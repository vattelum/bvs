<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { readContract, writeContract, waitForTransactionReceipt } from '@wagmi/core';
	import { config } from '$lib/services/ethereum';
	import { bvsRegistryConfig, bvsRegistryAddress } from '$lib/contracts';
	import { wallet } from '$lib/stores/wallet';
	import { loadCategories as fetchCategories, type CategoryInfo } from '$lib/services/registry';
	import Editor from '$lib/components/Editor.svelte';
	import {
		type Section,
		createSection,
		sectionsToMarkdown,
		buildDocument,
		parseDocument,
		wrapSections
	} from '$lib/services/markdown';
	import { uploadDocument, arweaveUrl } from '$lib/services/arweave';
	import { hashBody, hashToBytes32 } from '$lib/services/hash';
	import {
		DOC_TYPES,
		DOC_TYPE_TO_RELATION,
		docTypeLabel,
		relationLabel,
		requiresReferences,
		allowsMultipleReferences,
		supportsSectionTargeting
	} from '$lib/constants/docTypes';
	import { fetchFromArweave } from '$lib/services/arweave';
	import { computeSectionNumber, markdownToSections, sortByFixedNumber } from '$lib/services/markdown';
	import { marked } from 'marked';
	import DOMPurify from 'dompurify';
	import Tooltip from '$lib/components/Tooltip.svelte';
	const chainId = Number(import.meta.env.VITE_CHAIN_ID);
	const snapshotHub = import.meta.env.VITE_SNAPSHOT_HUB as string;
	const snapshotSpace = import.meta.env.VITE_SNAPSHOT_SPACE as string;

	interface VersionInfo {
		version: number;
		title: string;
		docType: number;
	}

	// Form state
	let title = $state('');
	let categoryId = $state(-1);
	let voteId = $state('');
	let docType = $state(0);
	let selectedRefs = $state<number[]>([]);
	let categoryVersions = $state<VersionInfo[]>([]);
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

	// Repeal state
	let repealReason = $state('');

	/** Comma-separated targetSection string for on-chain storage */
	function targetSectionValue(): string {
		return selectedTargetSections.join(',');
	}

	/** Derive the title suffix based on docType and selected sections */
	function titleSuffix(): string {
		if (docType === 3 && selectedTargetSections.length > 0) return 'Partial Repeal';
		return docTypeLabel(docType);
	}

	/** Strip any trailing " vN" suffix from a title to get the base name */
	function baseTitle(t: string): string {
		return t.replace(/\s+v\d+$/, '');
	}

	/** Derive a revision title with version numbering (v2, v3, ...) */
	function revisionTitle(targetTitle: string, targetDocType: number): string {
		if (targetDocType === 2) {
			const match = targetTitle.match(/\s+v(\d+)$/);
			const currentVersion = match ? parseInt(match[1], 10) : 2;
			return `${baseTitle(targetTitle)} v${currentVersion + 1}`;
		}
		return `${baseTitle(targetTitle)} v2`;
	}

	/** Update the title from the target document name + current mode */
	function updateTitle() {
		if (!targetDocTitle) return;
		title = `${targetDocTitle} (${titleSuffix()})`;
	}

	/** Whether a section is implicitly included because a parent is selected */
	function isImplicitlySelected(sectionNumber: string): boolean {
		return selectedTargetSections.some(sel => {
			if (sel === sectionNumber) return false;
			return sectionNumber.startsWith(sel + '.');
		});
	}

	/** Get sections in document order (matching availableTargetSections order) */
	function sortedSelectedSections(): string[] {
		const order = availableTargetSections.map(s => s.number);
		return [...selectedTargetSections].sort((a, b) => order.indexOf(a) - order.indexOf(b));
	}

	/** Whether the current docType uses the amendment editor mode */
	function isAmendmentMode(): boolean {
		return docType === 1 && selectedRefs.length === 1;
	}

	/** Whether the current docType uses the repeal flow */
	function isRepealMode(): boolean {
		return docType === 3 && selectedRefs.length === 1;
	}

	/** All original section numbers for the editor's numbering context */
	function originalSectionNumbers(): string[] {
		return availableTargetSections.map(s => s.number);
	}

	// Snapshot proposals
	interface SnapshotProposal {
		id: string;
		title: string;
		state: string;
		created: number;
	}
	let proposals = $state<SnapshotProposal[]>([]);
	let showProposals = $state(false);
	let loadingProposals = $state(false);

	async function fetchProposals() {
		if (proposals.length > 0) {
			showProposals = !showProposals;
			return;
		}
		loadingProposals = true;
		showProposals = true;
		try {
			const query = `{ proposals(where: { space_in: ["${snapshotSpace}"] }, first: 10, orderBy: "created", orderDirection: desc) { id title state created } }`;
			const res = await fetch(`${snapshotHub}/graphql`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ query })
			});
			const json = await res.json();
			proposals = json.data?.proposals ?? [];
		} catch {
			proposals = [];
		} finally {
			loadingProposals = false;
		}
	}

	function selectProposal(id: string) {
		voteId = id;
		showProposals = false;
	}

	// Draft auto-save
	const DRAFT_KEY = 'bvs:draft';
	let autoSaveInterval: ReturnType<typeof setInterval> | null = null;

	function saveDraft() {
		if (confirmed) return;
		const hasContent = title.trim() || sections.some(s => s.title.trim() || s.content.trim());
		if (!hasContent) return;
		try {
			localStorage.setItem(DRAFT_KEY, JSON.stringify({
				title, categoryId, voteId, docType, selectedRefs,
				selectedTargetSections, repealReason,
				sections: sections.map(s => ({ depth: s.depth, title: s.title, content: s.content, fixedNumber: s.fixedNumber }))
			}));
		} catch {
			// storage full or unavailable
		}
	}

	function restoreDraft() {
		try {
			const raw = localStorage.getItem(DRAFT_KEY);
			if (!raw) return;
			const draft = JSON.parse(raw);
			title = draft.title ?? '';
			categoryId = draft.categoryId ?? -1;
			voteId = draft.voteId ?? '';
			docType = draft.docType ?? 0;
			selectedRefs = Array.isArray(draft.selectedRefs) ? draft.selectedRefs : [];
			selectedTargetSections = Array.isArray(draft.selectedTargetSections) ? draft.selectedTargetSections : [];
			repealReason = draft.repealReason ?? '';
			if (categoryId >= 0) loadVersionsForCategory(categoryId);
			if (Array.isArray(draft.sections) && draft.sections.length > 0) {
				sections = draft.sections.map((s: { depth: number; title: string; content: string; fixedNumber?: string }) =>
					({ ...createSection(s.depth as 1 | 2 | 3), title: s.title, content: s.content, fixedNumber: s.fixedNumber })
				);
			}
		} catch {
			// corrupt draft, ignore
		}
	}

	function clearDraft() {
		try { localStorage.removeItem(DRAFT_KEY); } catch {}
	}

	function clearAll() {
		if (!confirm('Clear all fields?')) return;
		title = '';
		categoryId = -1;
		voteId = '';
		docType = 0;
		selectedRefs = [];
		categoryVersions = [];
		selectedTargetSections = [];
		availableTargetSections = [];
		allParsedSections = [];
		newSectionsOnly = false;
		targetDocError = '';
		targetDocTitle = '';
		repealReason = '';
		sections = [createSection(1)];
		clearDraft();
	}

	async function loadVersionsForCategory(catId: number) {
		if (catId < 0) {
			categoryVersions = [];
			return;
		}
		loadingVersions = true;
		try {
			const history = (await readContract(config, {
				...bvsRegistryConfig,
				functionName: 'getHistory',
				args: [BigInt(catId)]
			})) as Array<{ title: string; version: bigint; docType: number }>;
			categoryVersions = history.map((d) => ({
				version: Number(d.version),
				title: d.title,
				docType: d.docType
			}));
		} catch {
			categoryVersions = [];
		} finally {
			loadingVersions = false;
		}
	}

	async function loadTargetDocSections(version: number) {
		selectedTargetSections = [];
		availableTargetSections = [];
		allParsedSections = [];
		targetDocError = '';
		targetDocTitle = '';
		if (version <= 0 || categoryId < 0) return;

		const ver = categoryVersions.find((v) => v.version === version);
		if (!ver) return;

		targetDocTitle = ver.title;
		title = docType === 2 ? revisionTitle(ver.title, ver.docType) : `${ver.title} (${docTypeLabel(docType)})`;

		loadingTargetDoc = true;
		try {
			const doc = (await readContract(config, {
				...bvsRegistryConfig,
				functionName: 'getDocument',
				args: [BigInt(categoryId), BigInt(version)]
			})) as { arweaveTxId: string; contentHash: string };

			const text = await fetchFromArweave(doc.arweaveTxId, doc.contentHash);
			const bodyMatch = text.match(/^---\n[\s\S]*?\n---\n([\s\S]*)$/);
			const body = bodyMatch ? bodyMatch[1].trim() : text;

			const parsed = markdownToSections(body);
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
		selectedRefs = [];
		selectedTargetSections = [];
		availableTargetSections = [];
		allParsedSections = [];
		newSectionsOnly = false;
		targetDocError = '';
		targetDocTitle = '';
		loadVersionsForCategory(newCatId);
	}

	function handleDocTypeChange(newDocType: number) {
		const prevDocType = docType;
		docType = newDocType;

		if (newDocType === 0 || newDocType === 4) {
			title = '';
			selectedRefs = [];
			selectedTargetSections = [];
			availableTargetSections = [];
			allParsedSections = [];
			newSectionsOnly = false;
			targetDocError = '';
			targetDocTitle = '';
			repealReason = '';
			sections = [createSection(1)];
			return;
		}

		if (newDocType === 2 && selectedRefs.length === 1) {
			selectedTargetSections = [];
			availableTargetSections = [];
			allParsedSections = [];
			newSectionsOnly = false;
			repealReason = '';
			if (targetDocTitle) {
				const targetVer = categoryVersions.find((v) => v.version === selectedRefs[0]);
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
		selectedRefs = [];
		selectedTargetSections = [];
		availableTargetSections = [];
		allParsedSections = [];
		newSectionsOnly = false;
		targetDocError = '';
		targetDocTitle = '';
		repealReason = '';
		sections = [createSection(1)];
	}

	function toggleRef(version: number) {
		if (allowsMultipleReferences(docType)) {
			if (selectedRefs.includes(version)) {
				selectedRefs = selectedRefs.filter((v) => v !== version);
			} else {
				selectedRefs = [...selectedRefs, version];
			}
		} else {
			const wasSelected = selectedRefs.includes(version);
			selectedRefs = wasSelected ? [] : [version];
			selectedTargetSections = [];
			availableTargetSections = [];
			allParsedSections = [];
			newSectionsOnly = false;
			targetDocError = '';
			targetDocTitle = '';
			if (!wasSelected && supportsSectionTargeting(docType)) {
				loadTargetDocSections(version);
			} else if (!wasSelected) {
				const ver = categoryVersions.find((v) => v.version === version);
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
		version: bigint;
		relationType: number;
		targetSection: string;
	}> {
		if (!requiresReferences(docType) || selectedRefs.length === 0) return [];
		const relationType = DOC_TYPE_TO_RELATION[docType];
		return selectedRefs.map((version) => ({
			registryAddress: bvsRegistryAddress,
			chainId: BigInt(chainId),
			categoryId: BigInt(categoryId),
			version: BigInt(version),
			relationType,
			targetSection: targetSectionValue()
		}));
	}

	// Page state
	let categories = $state<CategoryInfo[]>([]);
	let loadingCategories = $state(true);
	let submitting = $state(false);
	let submitStep = $state('');
	let submitError = $state('');
	let importError = $state('');

	// Review modal
	let showReview = $state(false);
	let reviewHtml = $state('');
	let reviewCopyLabel = $state('Copy');

	// Confirmation
	let confirmed = $state(false);
	let confirmData = $state<{
		txHash: string;
		arweaveTxId: string;
		title: string;
		category: string;
		version: number;
		docTypeName: string;
		refSummary: string;
	} | null>(null);

	function networkName(): string {
		if (chainId === 1) return 'Ethereum';
		if (chainId === 11155111) return 'Sepolia';
		return `Chain ${chainId}`;
	}

	function explorerTxUrl(txHash: string): string {
		if (chainId === 1) return `https://etherscan.io/tx/${txHash}`;
		if (chainId === 11155111) return `https://sepolia.etherscan.io/tx/${txHash}`;
		return `https://etherscan.io/tx/${txHash}`;
	}

	function formatDate(): string {
		const d = new Date();
		const months = [
			'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
			'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
		];
		return `${String(d.getDate()).padStart(2, '0')} ${months[d.getMonth()]} ${d.getFullYear()}`;
	}

	async function loadCategories() {
		try {
			categories = await fetchCategories();
		} catch (e) {
			submitError = e instanceof Error ? e.message : 'Failed to load categories';
		} finally {
			loadingCategories = false;
		}
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
		if (categoryId < 0) {
			submitError = 'Please select a category.';
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
			reviewHtml = DOMPurify.sanitize(wrapSections(await marked.parse(md)));
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
			const body = isRepealMode() ? buildRepealBody() : sectionsToMarkdown(sections);
			const contentHash = await hashBody(body);

			// 2. Build full document with frontmatter
			const cat = categories.find((c) => c.id === categoryId);
			const expectedVersion = cat ? cat.versionCount + 1 : 1;
			const frontmatter: Record<string, unknown> = {
				title,
				doc_type: docType,
				version: expectedVersion,
				category: cat?.name ?? '',
				registry_address: bvsRegistryAddress,
				network: networkName(),
				chain_id: chainId,
				ratified: formatDate(),
				vote_id: voteId,
				content_hash: contentHash,
				...(selectedTargetSections.length > 0 ? { target_section: targetSectionValue() } : {})
			};
			let fullDocument: string;
			if (isRepealMode()) {
				const yaml = Object.entries(frontmatter)
					.map(([k, v]) => typeof v === 'string' ? `${k}: "${v}"` : `${k}: ${v}`)
					.join('\n');
				fullDocument = `---\n${yaml}\n---\n\n${body}\n`;
			} else {
				fullDocument = buildDocument(frontmatter, sections);
			}

			// 3. Upload to Arweave
			submitStep = 'Uploading to Arweave...';
			const arweaveTxId = await uploadDocument(fullDocument);

			// 4. Record on-chain
			submitStep = 'Recording on-chain...';
			const txHash = await writeContract(config, {
				...bvsRegistryConfig,
				functionName: 'addDocument',
				args: [
					{
						categoryId: BigInt(categoryId),
						arweaveTxId,
						contentHash: hashToBytes32(contentHash),
						title,
						voteId,
						docType
					},
					buildExternalRefs()
				]
			});

			submitStep = 'Waiting for confirmation...';
			await waitForTransactionReceipt(config, { hash: txHash });

			// 5. Clear draft and show confirmation
			clearDraft();
			confirmed = true;
			let refSummary = '';
			if (selectedRefs.length > 0 && requiresReferences(docType)) {
				const relType = DOC_TYPE_TO_RELATION[docType];
				const relLabel = relationLabel(relType);
				const refVer = selectedRefs[0];
				const refDoc = categoryVersions.find(v => v.version === refVer);
				const refTitle = refDoc?.title ?? '';
				const secs = selectedTargetSections.length > 0
					? `, \u00A7${sortedSelectedSections().join(', \u00A7')}`
					: '';
				refSummary = `${relLabel} ${refVer}${refTitle ? ', ' + refTitle : ''}${secs}`;
			}

			confirmData = {
				txHash,
				arweaveTxId,
				title,
				category: cat?.name ?? '',
				version: expectedVersion,
				docTypeName: docTypeLabel(docType),
				refSummary
			};
		} catch (e) {
			submitError = e instanceof Error ? e.message : 'Upload failed';
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
			network: networkName(),
			chain_id: chainId,
			vote_id: voteId,
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
				if (frontmatter.vote_id) voteId = frontmatter.vote_id;
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
		confirmed = false;
		confirmData = null;
		title = '';
		voteId = '';
		docType = 0;
		selectedRefs = [];
		categoryVersions = [];
		selectedTargetSections = [];
		availableTargetSections = [];
		allParsedSections = [];
		newSectionsOnly = false;
		targetDocError = '';
		targetDocTitle = '';
		repealReason = '';
		sections = [createSection(1)];
		clearDraft();
		loadCategories();
	}

	onMount(() => {
		restoreDraft();
		loadCategories();
		autoSaveInterval = setInterval(saveDraft, 30_000);
	});

	onDestroy(() => {
		if (autoSaveInterval) clearInterval(autoSaveInterval);
		saveDraft();
	});
</script>

<div>
	<h1 class="text-2xl font-semibold mb-6">{confirmed ? 'New Law Recorded' : 'Propose Legislation'}</h1>

	<!-- Confirmation screen -->
	{#if confirmed && confirmData}
		<div class="border border-success/40 rounded-lg p-6">
			<h2 class="text-lg font-medium text-success mb-4">Document Recorded</h2>

			<div class="flex flex-col gap-3 text-sm">
				<div>
					<span class="text-text-muted">Title:</span>
					<span class="ml-2">{confirmData.title}</span>
				</div>
				<div>
					<span class="text-text-muted">Category:</span>
					<span class="ml-2">{confirmData.category}</span>
				</div>
				<div>
					<span class="text-text-muted">Type:</span>
					<span class="ml-2">{confirmData.docTypeName}</span>
				</div>
				<div>
					<span class="text-text-muted">Document:</span>
					<span class="ml-2">{confirmData.version}</span>
				</div>
				{#if confirmData.refSummary}
					<div>
						<span class="text-text-muted">References:</span>
						<span class="ml-2">{confirmData.refSummary}</span>
					</div>
				{/if}
				<div>
					<span class="text-text-muted">Transaction:</span>
					<a
						href={explorerTxUrl(confirmData.txHash)}
						target="_blank"
						rel="noopener noreferrer"
						class="ml-2 text-primary hover:underline font-mono text-xs"
					>
						{confirmData.txHash.slice(0, 10)}...{confirmData.txHash.slice(-8)}
					</a>
				</div>
				<div>
					<span class="text-text-muted">Arweave:</span>
					<a
						href={arweaveUrl(confirmData.arweaveTxId)}
						target="_blank"
						rel="noopener noreferrer"
						class="ml-2 text-primary hover:underline font-mono text-xs"
					>
						{confirmData.arweaveTxId}
					</a>
				</div>
			</div>

			<div class="flex gap-3 mt-6">
				<a
					href="/"
					class="text-sm px-4 py-1.5 rounded bg-primary hover:bg-primary-hover text-text transition-colors"
				>
					View in Registry
				</a>
				<button
					onclick={resetForm}
					class="text-sm px-4 py-1.5 rounded border border-border hover:bg-bg-lighter text-text-secondary transition-colors cursor-pointer"
				>
					Propose Another
				</button>
			</div>
		</div>

	<!-- Editor (visible to all, submit gated to admin) -->
	{:else}
		{#if loadingCategories}
			<p class="text-text-secondary">Loading categories...</p>
		{:else}
			{@const isAdmin = $wallet.connected && $wallet.isAdmin}

			{#if !isAdmin}
				<div class="border border-border rounded-lg p-4 text-center mb-6">
					<p class="text-text-muted text-sm">Connect as admin to submit proposals.</p>
				</div>
			{/if}

			<div class="flex flex-col gap-5" class:opacity-50={!isAdmin} class:pointer-events-none={!isAdmin}>
				<!-- Metadata form -->
				<div class="flex flex-col gap-4">
					<div>
						<label for="title" class="block text-sm text-text-secondary mb-1">Title</label>
						<input
							id="title"
							type="text"
							bind:value={title}
							disabled={!isAdmin}
							placeholder="Document title"
							class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary disabled:opacity-50"
						/>
					</div>

					<div>
						<label for="category" class="block text-sm text-text-secondary mb-1"
							>Category <Tooltip text={"Categories are defined in the smart contract by the governance authority and represent distinct legislative domains (e.g. Constitutional Law, Operational Policy, Resolutions).\n\nNew categories can be added by the governance authority as the organization's legislative structure evolves."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip></label
						>
						<select
							id="category"
							value={categoryId}
							onchange={(e) => handleCategoryChange(Number((e.target as HTMLSelectElement).value))}
							disabled={!isAdmin}
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
							disabled={!isAdmin}
							class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary disabled:opacity-50"
						>
							{#each DOC_TYPES as dt}
								<option value={dt.value}>{dt.label}</option>
							{/each}
						</select>
					</div>

					<div>
						<label for="voteid" class="block text-sm text-text-secondary mb-1"
							>Vote ID <Tooltip text={"The BVS uses Snapshot as its governance platform, where tokenholders cast gasless votes on proposals. Each proposal has a unique identifier.\n\nWhen a proposal passes and the resulting legislation is recorded here, this vote ID is stored alongside the document in the on-chain registry \u2014 creating a permanent, machine-readable link between the ratified document and the governance decision that authorized it."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip></label
						>
						<div class="flex gap-2">
							<input
								id="voteid"
								type="text"
								bind:value={voteId}
								disabled={!isAdmin}
								placeholder="Snapshot proposal ID"
								class="flex-1 bg-bg-light border border-border rounded px-3 py-2 text-sm font-mono outline-none focus:border-primary disabled:opacity-50"
							/>
							{#if isAdmin}
								<button
									onclick={fetchProposals}
									disabled={loadingProposals}
									class="px-3 py-2 rounded border border-primary text-primary hover:bg-primary hover:text-text text-sm transition-colors cursor-pointer disabled:opacity-50"
								>
									{loadingProposals ? '...' : 'Select'}
								</button>
							{/if}
						</div>
						{#if showProposals}
							<div class="mt-2 border border-border rounded bg-bg-light max-h-48 overflow-y-auto">
								{#if loadingProposals}
									<p class="text-text-muted text-xs p-3">Looking for recent proposals...</p>
								{:else if proposals.length === 0}
									<p class="text-text-muted text-xs p-3">No proposals found.</p>
								{:else}
									{#each proposals as p}
										<button
											onclick={() => selectProposal(p.id)}
											class="w-full text-left px-3 py-2 text-sm hover:bg-bg-lighter transition-colors cursor-pointer border-b border-border last:border-b-0 flex items-center justify-between"
										>
											<span class="truncate">{p.title}</span>
											<span class="text-xs text-text-muted shrink-0 ml-2">{p.state}</span>
										</button>
									{/each}
								{/if}
							</div>
						{/if}
					</div>

					{#if requiresReferences(docType)}
						<div>
							<label class="block text-sm text-text-secondary mb-1">
								{allowsMultipleReferences(docType) ? 'Select documents to consolidate' : `Select document to ${docTypeLabel(docType).toLowerCase()}`}
							</label>
							{#if categoryId < 0}
								<p class="text-text-muted text-sm">Select a category first.</p>
							{:else if loadingVersions}
								<p class="text-text-muted text-sm">Loading documents...</p>
							{:else if categoryVersions.length === 0}
								<p class="text-text-muted text-sm">No documents in this category.</p>
							{:else}
								<div class="flex flex-col gap-1 max-h-48 overflow-y-auto border border-border rounded p-2">
									{#each categoryVersions as ver}
										<button
											type="button"
											onclick={() => toggleRef(ver.version)}
											class="text-left px-3 py-1.5 rounded text-sm transition-colors cursor-pointer
												{selectedRefs.includes(ver.version) ? 'bg-primary/20 border border-primary/40' : 'hover:bg-bg-lighter border border-transparent'}"
										>
											<span class="font-mono text-text-muted mr-2">{ver.version}.</span>
											{ver.title}
										</button>
									{/each}
								</div>
							{/if}
						</div>

						<!-- Section picker (Amendment + Repeal only) -->
						{#if supportsSectionTargeting(docType) && selectedRefs.length === 1}
							<div>
								<label class="block text-sm text-text-secondary mb-1">
									Target sections <span class="text-text-muted">(select specific sections, or leave all unselected for whole document)</span>
								</label>
								{#if loadingTargetDoc}
									<p class="text-text-muted text-sm">Loading document sections...</p>
								{:else if targetDocError}
									<p class="text-text-muted text-sm">{targetDocError}</p>
								{:else if availableTargetSections.length > 0}
									<div class="flex flex-col gap-1 max-h-48 overflow-y-auto border border-border rounded p-2 {newSectionsOnly ? 'opacity-40 pointer-events-none' : ''}">
										{#each availableTargetSections as sec}
											{@const explicit = !newSectionsOnly && selectedTargetSections.includes(sec.number)}
											{@const implicit = !newSectionsOnly && isImplicitlySelected(sec.number)}
											<button
												type="button"
												onclick={() => handleSectionToggle(sec.number)}
												disabled={newSectionsOnly}
												class="text-left rounded text-sm transition-colors cursor-pointer
													{explicit ? 'bg-primary/20 border border-primary/40' : implicit ? 'bg-primary/10 border border-primary/20 opacity-60' : 'hover:bg-bg-lighter border border-transparent'}"
												style="padding: 6px 12px 6px {12 + (sec.depth - 1) * 16}px"
											>
												<span class="font-mono text-text-muted mr-2">{'\u00A7'}{sec.number}</span>
												{sec.title}
												{#if implicit}<span class="text-xs text-text-muted ml-1">(included)</span>{/if}
											</button>
										{/each}
									</div>
									{#if newSectionsOnly}
										<p class="text-xs text-text-muted mt-1">
											Adding new sections only. Use the editor to add clauses.
										</p>
									{:else if selectedTargetSections.length > 0}
										<p class="text-xs text-text-muted mt-1">
											Targeting {sortedSelectedSections().map(s => '\u00A7' + s).join(', ')}{sortedSelectedSections().some(s => availableTargetSections.some(t => t.number.startsWith(s + '.'))) ? ' (and all subsections)' : ''}{isRepealMode() ? '' : ' \u2014 editor loaded with selected sections.'}
										</p>
									{:else}
										<p class="text-xs text-text-muted mt-1">
											All sections loaded. Select specific sections to narrow the scope.
										</p>
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
							</div>
						{/if}
					{/if}
				</div>

				{#if isRepealMode()}
					<!-- Repeal UI -->
					<div class="border border-border rounded bg-bg-light p-4 flex flex-col gap-4">
						<div>
							<p class="text-sm text-text-secondary">
								{#if selectedTargetSections.length > 0}
									Repealing {sortedSelectedSections().map(s => '\u00A7' + s).join(', ')}{sortedSelectedSections().some(s => availableTargetSections.some(t => t.number.startsWith(s + '.'))) ? ' (and all subsections)' : ''} of "{targetDocTitle}"
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
					{#if isAdmin}
						<div class="flex gap-3">
							<button
								onclick={handleImport}
								class="text-sm px-4 py-1.5 rounded border border-primary text-primary hover:bg-primary hover:text-text transition-colors cursor-pointer"
							>
								Import .md
							</button>
							<button
								onclick={handleExport}
								class="text-sm px-4 py-1.5 rounded border border-primary text-primary hover:bg-primary hover:text-text transition-colors cursor-pointer"
							>
								Export .md
							</button>
							<button
								onclick={clearAll}
								class="text-sm px-4 py-1.5 rounded border border-border text-text-muted hover:border-error hover:text-error transition-colors cursor-pointer"
							>
								Clear All
							</button>
						</div>
					{/if}

					{#if importError}
						<p class="text-error text-sm">{importError}</p>
					{/if}

					<!-- Editor -->
					<Editor bind:sections amendmentMode={isAmendmentMode()} originalSectionNumbers={originalSectionNumbers()} />
				{/if}

				<!-- Submit -->
				{#if submitError}
					<p class="text-error text-sm">{submitError}</p>
				{/if}

				{#if isAdmin}
					<div class="flex items-center gap-2">
						<button
							onclick={openReview}
							disabled={submitting}
							class="self-start px-6 py-2 rounded bg-primary hover:bg-primary-hover text-text text-sm font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
						>
							{#if submitting}
								{submitStep}
							{:else}
								Review &amp; Upload
							{/if}
						</button>
						<Tooltip text={"After approval, the full document (including its metadata header containing title, version, category, and content hash) is uploaded to Arweave as a permanent file.\n\nA SHA-256 hash of the document body is computed locally, then both the Arweave transaction ID and the content hash are submitted to the registry smart contract on Ethereum.\n\nAs a result, anyone can independently fetch the document from Arweave, hash its contents, and verify it matches the on-chain record \u2014 proving the document has not been altered since ratification."} align="left" position="above"><span class="text-sm text-text-muted cursor-help">(?)</span></Tooltip>
					</div>
				{/if}
			</div>
		{/if}
	{/if}
</div>

<!-- Review modal -->
{#if showReview}
	<div
		class="fixed inset-0 bg-black/70 z-50 flex items-center justify-center p-6"
		onkeydown={(e) => { if (e.key === 'Escape') showReview = false; }}
		role="button"
		tabindex="-1"
	>
		<div class="bg-bg border border-border rounded-lg max-w-3xl w-full max-h-[85vh] flex flex-col">
			<div class="flex items-center justify-between px-6 py-4 border-b border-border">
				<h2 class="text-lg font-medium">Review: {title}</h2>
				<button
					onclick={() => showReview = false}
					class="text-text-muted hover:text-text transition-colors cursor-pointer text-lg"
				>&times;</button>
			</div>

			<div class="px-6 py-4 text-sm text-text-secondary border-b border-border flex gap-6">
				<span>Category: {categories.find(c => c.id === categoryId)?.name ?? ''}</span>
				<span>Type: {docTypeLabel(docType)}</span>
				{#if voteId}
					<span class="font-mono text-xs">Vote: {voteId.slice(0, 10)}...</span>
				{/if}
				{#if selectedTargetSections.length > 0}
					<span>Target: {selectedTargetSections.map(s => '\u00A7' + s).join(', ')}</span>
				{/if}
			</div>

			<div class="overflow-y-auto px-6 py-6 flex-1">
				<div class="doc-viewer prose prose-invert max-w-none text-sm">
					{@html reviewHtml}
				</div>
			</div>

			<div class="flex items-center justify-between px-6 py-4 border-t border-border">
				<button
					onclick={async () => {
						const md = isRepealMode() ? buildRepealBody() : sectionsToMarkdown(sections);
						try {
							await navigator.clipboard.writeText(md);
							reviewCopyLabel = 'Copied';
							setTimeout(() => reviewCopyLabel = 'Copy', 2000);
						} catch {
							reviewCopyLabel = 'Failed';
							setTimeout(() => reviewCopyLabel = 'Copy', 2000);
						}
					}}
					class="text-sm px-4 py-1.5 rounded border border-primary text-primary hover:bg-primary hover:text-text transition-colors cursor-pointer"
				>
					{reviewCopyLabel}
				</button>
				<div class="flex items-center gap-3">
					<button
						onclick={() => showReview = false}
						class="text-sm px-4 py-1.5 rounded border border-border hover:bg-bg-lighter text-text-secondary transition-colors cursor-pointer"
					>
						Back to Editor
					</button>
					<button
						onclick={handleSubmit}
						class="text-sm px-6 py-1.5 rounded bg-primary hover:bg-primary-hover text-text font-medium transition-colors cursor-pointer"
					>
						Upload &amp; Record
					</button>
				</div>
			</div>
		</div>
	</div>
{/if}
