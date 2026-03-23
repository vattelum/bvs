<script lang="ts">
	import { onMount } from 'svelte';
	import { readContract } from '@wagmi/core';
	import { marked } from 'marked';
	import DOMPurify from 'dompurify';
	import { config } from '$lib/services/ethereum';
	import { bvsRegistryConfig } from '$lib/contracts';
	import { fetchFromArweave } from '$lib/services/arweave';
	import { wrapSections } from '$lib/services/markdown';
	import { loadCategories as fetchCategories } from '$lib/services/registry';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import { docTypeLabel, relationLabel, RELATION_TYPES } from '$lib/constants/docTypes';

	const snapshotUrl = import.meta.env.VITE_SNAPSHOT_SPACE
		? `${import.meta.env.VITE_SNAPSHOT_HUB?.includes('testnet') ? 'https://testnet.snapshot.box' : 'https://snapshot.box'}/#/${import.meta.env.VITE_SNAPSHOT_SPACE}/proposal/`
		: '';

	interface Reference {
		registryAddress: string;
		chainId: number;
		categoryId: number;
		version: number;
		relationType: number;
		targetSection: string;
	}

	interface IncomingRef {
		fromVersion: number;
		relationType: number;
		targetSection: string;
	}

	interface Document {
		arweaveTxId: string;
		contentHash: string;
		title: string;
		version: number;
		timestamp: number;
		voteId: string;
		docType: number;
		references: Reference[];
		refsLoaded: boolean;
		incomingRefs: IncomingRef[];
		// Per-document content slots
		rawMarkdown: string;
		htmlContent: string;
		fetching: boolean;
		fetched: boolean;
	}

	interface Category {
		id: number;
		name: string;
		versionCount: number;
		documents: Document[];
		expanded: boolean;
		loading: boolean;
	}

	const categoryColors = [
		{ border: 'border-cat-blue', text: 'text-cat-blue', dot: 'bg-cat-blue' },
		{ border: 'border-cat-green', text: 'text-cat-green', dot: 'bg-cat-green' },
		{ border: 'border-cat-gold', text: 'text-cat-gold', dot: 'bg-cat-gold' }
	];

	let categories = $state<Category[]>([]);
	let loading = $state(true);
	let error = $state('');
	let selectedDoc = $state<{ categoryId: number; version: number } | null>(null);
	let copyLabel = $state('Copy');

	function getSelectedDoc(): Document | null {
		if (!selectedDoc) return null;
		const cat = categories.find(c => c.id === selectedDoc!.categoryId);
		return cat?.documents.find(d => d.version === selectedDoc!.version) ?? null;
	}

	async function copyMarkdown() {
		const doc = getSelectedDoc();
		if (!doc) return;
		try {
			await navigator.clipboard.writeText(doc.rawMarkdown);
			copyLabel = 'Copied';
			setTimeout(() => copyLabel = 'Copy', 2000);
		} catch {
			copyLabel = 'Failed';
			setTimeout(() => copyLabel = 'Copy', 2000);
		}
	}

	function getColors(index: number) {
		return categoryColors[index % categoryColors.length];
	}

	function formatDate(timestamp: number) {
		const d = new Date(timestamp * 1000);
		const months = [
			'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
			'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
		];
		const day = String(d.getDate()).padStart(2, '0');
		return `${day} ${months[d.getMonth()]} ${d.getFullYear()}`;
	}

	function stripFrontmatter(content: string): string {
		const match = content.match(/^---\n[\s\S]*?\n---\n([\s\S]*)$/);
		return match ? match[1].trim() : content;
	}

	async function loadCategories() {
		try {
			const cats = await fetchCategories();
			categories = cats.map(c => ({
				...c,
				documents: [],
				expanded: false,
				loading: false
			}));
		} catch (e) {
			error = e instanceof Error ? e.message : 'Failed to load registry';
		} finally {
			loading = false;
		}
	}

	async function toggleCategory(index: number) {
		const cat = categories[index];

		if (cat.expanded) {
			categories[index] = { ...cat, expanded: false };
			selectedDoc = null;
			return;
		}

		categories[index] = { ...cat, expanded: true, loading: true };

		if (cat.versionCount > 0 && cat.documents.length === 0) {
			try {
				const history = (await readContract(config, {
					...bvsRegistryConfig,
					functionName: 'getHistory',
					args: [BigInt(cat.id)]
				})) as Array<{
					arweaveTxId: string;
					contentHash: string;
					title: string;
					version: bigint;
					timestamp: bigint;
					voteId: string;
					docType: number;
				}>;

				const docs: Document[] = history.map((d) => ({
					arweaveTxId: d.arweaveTxId,
					contentHash: d.contentHash,
					title: d.title,
					version: Number(d.version),
					timestamp: Number(d.timestamp),
					voteId: d.voteId,
					docType: d.docType,
					references: [],
					refsLoaded: false,
					incomingRefs: [],
					rawMarkdown: '',
					htmlContent: '',
					fetching: false,
					fetched: false
				}));

				categories[index] = {
					...categories[index],
					documents: docs,
					loading: false
				};

				loadAllReferences(index);
			} catch {
				categories[index] = { ...categories[index], loading: false };
			}
		} else {
			categories[index] = { ...categories[index], loading: false };
		}
	}

	async function loadAllReferences(catIndex: number) {
		const cat = categories[catIndex];
		if (!cat || cat.documents.length === 0) return;

		try {
			const allRefs = await Promise.all(
				cat.documents.map((doc) =>
					readContract(config, {
						...bvsRegistryConfig,
						functionName: 'getReferences',
						args: [BigInt(cat.id), BigInt(doc.version)]
					}).catch(() => [])
				)
			);

			const updatedDocs = cat.documents.map((doc, i) => {
				const refs = (allRefs[i] as Array<{
					registryAddress: string;
					chainId: bigint;
					categoryId: bigint;
					version: bigint;
					relationType: number;
					targetSection: string;
				}>);
				return {
					...doc,
					references: refs.map((r) => ({
						registryAddress: r.registryAddress,
						chainId: Number(r.chainId),
						categoryId: Number(r.categoryId),
						version: Number(r.version),
						relationType: r.relationType,
						targetSection: r.targetSection
					})),
					refsLoaded: true
				};
			});

			for (const doc of updatedDocs) {
				for (const ref of doc.references) {
					if (ref.categoryId !== cat.id) continue;
					const target = updatedDocs.find((d) => d.version === ref.version);
					if (target) {
						target.incomingRefs = [
							...target.incomingRefs,
							{
								fromVersion: doc.version,
								relationType: ref.relationType,
								targetSection: ref.targetSection
							}
						];
					}
				}
			}

			categories[catIndex] = { ...categories[catIndex], documents: updatedDocs };
		} catch {
			// References failed to load — documents still display without tags
		}
	}

	/** Whether a document is superseded (full repeal or revision) */
	function isSuperseded(doc: Document): boolean {
		return doc.incomingRefs.some(
			(r) => (r.relationType === RELATION_TYPES.REPEALS && !r.targetSection) ||
				r.relationType === RELATION_TYPES.REVISES
		);
	}

	/** Format an incoming reference as a display tag */
	function incomingRefLabel(ref: IncomingRef): string {
		if (ref.relationType === RELATION_TYPES.AMENDS) {
			return ref.targetSection ? `\u00A7${ref.targetSection} amended by ${ref.fromVersion}` : `Amended by ${ref.fromVersion}`;
		}
		if (ref.relationType === RELATION_TYPES.REPEALS) {
			if (ref.targetSection) return `\u00A7${ref.targetSection} repealed by ${ref.fromVersion}`;
			return `Repealed by ${ref.fromVersion}`;
		}
		if (ref.relationType === RELATION_TYPES.REVISES) {
			return `Replaced by ${ref.fromVersion}`;
		}
		if (ref.relationType === RELATION_TYPES.CODIFIES) {
			return `Codified in ${ref.fromVersion}`;
		}
		return `Referenced by ${ref.fromVersion}`;
	}

	/** Look up a document title within a category */
	function docTitle(categoryId: number, version: number): string {
		const cat = categories.find(c => c.id === categoryId);
		const doc = cat?.documents.find(d => d.version === version);
		return doc?.title ?? '';
	}

	function findDoc(categoryId: number, version: number): { catIdx: number; docIdx: number } | null {
		const catIdx = categories.findIndex(c => c.id === categoryId);
		if (catIdx === -1) return null;
		const docIdx = categories[catIdx].documents.findIndex(d => d.version === version);
		if (docIdx === -1) return null;
		return { catIdx, docIdx };
	}

	async function viewDocument(categoryId: number, version: number) {
		// Toggle off
		if (selectedDoc?.categoryId === categoryId && selectedDoc?.version === version) {
			selectedDoc = null;
			copyLabel = 'Copy';
			return;
		}

		selectedDoc = { categoryId, version };
		copyLabel = 'Copy';

		const loc = findDoc(categoryId, version);
		if (!loc) return;
		const doc = categories[loc.catIdx].documents[loc.docIdx];

		// Already fetched — nothing to do
		if (doc.fetched) return;
		// Already fetching — just select it, result will appear when ready
		if (doc.fetching) return;

		// Start fetch
		categories[loc.catIdx].documents[loc.docIdx] = { ...doc, fetching: true };

		try {
			const text = await fetchFromArweave(doc.arweaveTxId, doc.contentHash);
			const body = stripFrontmatter(text);
			const html = DOMPurify.sanitize(wrapSections(await marked.parse(body)));

			// Write result to the document's own slot
			const current = findDoc(categoryId, version);
			if (current) {
				categories[current.catIdx].documents[current.docIdx] = {
					...categories[current.catIdx].documents[current.docIdx],
					rawMarkdown: body,
					htmlContent: html,
					fetching: false,
					fetched: true
				};
			}
		} catch {
			const current = findDoc(categoryId, version);
			if (current) {
				categories[current.catIdx].documents[current.docIdx] = {
					...categories[current.catIdx].documents[current.docIdx],
					htmlContent: '<p class="text-text-muted">Content unavailable. The document may still be confirming on the Arweave network \u2014 this can take up to 30 minutes after upload. Try again shortly.</p>',
					fetching: false,
					fetched: true
				};
			}
		}
	}

	onMount(loadCategories);
</script>

<div>
	<h1 class="text-2xl font-semibold mb-6">Blockchain Voting System — Registry <Tooltip text={"The BVS stores an organization's legal documents as permanent, immutable files on Arweave decentralized data storage.\n\nBoth the document's content hash (SHA-256) and Arweave transaction ID are then recorded in a Solidity smart contract on Ethereum, creating a tamper-proof registry.\n\nThe on-chain record includes structured metadata (title, category, version, vote reference), making the entire registry machine-readable and verifiable by any application or contract."} align="left"><span class="text-sm font-normal text-text-muted cursor-help">(?)</span></Tooltip></h1>

	{#if loading}
		<p class="text-text-secondary">Loading categories...</p>
	{:else if error}
		<p class="text-error">{error}</p>
	{:else if categories.length === 0}
		<p class="text-text-secondary">No categories found.</p>
	{:else}
		<div class="flex flex-col gap-4">
			{#each categories as cat, i}
				{@const colors = getColors(i)}
				<div class="border {colors.border} border-opacity-40 rounded-lg bg-bg-light">
					<button
						onclick={() => toggleCategory(i)}
						class="w-full flex items-center justify-between px-5 py-4 cursor-pointer"
					>
						<div class="flex items-center gap-3">
							<span class="w-2.5 h-2.5 rounded-full {colors.dot}"></span>
							<span class="font-medium {colors.text}">{cat.name}</span>
						</div>
						<div class="flex items-center gap-3">
							<span class="text-sm text-text-muted">
								{cat.versionCount}
								{cat.versionCount === 1 ? 'document' : 'documents'}
							</span>
							<span
								class="text-text-muted text-xs transition-transform {cat.expanded
									? 'rotate-180'
									: ''}"
							>
								&#9660;
							</span>
						</div>
					</button>

					{#if cat.expanded}
						<div class="border-t border-border px-5 py-4">
							{#if cat.loading}
								<p class="text-text-secondary text-sm">Loading documents...</p>
							{:else if cat.versionCount === 0}
								<p class="text-text-muted text-sm">No documents recorded yet.</p>
							{:else}
								<div class="flex flex-col gap-2">
									{#each cat.documents as doc}
										{@const isSelected =
											selectedDoc?.categoryId === cat.id &&
											selectedDoc?.version === doc.version}
										<div>
											<button
												onclick={() =>
													viewDocument(cat.id, doc.version)}
												class="w-full text-left px-3 py-2 rounded transition-colors cursor-pointer
												{isSelected ? 'bg-bg-lighter' : 'hover:bg-bg-lighter'}"
											>
												<div class="flex items-center justify-between">
													<div class="flex items-center gap-3 flex-wrap">
														<span class="text-xs text-text-muted font-mono w-5 text-right shrink-0"
															>{doc.version}.</span
														>
														<span class="text-sm {isSuperseded(doc) ? 'line-through text-text-muted' : ''}">{doc.title}</span>
														<span class="text-xs px-1.5 py-0.5 rounded bg-bg-lighter text-text-muted">{docTypeLabel(doc.docType)}</span>
														{#each doc.incomingRefs as iref}
															<span class="text-xs px-1.5 py-0.5 rounded bg-bg-lighter text-text-secondary">{incomingRefLabel(iref)}</span>
														{/each}
													</div>
													<div class="flex items-center gap-3">
													{#if doc.voteId && snapshotUrl}
														<a
															href="{snapshotUrl}{doc.voteId}"
															target="_blank"
															rel="noopener noreferrer"
															class="text-xs text-primary hover:underline"
															onclick={(e) => e.stopPropagation()}
														>
															See vote
														</a>
													{/if}
													<span class="text-xs text-text-muted">
														Ratified {formatDate(doc.timestamp)}
													</span>
												</div>
												</div>
											</button>

											{#if isSelected}
												<div
													class="mt-2 mb-2 mx-3 p-4 rounded bg-bg border border-border"
												>
													{#if doc.fetching}
														<p class="text-text-secondary text-sm">
															Loading document from permanent storage... This may take a moment (sometimes several minutes).
														</p>
													{:else if doc.fetched}
														{#if doc.references.length > 0}
															<div class="mb-3 pb-3 border-b border-border">
																<span class="text-xs text-text-muted">References:</span>
																{#each doc.references as ref}
																	<span class="text-xs ml-2">
																		{relationLabel(ref.relationType)} {ref.version}{#if docTitle(ref.categoryId, ref.version)}, {docTitle(ref.categoryId, ref.version)}{/if}{#if ref.targetSection}, {'\u00A7'}{ref.targetSection}{/if}
																	</span>
																{/each}
															</div>
														{/if}
														<div class="doc-viewer prose prose-invert max-w-none text-sm">
															{@html doc.htmlContent}
														</div>
														<div class="flex justify-end mt-3">
															<button
																onclick={copyMarkdown}
																class="text-xs px-3 py-1 rounded border border-border hover:bg-bg-lighter text-text-muted hover:text-text transition-colors cursor-pointer"
															>
																{copyLabel}
															</button>
														</div>
													{:else}
														<p class="text-text-secondary text-sm">
															Loading document from permanent storage... This may take a moment (sometimes several minutes).
														</p>
													{/if}
												</div>
											{/if}
										</div>
									{/each}
								</div>
							{/if}
						</div>
					{/if}
				</div>
			{/each}
		</div>
	{/if}
</div>
