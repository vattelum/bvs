<script lang="ts">
	import { tick } from 'svelte';
	import {
		type Section,
		createSection,
		computeSectionNumber,
		sectionsToMarkdown,
		renderSectionedMarkdown,
		collectAllNumbers,
		nextChildNumber,
		nextSiblingNumber,
		sortByFixedNumber
	} from '$lib/services/markdown';

	let {
		sections = $bindable<Section[]>([]),
		amendmentMode = false,
		originalSectionNumbers = [] as string[],
		lockedSections = [] as number[]
	}: {
		sections: Section[];
		amendmentMode?: boolean;
		originalSectionNumbers?: string[];
		/** Top-level section numbers locked on the target document. Cascade:
		 *  locking §3 also locks §3.1, §3.2.A, etc. Editor renders matched
		 *  sections as disabled with a Locked badge. Empty for non-amend modes
		 *  or when the target has no on-chain restrictions. */
		lockedSections?: number[];
	} = $props();

	function rootSectionNumber(fixedNumber: string | undefined): number | null {
		if (!fixedNumber) return null;
		const m = fixedNumber.match(/^(\d+)/);
		return m ? Number(m[1]) : null;
	}

	function isSectionLocked(fixedNumber: string | undefined): boolean {
		if (lockedSections.length === 0) return false;
		// `0` is the entire-document sentinel — every section is locked.
		if (lockedSections.includes(0)) return true;
		const root = rootSectionNumber(fixedNumber);
		if (root === null) return false;
		return lockedSections.includes(root);
	}

	let preview = $state(false);
	let previewHtml = $state('');
	let activeTextarea: HTMLTextAreaElement | null = $state(null);
	let activeSectionIdx: number | null = $state(null);

	/** The minimum depth among selected sections — sibling add only allowed at this depth */
	function minSelectedDepth(): number {
		if (!amendmentMode || sections.length === 0) return 1;
		return Math.min(...sections.map(s => s.depth));
	}

	async function togglePreview() {
		if (!preview) {
			// No cache key — the editor body changes on every keystroke, so caching
			// the rendered HTML would be wrong. The shared helper handles the
			// marked + DOMPurify + section-wrap pipeline; we just skip the cache.
			previewHtml = await renderSectionedMarkdown(sectionsToMarkdown(sections));
		}
		preview = !preview;
	}

	/** Find the index after the last child/descendant of sections[index] */
	function endOfSubtree(index: number): number {
		const depth = sections[index].depth;
		let end = index + 1;
		while (end < sections.length && sections[end].depth > depth) {
			end++;
		}
		return end;
	}

	function addSibling(index: number) {
		if (amendmentMode) {
			const section = sections[index];
			if (!section.fixedNumber) return;
			const allNums = collectAllNumbers(sections, originalSectionNumbers);
			const result = nextSiblingNumber(section.fixedNumber, section.depth, allNums);
			const newSection = createSection(result.depth);
			newSection.fixedNumber = result.number;
			sections = sortByFixedNumber([...sections, newSection]);
		} else {
			const depth = sections[index].depth;
			const insertAt = endOfSubtree(index);
			const newSection = createSection(depth);
			sections = [...sections.slice(0, insertAt), newSection, ...sections.slice(insertAt)];
		}
	}

	function addChild(index: number) {
		const section = sections[index];
		if (section.depth >= 3) return;

		if (amendmentMode) {
			if (!section.fixedNumber) return;
			const allNums = collectAllNumbers(sections, originalSectionNumbers);
			const result = nextChildNumber(section.fixedNumber, section.depth, allNums);
			if (!result) return;
			const newSection = createSection(result.depth);
			newSection.fixedNumber = result.number;
			sections = sortByFixedNumber([...sections, newSection]);
		} else {
			const insertAt = endOfSubtree(index);
			const newSection = createSection((section.depth + 1) as 1 | 2 | 3);
			sections = [...sections.slice(0, insertAt), newSection, ...sections.slice(insertAt)];
		}
	}

	function addTopLevel() {
		if (amendmentMode) {
			const allNums = collectAllNumbers(sections, originalSectionNumbers);
			const topNums = allNums.filter(n => !n.includes('.')).map(n => parseInt(n)).filter(n => !isNaN(n));
			const next = topNums.length > 0 ? Math.max(...topNums) + 1 : 1;
			const newSection = createSection(1);
			newSection.fixedNumber = String(next);
			sections = sortByFixedNumber([...sections, newSection]);
		} else {
			sections = [...sections, createSection(1)];
		}
	}

	function removeSection(index: number) {
		if (amendmentMode) {
			// In amendment mode, just remove this one section (no cascading children)
			sections = [...sections.slice(0, index), ...sections.slice(index + 1)];
		} else {
			const depth = sections[index].depth;
			let end = index + 1;
			while (end < sections.length && sections[end].depth > depth) {
				end++;
			}
			sections = [...sections.slice(0, index), ...sections.slice(end)];
		}
	}

	function onTextareaFocus(el: HTMLTextAreaElement, index: number) {
		activeTextarea = el;
		activeSectionIdx = index;
	}

	function applyFormat(prefix: string, suffix: string) {
		if (!activeTextarea || activeSectionIdx === null) return;
		const ta = activeTextarea;
		const idx = activeSectionIdx;
		const start = ta.selectionStart;
		const end = ta.selectionEnd;
		const text = sections[idx].content;
		const selected = text.slice(start, end);

		sections[idx] = {
			...sections[idx],
			content: text.slice(0, start) + prefix + selected + suffix + text.slice(end)
		};

		tick().then(() => {
			ta.focus();
			ta.setSelectionRange(start + prefix.length, end + prefix.length);
		});
	}

	function applyList() {
		if (!activeTextarea || activeSectionIdx === null) return;
		const ta = activeTextarea;
		const idx = activeSectionIdx;
		const start = ta.selectionStart;
		const end = ta.selectionEnd;
		const text = sections[idx].content;

		const before = text.lastIndexOf('\n', start - 1) + 1;
		const after = text.indexOf('\n', end);
		const lineEnd = after === -1 ? text.length : after;
		const selectedLines = text.slice(before, lineEnd);
		const prefixed = selectedLines
			.split('\n')
			.map((l) => `- ${l}`)
			.join('\n');

		sections[idx] = {
			...sections[idx],
			content: text.slice(0, before) + prefixed + text.slice(lineEnd)
		};

		tick().then(() => {
			ta.focus();
		});
	}

	function depthIndent(depth: number): string {
		return `${(depth - 1) * 1.5}rem`;
	}
</script>

<div class="flex flex-col gap-4">
	<!-- Toolbar -->
	<div class="flex items-center gap-2 border-b border-border pb-3">
		<button
			onclick={togglePreview}
			class="text-sm px-3 py-1 rounded border border-border hover:bg-bg-lighter transition-colors cursor-pointer
				{preview ? 'bg-bg-lighter text-text' : 'text-text-secondary'}"
		>
			{preview ? 'Edit' : 'Preview'}
		</button>

		{#if !preview}
			<div class="w-px h-5 bg-border mx-1"></div>
			<button
				onclick={() => applyFormat('**', '**')}
				class="text-sm px-2 py-1 rounded hover:bg-bg-lighter text-text-secondary hover:text-text transition-colors cursor-pointer font-bold"
				title="Bold"
			>
				B
			</button>
			<button
				onclick={() => applyFormat('*', '*')}
				class="text-sm px-2 py-1 rounded hover:bg-bg-lighter text-text-secondary hover:text-text transition-colors cursor-pointer italic"
				title="Italic"
			>
				I
			</button>
			<button
				onclick={applyList}
				class="text-sm px-2 py-1 rounded hover:bg-bg-lighter text-text-secondary hover:text-text transition-colors cursor-pointer"
				title="Bullet list"
			>
				&bull; List
			</button>
		{/if}
	</div>

	<!-- Preview mode -->
	{#if preview}
		<div class="doc-viewer prose prose-invert max-w-none text-sm p-4 border border-border rounded bg-bg">
			{@html previewHtml}
		</div>

	<!-- Edit mode -->
	{:else}
		{#if sections.length === 0}
			<div class="text-center py-8">
				<button
					onclick={addTopLevel}
					class="text-sm px-4 py-1.5 rounded bg-primary hover:bg-primary-hover text-text transition-colors cursor-pointer"
				>
					Add new section
				</button>
			</div>
		{:else}
			<div class="flex flex-col gap-3">
				{#each sections as section, i (section.id)}
					{@const num = section.fixedNumber ? `§${section.fixedNumber}` : computeSectionNumber(sections, i)}
					{@const canAddSibling = !amendmentMode || section.depth === minSelectedDepth()}
					{@const locked = amendmentMode && isSectionLocked(section.fixedNumber)}
					<div
						class="border-l-2 rounded-r {locked ? 'border-error/50 bg-bg-light/40' : 'border-primary bg-bg-light'}"
						style="margin-left: {depthIndent(section.depth)}"
					>
						<div class="px-4 py-3">
							<!-- Section header -->
							<div class="flex items-center gap-2 mb-2">
								<span class="text-xs font-mono text-text-muted shrink-0">{num}</span>
								<input
									type="text"
									bind:value={section.title}
									disabled={locked}
									placeholder="Section title"
									class="flex-1 bg-bg border border-border rounded px-2 py-1 focus:border-primary outline-none text-sm text-text placeholder:text-text-muted disabled:opacity-50 disabled:cursor-not-allowed"
								/>
								{#if locked}
									<span class="text-[10px] uppercase tracking-wider text-error border border-error/40 rounded px-1.5 py-0.5 shrink-0" title="This section is locked on-chain — addDocument will revert SectionLocked.">Locked</span>
								{/if}
								<div class="flex items-center gap-1.5 shrink-0">
									{#if canAddSibling && !locked}
										<button
											onclick={() => addSibling(i)}
											class="text-xs px-2.5 py-1 rounded border border-border hover:bg-bg-lighter text-text-muted hover:text-text transition-colors cursor-pointer"
											title="Add section at same level"
										>
											+ Section
										</button>
									{/if}
									{#if section.depth < 3 && !locked}
										<button
											onclick={() => addChild(i)}
											class="text-xs px-2.5 py-1 rounded border border-border hover:bg-bg-lighter text-text-muted hover:text-text transition-colors cursor-pointer"
											title="Add subsection inside this section"
										>
											+ Sub
										</button>
									{/if}
									<button
										onclick={() => removeSection(i)}
										class="text-xs px-2.5 py-1 rounded border border-border hover:bg-bg-lighter text-text-muted hover:text-error transition-colors cursor-pointer"
										title="Remove section"
									>
										Remove
									</button>
								</div>
							</div>

							<!-- Section content -->
							<textarea
								bind:value={section.content}
								onfocus={(e) => onTextareaFocus(e.currentTarget as HTMLTextAreaElement, i)}
								disabled={locked}
								placeholder={locked ? 'Locked — cannot be amended on-chain.' : 'Section content...'}
								rows="3"
								class="w-full bg-bg border border-border rounded p-2 text-sm text-text placeholder:text-text-muted outline-none focus:border-primary resize-y font-mono disabled:opacity-50 disabled:cursor-not-allowed"
							></textarea>
						</div>
					</div>
				{/each}
			</div>

			{#if !amendmentMode || minSelectedDepth() === 1}
				<button
					onclick={addTopLevel}
					class="text-sm text-text-muted hover:text-text transition-colors cursor-pointer mt-2"
				>
					+ Add section
				</button>
			{/if}
		{/if}
	{/if}
</div>
