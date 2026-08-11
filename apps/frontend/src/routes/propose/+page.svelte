<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { readContract } from '@wagmi/core';
	import { config } from '$lib/services/wallet-config';
	import { bvsRegistryConfig, bvsRegistryAddress, membersCanPropose } from '$lib/contracts';
	import { wallet } from '$lib/stores/wallet';
	import { loadCategories as fetchCategories, loadDocuments, loadAmendmentRestrictions, loadDocumentBody, type CategoryInfo, type DocumentInfo, type AmendmentRestrictionsInfo } from '$lib/services/registry';
	import Editor from '$lib/components/Editor.svelte';
	import AmendmentRestrictions from '$lib/components/AmendmentRestrictions.svelte';
	import {
		type Section,
		createSection,
		sectionsToMarkdown,
		buildDocument,
		parseDocument,
		renderSectionedMarkdown,
		wrapWithFrontmatter,
		validateMarkdownUpload,
		MarkdownUnsafeError
	} from '$lib/services/markdown';
	import { uploadDocument, verifyTurboHas } from '$lib/services/arweave';
	import ProposalConfirmation, { type ProposalConfirmationData } from '$lib/components/ProposalConfirmation.svelte';
	import ReviewModal from '$lib/components/ReviewModal.svelte';
	import LoadingButton from '$lib/components/LoadingButton.svelte';
	import { showToast } from '$lib/stores/toasts';
	import { hashBody, canonicalizeBody } from '@vattelum/document-registry-js';
	import { hashToBytes32 } from '$lib/services/hash';
	import {
		DOC_TYPES,
		DOC_TYPE_TO_RELATION,
		docTypeLabel,
		relationLabel,
		requiresReferences,
		allowsMultipleReferences,
		supportsSectionTargeting
	} from '$lib/constants/docTypes';
	import { computeSectionNumber, sortByFixedNumber } from '$lib/services/markdown';
	import type { TemplateVariable } from '$lib/services/template-variables';
	import TargetDocumentPicker from '$lib/components/TargetDocumentPicker.svelte';
	import SectionTargetPicker from '$lib/components/SectionTargetPicker.svelte';
	import { formatDate } from '$lib/services/format';
	import { createDraftStore } from '$lib/services/draft';
	import { chainIdToLabel, explorerTxUrl } from '$lib/constants/networks';
	import { marked } from 'marked';
	import DOMPurify from 'dompurify';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import {
		createProposal,
		encodeAddDocumentTransaction,
		encodeSetAmendmentRestrictionsTransaction,
		selectStrategy
	} from '$lib/services/snapshot-x';
	import { formatCountdown } from '$lib/services/format';
	const chainId = Number(import.meta.env.VITE_CHAIN_ID);

	interface VersionInfo {
		version: number;
		title: string;
		docType: number;
	}

	// Form state
	let title = $state('');
	let categoryId = $state(-1);
	let documentId = $state(0); // 0 = new document, >0 = amend existing
	let docType = $state(0);
	let selectedRefs = $state<Array<{ documentId: number; version: number }>>([]);
	let categoryDocuments = $state<DocumentInfo[]>([]);
	let documentVersions = $state<VersionInfo[]>([]);
	let loadingDocuments = $state(false);
	let loadingVersions = $state(false);
	let sections = $state<Section[]>([createSection(1)]);

	// Section targeting
	interface TargetSectionInfo {
		number: string;
		title: string;
		content: string;
		depth: 1 | 2 | 3;
	}
	let selectedTargetSections = $state<string[]>([]);
	let availableTargetSections = $state<TargetSectionInfo[]>([]);
	let allParsedSections = $state<Section[]>([]);
	let newSectionsOnly = $state(false);
	let loadingTargetDoc = $state(false);
	let targetDocError = $state('');
	let targetDocTitle = $state('');
	let targetDocVariables = $state<TemplateVariable[]>([]);

	// Repeal state
	let repealReason = $state('');

	// Proposed amendment restrictions (for the new document being created or
	// the baseline being revised). Bundled into the proposal payload as a 2nd
	// MetaTransaction so /vote's Approve flow can sign setAmendmentRestrictions
	// after addDocument.
	let proposeRestrictionsEnabled = $state(false);
	let proposeTimeLockSeconds = $state(0);
	let proposeTimeLockPreset = $state('permanent');
	let proposeTimeLockCustomDays = $state('');
	let proposeLockMode = $state<'entire' | 'specific'>('entire');
	let proposeLockedSectionNumbers = $state<number[]>([]);

	// Restrictions on the target document being amended (read on selection).
	// Drives editor gray-out (lockedSections cascade) and the time-window
	// submit gate (AmendmentTooSoon). null when no target / no restrictions.
	let targetRestrictions = $state<AmendmentRestrictionsInfo | null>(null);

	// Reactive clock — drives the AmendmentTooSoon countdown on the submit
	// button. One-minute resolution is plenty for day/hour-scale windows.
	let nowSeconds = $state(Math.floor(Date.now() / 1000));

	let targetRestrictionsActive = $derived.by(() => {
		if (!targetRestrictions) return false;
		const r = targetRestrictions;
		if (r.minTimeBetweenAmendments === 0 || r.lastAmendmentTime === 0) return false;
		return nowSeconds < r.lastAmendmentTime + r.minTimeBetweenAmendments;
	});

	let targetRestrictionsEarliestAllowed = $derived.by(() => {
		if (!targetRestrictions) return 0;
		return targetRestrictions.lastAmendmentTime + targetRestrictions.minTimeBetweenAmendments;
	});

	let targetLockedSections = $derived.by(() => targetRestrictions?.lockedSections ?? []);

	let proposalRequiresTooSoonGate = $derived.by(() =>
		(docType === 1 || docType === 2 || docType === 3) && targetRestrictionsActive
	);

	function topSectionNumbers(secs: { fixedNumber?: string }[]): number[] {
		const nums = new Set<number>();
		secs.forEach((s, i) => {
			const fn = s.fixedNumber ?? computeSectionNumber(secs as Section[], i).replace('§', '');
			const m = fn.match(/^(\d+)/);
			if (m) nums.add(Number(m[1]));
		});
		return [...nums].sort((a, b) => a - b);
	}

	function hasProposedRestrictions(): boolean {
		if (!proposeRestrictionsEnabled) return false;
		const hasTime = proposeTimeLockSeconds > 0;
		const hasLocks = proposeLockMode === 'entire' || proposeLockedSectionNumbers.length > 0;
		return hasTime || hasLocks;
	}

	function getProposedLockedSections(): bigint[] {
		if (!proposeRestrictionsEnabled) return [];
		if (proposeLockMode === 'entire') return [0n];
		return proposeLockedSectionNumbers.map((n) => BigInt(n));
	}

	function resetProposedRestrictions() {
		proposeRestrictionsEnabled = false;
		proposeTimeLockSeconds = 0;
		proposeTimeLockPreset = 'permanent';
		proposeTimeLockCustomDays = '';
		proposeLockMode = 'entire';
		proposeLockedSectionNumbers = [];
	}

	// Title is auto-derived from the target for Amendment/Revision/Repeal, so the field is read-only.
	// Uniqueness is only enforced for Original — Codification keeps its name free.
	let titleLocked = $derived(docType === 1 || docType === 2 || docType === 3);
	let titleDuplicate = $derived.by(() => {
		if (docType !== 0) return false;
		const t = title.trim();
		if (!t) return false;
		return categoryDocuments.some((d) => d.latestTitle.trim() === t);
	});

	function targetSectionValue(): string {
		return selectedTargetSections.join(',');
	}

	function titleSuffix(): string {
		if (docType === 3 && selectedTargetSections.length > 0) return 'Partial Repeal';
		return docTypeLabel(docType);
	}

	function baseTitle(t: string): string {
		return t.replace(/\s+v\d+$/, '');
	}

	function revisionTitle(targetTitle: string, targetDocType: number): string {
		if (targetDocType === 2) {
			const match = targetTitle.match(/\s+v(\d+)$/);
			const currentVersion = match ? parseInt(match[1], 10) : 2;
			return `${baseTitle(targetTitle)} v${currentVersion + 1}`;
		}
		return `${baseTitle(targetTitle)} v2`;
	}

	function updateTitle() {
		if (!targetDocTitle) return;
		title = `${targetDocTitle} (${titleSuffix()})`;
	}

	function isImplicitlySelected(sectionNumber: string): boolean {
		return selectedTargetSections.some(sel => {
			if (sel === sectionNumber) return false;
			return sectionNumber.startsWith(sel + '.');
		});
	}

	function sortedSelectedSections(): string[] {
		const order = availableTargetSections.map(s => s.number);
		return [...selectedTargetSections].sort((a, b) => order.indexOf(a) - order.indexOf(b));
	}

	function isAmendmentMode(): boolean {
		return docType === 1;
	}

	function isRepealMode(): boolean {
		return docType === 3 && selectedRefs.length === 1;
	}

	function originalSectionNumbers(): string[] {
		return availableTargetSections.map(s => s.number);
	}

	function handleNewSectionsOnlyChange(value: boolean) {
		newSectionsOnly = value;
		if (value) {
			selectedTargetSections = [];
			sections = [];
		} else {
			sections = allParsedSections.map((s, i) => {
				const sec = createSection(s.depth);
				sec.title = s.title;
				sec.content = s.content;
				sec.fixedNumber = computeSectionNumber(allParsedSections, i).replace('§', '');
				return sec;
			});
		}
		updateTitle();
	}

	// Page state
	let categories = $state<CategoryInfo[]>([]);
	let loadingCategories = $state(true);
	let submitting = $state(false);
	let submitStep = $state('');
	let submitError = $state('');
	// Persists a Turbo upload across retries when the post-upload verification
	// fails. Cleared on body change, on a failed re-check, and on success — see
	// handleSubmit. Keeps the user from silently paying for a second Turbo
	// upload when the first one just hasn't propagated yet.
	let pendingContentUri = $state<string | null>(null);
	let pendingContentHash = $state<string | null>(null);
	let importError = $state('');

	// Review modal
	let showReview = $state(false);
	let reviewHtml = $state('');

	// Confirmation
	let confirmed = $state(false);
	let confirmData = $state<ProposalConfirmationData | null>(null);

	async function loadCategories() {
		try {
			categories = await fetchCategories();
		} catch (e) {
			submitError = e instanceof Error ? e.message : 'Failed to load categories';
		} finally {
			loadingCategories = false;
		}
	}

	async function loadDocsForCategory(catId: number) {
		if (catId < 0) {
			categoryDocuments = [];
			return;
		}
		loadingDocuments = true;
		try {
			categoryDocuments = await loadDocuments(catId);
		} catch {
			categoryDocuments = [];
		} finally {
			loadingDocuments = false;
		}
	}

	async function loadVersionsForDocument(catId: number, docId: number) {
		if (catId < 0 || docId <= 0) {
			documentVersions = [];
			return;
		}
		loadingVersions = true;
		try {
			const history = (await readContract(config, {
				...bvsRegistryConfig,
				functionName: 'getHistory',
				args: [BigInt(catId), BigInt(docId)]
			})) as Array<{ title: string; version: bigint; docType: number }>;
			documentVersions = history.map((d) => ({
				version: Number(d.version),
				title: d.title,
				docType: d.docType
			}));
		} catch {
			documentVersions = [];
		} finally {
			loadingVersions = false;
		}
	}

	async function loadTargetDocSections(docId: number, version: number) {
		selectedTargetSections = [];
		newSectionsOnly = false;
		availableTargetSections = [];
		allParsedSections = [];
		targetDocError = '';
		targetDocTitle = '';
		targetRestrictions = null;
		if (version <= 0 || categoryId < 0 || docId <= 0) return;

		try {
			const r = await loadAmendmentRestrictions(categoryId, docId);
			targetRestrictions = (r.minTimeBetweenAmendments > 0 || r.lockedSections.length > 0)
				? r
				: null;
		} catch {
			targetRestrictions = null;
		}

		const ver = documentVersions.find((v) => v.version === version);
		if (!ver) return;

		targetDocTitle = ver.title;
		title = docType === 2 ? revisionTitle(ver.title, ver.docType) : `${ver.title} (${docTypeLabel(docType)})`;

		loadingTargetDoc = true;
		try {
			const doc = await loadDocumentBody(categoryId, docId, version);
			targetDocVariables = doc.variables;
			const parsed = doc.sections;
			if (parsed.length === 0) {
				targetDocError = 'No parseable sections found in the target document.';
				return;
			}

			allParsedSections = parsed;
			availableTargetSections = parsed.map((s, i) => ({
				number: computeSectionNumber(parsed, i).replace('§', ''),
				title: s.title,
				content: s.content,
				depth: s.depth
			}));

			sections = parsed.map((s, i) => {
				const sec = createSection(s.depth);
				sec.title = s.title;
				sec.content = s.content;
				sec.fixedNumber = computeSectionNumber(parsed, i).replace('§', '');
				return sec;
			});
		} catch {
			targetDocError = 'Could not fetch target document. You can still proceed with whole-document mode.';
		} finally {
			loadingTargetDoc = false;
		}
	}

	function handleSectionToggle(sectionNumber: string) {

		const isSelected = selectedTargetSections.includes(sectionNumber);
		if (isSelected) {
			selectedTargetSections = selectedTargetSections.filter(
				(s) => s !== sectionNumber && !s.startsWith(sectionNumber + '.')
			);
		} else {
			if (isImplicitlySelected(sectionNumber)) return;
			const withoutChildren = selectedTargetSections.filter(
				(s) => !s.startsWith(sectionNumber + '.')
			);
			selectedTargetSections = [...withoutChildren, sectionNumber];
		}

		selectedTargetSections = sortedSelectedSections();
		updateTitle();

		if (isRepealMode()) return;

		if (selectedTargetSections.length === 0) {
			sections = allParsedSections.map((s, i) => {
				const sec = createSection(s.depth);
				sec.title = s.title;
				sec.content = s.content;
				sec.fixedNumber = computeSectionNumber(allParsedSections, i).replace('§', '');
				return sec;
			});
		} else {
			const included = availableTargetSections.filter((s) =>
				selectedTargetSections.includes(s.number) || isImplicitlySelected(s.number)
			);
			sections = sortByFixedNumber(included.map((info) => {
				const sec = createSection(info.depth);
				sec.title = info.title;
				sec.content = info.content;
				sec.fixedNumber = info.number;
				return sec;
			}));
		}
	}

	function handleCategoryChange(newCatId: number) {
		categoryId = newCatId;
		documentId = 0;
		selectedRefs = [];
		categoryDocuments = [];
		documentVersions = [];
		selectedTargetSections = [];
		newSectionsOnly = false;
		availableTargetSections = [];
		allParsedSections = [];
		newSectionsOnly = false;
		targetDocError = '';
		targetDocTitle = '';
		targetRestrictions = null;
		resetProposedRestrictions();
		loadDocsForCategory(newCatId);
	}

	function handleDocTypeChange(newDocType: number) {
		const prevDocType = docType;
		docType = newDocType;

		if (newDocType === 0) {
			title = '';
			documentId = 0;
			selectedRefs = [];
			selectedTargetSections = [];
		newSectionsOnly = false;
			availableTargetSections = [];
			allParsedSections = [];
			newSectionsOnly = false;
			targetDocError = '';
			targetDocTitle = '';
			targetRestrictions = null;
			repealReason = '';
			documentVersions = [];
			sections = [createSection(1)];
			return;
		}

		if (newDocType === 4) {
			title = '';
			selectedRefs = [];
			selectedTargetSections = [];
		newSectionsOnly = false;
			availableTargetSections = [];
			allParsedSections = [];
			targetDocError = '';
			targetDocTitle = '';
			targetRestrictions = null;
			repealReason = '';
			sections = [createSection(1)];
			return;
		}

		if (newDocType === 2 && selectedRefs.length === 1) {
			selectedTargetSections = [];
		newSectionsOnly = false;
			availableTargetSections = [];
			allParsedSections = [];
			newSectionsOnly = false;
			repealReason = '';
			if (targetDocTitle) {
				const targetVer = documentVersions.find((v) => v.version === selectedRefs[0].version);
				title = revisionTitle(targetDocTitle, targetVer?.docType ?? 0);
			}
			sections = [createSection(1)];
			return;
		}

		if (supportsSectionTargeting(prevDocType) && supportsSectionTargeting(newDocType) && selectedRefs.length === 1) {
			selectedTargetSections = [];
		newSectionsOnly = false;
			repealReason = '';
			updateTitle();
			sections = allParsedSections.map((s, i) => {
				const sec = createSection(s.depth);
				sec.title = s.title;
				sec.content = s.content;
				sec.fixedNumber = computeSectionNumber(allParsedSections, i).replace('§', '');
				return sec;
			});
			return;
		}

		title = '';
		documentId = 0;
		selectedRefs = [];
		selectedTargetSections = [];
		newSectionsOnly = false;
		availableTargetSections = [];
		allParsedSections = [];
		newSectionsOnly = false;
		targetDocError = '';
		targetDocTitle = '';
		targetRestrictions = null;
		repealReason = '';
		documentVersions = [];
		sections = [createSection(1)];
	}

	function handleDocumentSelect(docId: number) {
		documentId = docId;
		selectedRefs = [];
		selectedTargetSections = [];
		newSectionsOnly = false;
		availableTargetSections = [];
		allParsedSections = [];
		targetDocError = '';
		targetDocTitle = '';
		targetRestrictions = null;
		documentVersions = [];

		if (docId > 0) {
			loadVersionsForDocument(categoryId, docId);
		}
	}

	function toggleRef(ref: { documentId: number; version: number }) {
		if (allowsMultipleReferences(docType)) {
			const exists = selectedRefs.find(r => r.documentId === ref.documentId && r.version === ref.version);
			if (exists) {
				selectedRefs = selectedRefs.filter(r => !(r.documentId === ref.documentId && r.version === ref.version));
			} else {
				selectedRefs = [...selectedRefs, ref];
			}
		} else {
			const wasSelected = selectedRefs.find(r => r.documentId === ref.documentId && r.version === ref.version);
			selectedRefs = wasSelected ? [] : [ref];
			selectedTargetSections = [];
		newSectionsOnly = false;
			availableTargetSections = [];
			allParsedSections = [];
			newSectionsOnly = false;
			targetDocError = '';
			targetDocTitle = '';
			targetRestrictions = null;
			if (!wasSelected && supportsSectionTargeting(docType)) {
				loadTargetDocSections(ref.documentId, ref.version);
			} else if (!wasSelected) {
				const ver = documentVersions.find((v) => v.version === ref.version);
				if (ver) {
					targetDocTitle = ver.title;
					title = docType === 2 ? revisionTitle(ver.title, ver.docType) : `${ver.title} (${docTypeLabel(docType)})`;
				}
			}
		}
	}

	function buildExternalRefs(): Array<{
		registryAddress: string;
		chainId: bigint;
		categoryId: bigint;
		documentId: bigint;
		version: bigint;
		relationType: number;
		targetSection: string;
	}> {
		if (!requiresReferences(docType) || selectedRefs.length === 0) return [];
		const relationType = DOC_TYPE_TO_RELATION[docType];
		return selectedRefs.map((ref) => ({
			registryAddress: bvsRegistryAddress,
			chainId: BigInt(chainId),
			categoryId: BigInt(categoryId),
			documentId: BigInt(ref.documentId),
			version: BigInt(ref.version),
			relationType,
			targetSection: targetSectionValue()
		}));
	}

	// Draft auto-save
	interface DraftState {
		title: string;
		categoryId: number;
		documentId: number;
		docType: number;
		selectedRefs: Array<{ documentId: number; version: number }>;
		selectedTargetSections: string[];
		repealReason: string;
		sections: Array<{ depth: number; title: string; content: string; fixedNumber?: string }>;
	}

	const draft = createDraftStore<DraftState>(
		'bvs:draft',
		() => {
			if (confirmed) return null;
			const hasContent = title.trim() || sections.some(s => s.title.trim() || s.content.trim());
			if (!hasContent) return null;
			return {
				title, categoryId, documentId, docType, selectedRefs,
				selectedTargetSections, repealReason,
				sections: sections.map(s => ({ depth: s.depth, title: s.title, content: s.content, fixedNumber: s.fixedNumber }))
			};
		},
		(d) => {
			title = d.title ?? '';
			categoryId = d.categoryId ?? -1;
			documentId = d.documentId ?? 0;
			docType = d.docType ?? 0;
			selectedRefs = Array.isArray(d.selectedRefs) ? d.selectedRefs : [];
			selectedTargetSections = Array.isArray(d.selectedTargetSections) ? d.selectedTargetSections : [];
			repealReason = d.repealReason ?? '';
			if (categoryId >= 0) loadDocsForCategory(categoryId);
			if (documentId > 0 && categoryId >= 0) {
				loadVersionsForDocument(categoryId, documentId);
			}
			if (Array.isArray(d.sections) && d.sections.length > 0) {
				sections = d.sections.map((s) =>
					({ ...createSection(s.depth as 1 | 2 | 3), title: s.title, content: s.content, fixedNumber: s.fixedNumber })
				);
			}
		}
	);

	/**
	 * Reset every form field to its initial state. Used by both the manual
	 * "Clear All" button and the "Propose Another" flow after a successful
	 * submission.
	 *
	 * @param resetCategory — whether to wipe the selected category (true for
	 * Clear All, false for Propose Another which preserves category selection
	 * momentum).
	 */
	function resetAll(resetCategory: boolean) {
		confirmed = false;
		confirmData = null;
		title = '';
		docType = 0;
		documentId = 0;
		selectedRefs = [];
		categoryDocuments = [];
		documentVersions = [];
		selectedTargetSections = [];
		newSectionsOnly = false;
		availableTargetSections = [];
		allParsedSections = [];
		targetDocError = '';
		targetDocTitle = '';
		repealReason = '';
		targetRestrictions = null;
		resetProposedRestrictions();
		sections = [createSection(1)];
		draft.clear();
		if (resetCategory) categoryId = -1;
	}

	function clearAll() {
		if (!confirm('Clear all fields?')) return;
		resetAll(true);
	}

	function buildRepealBody(): string {
		const sorted = sortedSelectedSections();
		const includesChildren = sorted.some(s => availableTargetSections.some(t => t.number.startsWith(s + '.')));
		const childNote = includesChildren ? ' (and all subsections)' : '';
		let sentence: string;
		if (sorted.length === 0) {
			sentence = `"${targetDocTitle}" is repealed.`;
		} else if (sorted.length === 1) {
			sentence = `\u00A7${sorted[0]}${childNote} of "${targetDocTitle}" is repealed.`;
		} else {
			sentence = `${sorted.map(s => '\u00A7' + s).join(', ')}${childNote} of "${targetDocTitle}" are repealed.`;
		}
		let body = `## Repeal Notice\n\n${sentence}`;
		if (repealReason.trim()) {
			body += `\n\n**Reason:** ${repealReason.trim()}`;
		}
		return body;
	}

	async function openReview() {
		if (!title.trim()) {
			submitError = 'Title is required.';
			return;
		}
		if (title.length > 256) {
			submitError = 'Title must be 256 characters or fewer.';
			return;
		}
		if (categoryId < 0) {
			submitError = 'Please select a category.';
			return;
		}
		if (titleDuplicate) {
			submitError = 'A document with this title already exists in this category. Choose a different title.';
			return;
		}
		if (isRepealMode()) {
			// Repeal doesn't need editor sections
		} else if (sections.length === 0) {
			submitError = 'At least one section is required.';
			return;
		}
		if (requiresReferences(docType) && selectedRefs.length === 0) {
			if (allowsMultipleReferences(docType)) {
				submitError = `${docTypeLabel(docType)} requires selecting at least one document to consolidate.`;
			} else {
				submitError = `Please select a document to ${docTypeLabel(docType).toLowerCase()}.`;
			}
			return;
		}
		submitError = '';

		if (isRepealMode()) {
			const md = buildRepealBody();
			reviewHtml = DOMPurify.sanitize(await marked.parse(md));
		} else {
			const md = sectionsToMarkdown(sections);
			reviewHtml = await renderSectionedMarkdown(md);
		}
		showReview = true;
	}

	async function handleSubmit() {
		showReview = false;
		submitting = true;
		submitError = '';

		try {
			// 1. Assemble body and compute hash
			submitStep = 'Computing content hash...';
			// Canonicalize once, upstream of both the hash and the frontmatter-wrap
			// that feeds uploadDocument, so producer bytes and the recorded hash agree
			// byte-for-byte with any third-party verifier (S-4).
			const body = canonicalizeBody(isRepealMode() ? buildRepealBody() : sectionsToMarkdown(sections));
			const contentHash = hashBody(body);

			// 2. Build full document with frontmatter
			const cat = categories.find((c) => c.id === categoryId);
			const frontmatter: Record<string, unknown> = {
				title,
				doc_type: docType,
				category: cat?.name ?? '',
				registry_address: bvsRegistryAddress,
				network: chainIdToLabel(chainId),
				chain_id: chainId,
				submitted: formatDate(Math.floor(Date.now() / 1000)),
				content_hash: contentHash,
				...(selectedTargetSections.length > 0 ? { target_section: targetSectionValue() } : {})
			};
			let fullDocument: string;
			if (isRepealMode()) {
				fullDocument = wrapWithFrontmatter(frontmatter, body);
			} else {
				fullDocument = buildDocument(frontmatter, sections);
			}

			// 2.5 Validate the assembled document is sanitization-clean before upload.
			submitStep = 'Validating content...';
			await validateMarkdownUpload(fullDocument);

			// 3. Upload to Arweave (Transaction 1) — or re-check a previous upload
			// whose verification failed last time, if the body is unchanged.
			if (pendingContentHash !== contentHash) {
				pendingContentUri = null;
				pendingContentHash = null;
			}

			let contentUri: string;
			if (pendingContentUri) {
				submitStep = 'Re-checking previous upload...';
				try {
					await verifyTurboHas(pendingContentUri);
					contentUri = pendingContentUri;
					pendingContentUri = null;
					pendingContentHash = null;
				} catch {
					pendingContentUri = null;
					pendingContentHash = null;
					throw new Error(
						"Previous upload not confirmed on Arweave. Submit again to start a fresh upload on Arweave."
					);
				}
			} else {
				submitStep = 'Uploading to Arweave...';
				contentUri = await uploadDocument(fullDocument);

				submitStep = 'Verifying upload...';
				try {
					await verifyTurboHas(contentUri);
				} catch {
					pendingContentUri = contentUri;
					pendingContentHash = contentHash;
					throw new Error(
						"Upload sent to Arweave but our system couldn't confirm it yet. Click Submit to re-check."
					);
				}
			}

			// 4. Create Snapshot X proposal (Transaction 2)
			submitStep = 'Creating governance proposal...';
			const strategyAddress = selectStrategy();

			const addDocTx = encodeAddDocumentTransaction(
				{
					categoryId: BigInt(categoryId),
					documentId: BigInt(documentId),
					contentUri,
					contentHash: hashToBytes32(contentHash),
					title,
					voteId: '',
					docType
				},
				buildExternalRefs()
			);

			const transactions = [addDocTx];

			// 4b. Bundle setAmendmentRestrictions when the proposer wants the
			//     new doc locked. /vote decodes (minTime, lockedSections) from
			//     this MetaTransaction and signs setAmendmentRestrictions as a
			//     follow-up tx after addDocument confirms — resolving the real
			//     documentId from the DocumentAdded event log. The documentId
			//     arg encoded here is therefore unused at execution and we pass
			//     0n as a placeholder.
			if (hasProposedRestrictions()) {
				const restrictionTx = encodeSetAmendmentRestrictionsTransaction(
					BigInt(categoryId),
					documentId > 0 ? BigInt(documentId) : 0n,
					BigInt(proposeTimeLockSeconds),
					getProposedLockedSections()
				);
				transactions.push(restrictionTx);
			}

			// Metadata URI includes Arweave link for voter verification
			const metadataURI = `ipfs://proposal:${title}|arweave:${contentUri}`;

			const result = await createProposal(
				$wallet.address!,
				metadataURI,
				strategyAddress,
				transactions
			);

			// 5. Clear draft and show confirmation
			draft.clear();
			pendingContentUri = null;
			pendingContentHash = null;
			confirmed = true;
			let refSummary = '';
			if (selectedRefs.length > 0 && requiresReferences(docType)) {
				const relType = DOC_TYPE_TO_RELATION[docType];
				const relLabel = relationLabel(relType);
				const ref = selectedRefs[0];
				const refVer = documentVersions.find(v => v.version === ref.version);
				const refTitle = refVer?.title ?? '';
				const secs = selectedTargetSections.length > 0
					? `, \u00A7${sortedSelectedSections().join(', \u00A7')}`
					: '';
				refSummary = `${relLabel} ${refTitle || `document ${ref.documentId}`} v${ref.version}${secs}`;
			}

			confirmData = {
				txHash: result.txHash,
				contentUri,
				proposalId: result.proposalId,
				title,
				category: cat?.name ?? '',
				documentId,
				docTypeName: docTypeLabel(docType),
				refSummary
			};
		} catch (e) {
			const msg = e instanceof Error ? e.message : 'Proposal creation failed';
			submitError = msg;
			if (!(e instanceof MarkdownUnsafeError)) {
				showToast('error', msg);
			}
		} finally {
			submitting = false;
			submitStep = '';
		}
	}

	function handleExport() {
		const cat = categories.find((c) => c.id === categoryId);
		const body = sectionsToMarkdown(sections);
		const frontmatter: Record<string, unknown> = {
			title: title || 'Untitled',
			doc_type: docType,
			category: cat?.name ?? '',
			registry_address: bvsRegistryAddress,
			network: chainIdToLabel(chainId),
			chain_id: chainId,
			...(selectedTargetSections.length > 0 ? { target_section: targetSectionValue() } : {})
		};
		const doc = buildDocument(frontmatter, sections);

		const blob = new Blob([doc], { type: 'text/markdown' });
		const url = URL.createObjectURL(blob);
		const a = document.createElement('a');
		a.href = url;
		a.download = `${(title || 'draft').replace(/\s+/g, '-').toLowerCase()}.md`;
		a.click();
		URL.revokeObjectURL(url);
	}

	function handleImport() {
		const input = document.createElement('input');
		input.type = 'file';
		input.accept = '.md';
		input.onchange = async () => {
			const file = input.files?.[0];
			if (!file) return;
			importError = '';

			try {
				const text = await file.text();
				const { frontmatter, sections: parsedSections } = parseDocument(text);

				if (parsedSections.length === 0) {
					importError = 'No sections found. Ensure headings use \u00A7-numbered format (## \u00A71, ### \u00A71.1, #### \u00A71.1.A).';
					return;
				}

				if (frontmatter.title && docType !== 1 && docType !== 2 && docType !== 3) title = frontmatter.title;
				if (frontmatter.category) {
					const match = categories.find(
						(c) => c.name.toLowerCase() === frontmatter.category.toLowerCase()
					);
					if (match) categoryId = match.id;
				}

				sections = parsedSections;
			} catch {
				importError = 'Failed to parse the imported file.';
			}
		};
		input.click();
	}

	function resetForm() {
		resetAll(false);
		loadCategories();
	}

	onMount(() => {
		draft.restore();
		loadCategories();
		draft.startAutosave();
	});

	$effect(() => {
		const id = setInterval(() => {
			nowSeconds = Math.floor(Date.now() / 1000);
		}, 60_000);
		return () => clearInterval(id);
	});

	onDestroy(() => {
		draft.stopAutosave();
		draft.save();
	});
</script>

<div>
	<h1 class="text-2xl font-semibold mb-6">{confirmed ? 'Proposal Submitted' : 'Propose Legislation'}</h1>

	<!-- Confirmation screen -->
	{#if confirmed && confirmData}
		<ProposalConfirmation data={confirmData} {chainId} onReset={resetForm} />

	<!-- Editor (accessible to any token holder) -->
	{:else}
		{#if loadingCategories}
			<p class="text-text-secondary">Loading categories...</p>
		{:else}
			{@const canPropose = $wallet.connected && $wallet.isTokenHolder}

			{#if !$wallet.connected}
				<div class="border border-border rounded-lg p-4 text-center mb-6">
					<p class="text-text-muted text-sm">Connect your wallet to propose legislation.</p>
				</div>
			{:else if !$wallet.isTokenHolder}
				<div class="border border-border rounded-lg p-4 text-center mb-6">
					<p class="text-text-muted text-sm">You need a membership token to propose legislation. <a href="/admin" class="text-primary hover:underline">Join the association</a> first.</p>
				</div>
			{/if}

			<div class="flex flex-col gap-5" class:opacity-50={!canPropose} class:pointer-events-none={!canPropose}>
				<!-- Metadata form -->
				<div class="flex flex-col gap-4">
					<div>
						<label for="title" class="block text-sm text-text-secondary mb-1">Title</label>
						<input
							id="title"
							type="text"
							bind:value={title}
							disabled={!canPropose}
							readonly={titleLocked}
							placeholder="Document title"
							class="w-full bg-bg-light border rounded px-3 py-2 text-sm outline-none focus:border-primary disabled:opacity-50 read-only:opacity-60 read-only:cursor-not-allowed {titleDuplicate ? 'border-error' : 'border-border'}"
						/>
						{#if titleLocked}
							<p class="text-xs text-text-muted mt-1">Title is derived from the target document and cannot be edited.</p>
						{:else if titleDuplicate}
							<p class="text-xs text-error mt-1">A document with this title already exists in this category. Choose a different title.</p>
						{/if}
					</div>

					<div>
						<label for="category" class="block text-sm text-text-secondary mb-1"
							>Category <Tooltip text={"Categories are defined in the smart contract by the governance authority and represent distinct legislative domains (e.g. Governing Laws, Chain Standards, Model Agreements).\n\nNew categories can be added by the core governance authority."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip></label
						>
						<select
							id="category"
							value={categoryId}
							onchange={(e) => handleCategoryChange(Number((e.target as HTMLSelectElement).value))}
							disabled={!canPropose}
							class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary disabled:opacity-50"
						>
							<option value={-1} disabled>Select a category</option>
							{#each categories as cat}
								<option value={cat.id}>{cat.name}</option>
							{/each}
						</select>
					</div>

					<div>
						<label for="docType" class="block text-sm text-text-secondary mb-1"
							>Document Type <Tooltip text={"Original: new legislation.\nAmendment: modifies an existing document.\nRevision: full replacement.\nRepeal: revokes a document.\nCodification: consolidates multiple documents."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip></label
						>
						<select
							id="docType"
							value={docType}
							onchange={(e) => handleDocTypeChange(Number((e.target as HTMLSelectElement).value))}
							disabled={!canPropose}
							class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary disabled:opacity-50"
						>
							{#each DOC_TYPES as dt}
								<option value={dt.value}>{dt.label}</option>
							{/each}
						</select>
					</div>

					<TargetDocumentPicker
						{docType}
						{categoryId}
						{categoryDocuments}
						{documentId}
						{documentVersions}
						{selectedRefs}
						{loadingDocuments}
						{loadingVersions}
						onDocumentSelect={handleDocumentSelect}
						onToggleRef={toggleRef}
					/>

					{#if requiresReferences(docType) && supportsSectionTargeting(docType) && selectedRefs.length === 1}
						<SectionTargetPicker
							{availableTargetSections}
							bind:selectedTargetSections
							bind:newSectionsOnly
							{loadingTargetDoc}
							{targetDocError}
							isAmendmentMode={isAmendmentMode()}
							isRepealMode={isRepealMode()}
							{targetDocVariables}
							lockedSections={targetLockedSections}
							onToggleSection={handleSectionToggle}
							onNewSectionsOnlyChange={handleNewSectionsOnlyChange}
						/>
					{/if}

					{#if targetRestrictions}
						<div class="border border-error/30 rounded-lg p-3 bg-error/5">
							<p class="text-sm text-error font-medium mb-1">Target document has on-chain restrictions</p>
							<ul class="text-xs text-text-secondary list-disc pl-5 space-y-0.5">
								{#if targetRestrictions.lockedSections.length > 0}
									{#if targetRestrictions.lockedSections.includes(0)}
										<li>Every section is locked. Amendments to any section will revert <code>SectionLocked</code>.</li>
									{:else}
										<li>Locked: {targetRestrictions.lockedSections.map((s) => '§' + s).join(', ')} (cascade: subsections included)</li>
									{/if}
									{#if isAmendmentMode()}
										<label class="flex items-center gap-2 cursor-pointer mt-2">
											<input
												type="checkbox"
												bind:checked={newSectionsOnly}
												onchange={() => {
													if (newSectionsOnly) {
														selectedTargetSections = [];
														sections = [];
													} else {
														sections = allParsedSections.map((s, i) => {
															const sec = createSection(s.depth);
															sec.title = s.title;
															sec.content = s.content;
															sec.fixedNumber = computeSectionNumber(allParsedSections, i).replace('§', '');
															return sec;
														});
													}
													updateTitle();
												}}
												class="accent-primary"
											/>
											<span class="text-sm text-text-secondary">Add new section instead</span>
										</label>
									{/if}
								{/if}
								{#if targetRestrictions.minTimeBetweenAmendments > 0 && targetRestrictionsActive}
									<li>Time gate active — next amendment allowed in <span class="font-mono">{formatCountdown(targetRestrictionsEarliestAllowed)}</span>.</li>
								{:else if targetRestrictions.minTimeBetweenAmendments > 0}
									<li>Time gate ({Math.round(targetRestrictions.minTimeBetweenAmendments / 86400)} days) is currently elapsed.</li>
								{/if}
							</ul>
						</div>
					{/if}
				</div>

				{#if isRepealMode()}
					<!-- Repeal UI -->
					<div class="border border-border rounded bg-bg-light p-4 flex flex-col gap-4">
						<div>
							<p class="text-sm text-text-secondary">
								{#if selectedTargetSections.length > 0}
									Repealing {sortedSelectedSections().map(s => '§' + s).join(', ')}{sortedSelectedSections().some(s => availableTargetSections.some(t => t.number.startsWith(s + '.'))) ? ' (and all subsections)' : ''} of "{targetDocTitle}"
								{:else}
									Repealing entire document "{targetDocTitle}"
								{/if}
							</p>
						</div>
						<div>
							<label for="repealReason" class="block text-sm text-text-secondary mb-1">Reason for repeal <span class="text-text-muted">(optional)</span></label>
							<textarea
								id="repealReason"
								bind:value={repealReason}
								placeholder="Explain why this document or section is being repealed..."
								rows="4"
								class="w-full bg-bg border border-border rounded p-2 text-sm text-text placeholder:text-text-muted outline-none focus:border-primary resize-y"
							></textarea>
						</div>
					</div>
				{:else}
					<!-- Import/Export/Clear -->
					{#if canPropose}
						<div class="flex gap-3">
							<LoadingButton
								onclick={handleImport}
								variant="none"
								class="border border-primary text-primary hover:bg-primary hover:text-text py-1.5"
							>
								Import .md
							</LoadingButton>
							<LoadingButton
								onclick={handleExport}
								variant="none"
								class="border border-primary text-primary hover:bg-primary hover:text-text py-1.5"
							>
								Export .md
							</LoadingButton>
							<LoadingButton
								onclick={clearAll}
								variant="none"
								class="border border-border text-text-muted hover:border-error hover:text-error py-1.5"
							>
								Clear All
							</LoadingButton>
						</div>
					{/if}

					{#if importError}
						<p class="text-error text-sm">{importError}</p>
					{/if}

					<!-- Editor -->
					<Editor
						bind:sections
						amendmentMode={isAmendmentMode()}
						originalSectionNumbers={originalSectionNumbers()}
						lockedSections={targetLockedSections}
					/>

					<!-- Restrictions picker — only for the new document being created
					     (Original) or a baseline-replacing Revision/Codification.
					     Amendment/Repeal target an existing doc and inherit its locks. -->
					{#if docType === 0 || docType === 2 || docType === 4}
						<AmendmentRestrictions
							bind:enabled={proposeRestrictionsEnabled}
							bind:timeLockSeconds={proposeTimeLockSeconds}
							bind:timeLockPreset={proposeTimeLockPreset}
							bind:timeLockCustomDays={proposeTimeLockCustomDays}
							bind:lockMode={proposeLockMode}
							bind:lockedSectionNumbers={proposeLockedSectionNumbers}
							topSections={topSectionNumbers(sections)}
						/>
					{/if}
				{/if}

				<!-- Submit -->
				{#if submitError}
					<p class="text-error text-sm">{submitError}</p>
				{/if}

				{#if proposalRequiresTooSoonGate}
					<p class="text-error text-sm">
						Target document is inside its amendment window.
						<code>BVSRegistry.addDocument</code> would revert <code>AmendmentTooSoon</code>.
						Next amendment allowed in <span class="font-mono">{formatCountdown(targetRestrictionsEarliestAllowed)}</span>.
					</p>
				{/if}

				{#if canPropose}
					<div class="flex items-center gap-2">
						<LoadingButton
							onclick={openReview}
							loading={submitting}
							disabled={proposalRequiresTooSoonGate}
							loadingLabel={submitStep || 'Submitting...'}
							variant="primary"
							class="self-start px-6"
						>
							Review &amp; Submit Proposal
						</LoadingButton>
						<Tooltip text={"The document is uploaded to Arweave (permanent storage), then a governance proposal is created on Snapshot X.\n\nMembers vote on-chain. If the proposal includes amendment restrictions, the admin's Approve flow signs a follow-up setAmendmentRestrictions transaction.\n\nTwo transactions to submit: (1) Arweave upload, (2) Snapshot X proposal creation."} align="left" position="above"><span class="text-sm text-text-muted cursor-help">(?)</span></Tooltip>
					</div>
				{/if}
			</div>
		{/if}
	{/if}
</div>

<!-- Review modal -->
{#if showReview}
	{#snippet reviewBadges()}
		<span>Category: {categories.find(c => c.id === categoryId)?.name ?? ''}</span>
		{#if documentId > 0}
			<span>Document: {documentId}</span>
		{/if}
		<span>Type: {docTypeLabel(docType)}</span>
		{#if selectedTargetSections.length > 0}
			<span>Target: {selectedTargetSections.map(s => '\u00A7' + s).join(', ')}</span>
		{/if}
		{#if hasProposedRestrictions()}
			<span class="text-cat-gold">Restrictions: {proposeLockMode === 'entire' ? 'Entire document' : proposeLockedSectionNumbers.map(s => '\u00A7' + s).join(', ')}{proposeTimeLockSeconds > 0 ? `, ${Math.round(proposeTimeLockSeconds / 86400)}-day window` : ', no time gate'}</span>
		{/if}
	{/snippet}
	<ReviewModal
		{title}
		bodyHtml={reviewHtml}
		badges={reviewBadges}
		copyText={isRepealMode() ? buildRepealBody() : sectionsToMarkdown(sections)}
		onClose={() => showReview = false}
		onSubmit={handleSubmit}
	/>
{/if}
