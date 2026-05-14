<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { writeContract, waitForTransactionReceipt } from '@wagmi/core';
	import { parseEventLogs } from 'viem';
	import BVSRegistryAbi from '$lib/contracts/BVSRegistry.abi.json';
	import { fetchFromArweave } from '$lib/services/arweave';
	import ActiveProposalCard from '$lib/components/ActiveProposalCard.svelte';
	import PassedProposalCard from '$lib/components/PassedProposalCard.svelte';
	import { renderSectionedMarkdown } from '$lib/services/markdown';
	import { loadCategories, loadDocuments } from '$lib/services/registry';
	import { wallet } from '$lib/stores/wallet';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import LoadingButton from '$lib/components/LoadingButton.svelte';
	import { config } from '$lib/services/wallet-config';
	import { bvsRegistryConfig } from '$lib/contracts';
	import { docTypeLabel } from '$lib/constants/docTypes';
	import { parseVariableSchema, type TemplateVariable } from '$lib/services/template-variables';
	import { stripFrontmatter } from '$lib/services/format';
	import {
		getProposals,
		getApprovalThreshold,
		getParticipationQuorum,
		getTotalSupply,
		getAdminDecisions,
		hasVoted as checkHasVoted,
		vote as castVote,
		ProposalStatus,
		VoteChoice,
		statusLabel,
		statusClass,
		approvalVotesNeeded,
		participationVotesNeeded,
		type ProposalInfo,
		type StrategyQuorums,
		type DecisionRecord
	} from '$lib/services/snapshot-x';
	import { executionStrategyAddress } from '$lib/contracts';
	import { chainIdToBlockTime } from '$lib/constants/networks';
	import { showToast } from '$lib/stores/toasts';

	// Per-chain average block time — Sepolia/Mainnet ~12s, Base/Polygon ~2s,
	// Arbitrum ~0.25s. Hardcoding 12 here would make the /vote countdown wrong
	// by Nx on any non-Ethereum-style chain.
	const BLOCK_TIME_SECONDS = chainIdToBlockTime(Number(import.meta.env.VITE_CHAIN_ID));

	interface ProposalCard extends ProposalInfo {
		categoryName: string;
		documentLabel: string;
		userVoted: boolean;
		htmlContent: string;
		templateVariables: TemplateVariable[];
		fetching: boolean;
		fetched: boolean;
		decision: DecisionRecord | null;
	}

	let loading = $state(true);
	let error = $state('');
	let activeProposals = $state<ProposalCard[]>([]);
	let passedProposals = $state<ProposalCard[]>([]);
	let historyProposals = $state<ProposalCard[]>([]);
	let expandedId = $state<number | null>(null);
	let historyExpanded = $state(false);
	let historyLoaded = $state(false);

	let totalSupply = $state(0n);
	let strategyApproval = $state(0);
	let strategyParticipation = $state(0);
	let currentBlock = $state(0);

	const quorums = $derived<StrategyQuorums>({
		approvalPct: {
			[executionStrategyAddress.toLowerCase()]: strategyApproval
		},
		participationPct: {
			[executionStrategyAddress.toLowerCase()]: strategyParticipation
		}
	});

	let votingId = $state<number | null>(null);
	let approvingId = $state<number | null>(null);
	let rejectingId = $state<number | null>(null);
	let rejectModalProposalId = $state<number | null>(null);
	let rejectReason = $state('');

	let categoryNames = $state<Record<number, string>>({});
	let documentTitles = $state<Record<string, string>>({});
	let tickNow = $state(Date.now());
	let tickInterval: ReturnType<typeof setInterval> | null = null;
	let blockRefreshInterval: ReturnType<typeof setInterval> | null = null;
	let blockFetchedAt = $state(0);


	/** Estimated seconds remaining until a given block, calibrated against last block fetch. */
	function secondsUntilBlock(blockNumber: number): number {
		if (currentBlock <= 0) return 0;
		const elapsed = (tickNow - blockFetchedAt) / 1000;
		const blockSeconds = (blockNumber - currentBlock) * BLOCK_TIME_SECONDS;
		return Math.max(0, blockSeconds - elapsed);
	}

	function blockToGMT(blockNumber: number): string {
		if (currentBlock <= 0) return `Block ${blockNumber}`;
		const remaining = secondsUntilBlock(blockNumber);
		const date = new Date(tickNow + remaining * 1000);
		const day = String(date.getUTCDate()).padStart(2, '0');
		const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
		const hours = String(date.getUTCHours()).padStart(2, '0');
		const mins = String(date.getUTCMinutes()).padStart(2, '0');
		return `${day} ${months[date.getUTCMonth()]} ${date.getUTCFullYear()} ${hours}:${mins} GMT`;
	}

	function timeRemaining(blockNumber: number): string {
		if (currentBlock <= 0) return '';
		const totalSeconds = secondsUntilBlock(blockNumber);
		if (totalSeconds <= 0) return 'ended';
		const days = Math.floor(totalSeconds / 86400);
		const hours = Math.floor((totalSeconds % 86400) / 3600);
		const minutes = Math.floor((totalSeconds % 3600) / 60);
		const seconds = Math.floor(totalSeconds % 60);
		const parts: string[] = [];
		if (days > 0) parts.push(`${days}d`);
		if (hours > 0) parts.push(`${hours}h`);
		if (minutes > 0) parts.push(`${minutes}m`);
		if (days === 0) parts.push(`${seconds}s`);
		if (parts.length === 0) parts.push('0s');
		return parts.join(' ');
	}

	function buildRestrictionsText(p: ProposalInfo): string {
		const r = p.metadata?.restrictions;
		if (!r) return '';
		const isEntire = r.lockedSections.includes(0);
		const sectionsLabel = isEntire
			? 'Entire document'
			: r.lockedSections.length > 0
				? r.lockedSections.map((s) => '§' + s).join(', ')
				: '';
		const timeLabel = r.minTimeBetweenAmendments > 0
			? `${Math.round(r.minTimeBetweenAmendments / 86400)}-day window`
			: 'no time gate';
		if (!sectionsLabel) return timeLabel;
		return `${sectionsLabel}, ${timeLabel}`;
	}

	function buildCard(p: ProposalInfo, voted: boolean, decision: DecisionRecord | null): ProposalCard {
		const catName = p.metadata ? (categoryNames[p.metadata.categoryId] ?? `Category ${p.metadata.categoryId}`) : 'Unknown';
		let docLabel = '';
		if (p.metadata) {
			if (p.metadata.documentId === 0) {
				docLabel = `New document in ${catName}`;
			} else {
				const titleKey = `${p.metadata.categoryId}-${p.metadata.documentId}`;
				const docTitle = documentTitles[titleKey];
				docLabel = docTitle
					? `${docTypeLabel(p.metadata.docType)} \u2014 ${catName}, Doc ${p.metadata.documentId}: ${docTitle}`
					: `${docTypeLabel(p.metadata.docType)} \u2014 ${catName}, Doc ${p.metadata.documentId}`;
			}
		}
		return {
			...p,
			categoryName: catName,
			documentLabel: docLabel,
			userVoted: voted,
			htmlContent: '',
			templateVariables: [],
			fetching: false,
			fetched: false,
			decision
		};
	}

	async function loadPage() {
		try {
			// Load categories for name mapping
			const cats = await loadCategories();
			const names: Record<number, string> = {};
			for (const c of cats) names[c.id] = c.name;
			categoryNames = names;

			const [allProposals, supply, approvalPct, participationPct, decisions] = await Promise.all([
				getProposals(),
				getTotalSupply(),
				getApprovalThreshold(executionStrategyAddress).catch(() => 0),
				getParticipationQuorum(executionStrategyAddress).catch(() => 0),
				getAdminDecisions().catch(() => ({} as Record<number, DecisionRecord>))
			]);

			totalSupply = supply;
			strategyApproval = approvalPct;
			strategyParticipation = participationPct;

			// Get current block
			const client = (await import('$lib/services/wallet-config')).getClient();
			if (client) {
				const block = await client.getBlockNumber();
				currentBlock = Number(block);
				blockFetchedAt = Date.now();
			}

			// Load document titles for amendments (documentId > 0)
			const amendedDocs = new Set<string>();
			for (const p of allProposals) {
				if (p.metadata && p.metadata.documentId > 0) {
					amendedDocs.add(`${p.metadata.categoryId}-${p.metadata.documentId}`);
				}
			}
			if (amendedDocs.size > 0) {
				const titles: Record<string, string> = {};
				for (const key of amendedDocs) {
					const [catId, docId] = key.split('-').map(Number);
					try {
						const docs = await loadDocuments(catId);
						const doc = docs.find(d => d.documentId === docId);
						if (doc) titles[key] = doc.latestTitle;
					} catch { /* skip */ }
				}
				documentTitles = titles;
			}

			// Bucketing — admin decision (approve/reject) sends a proposal straight to History
			// regardless of Snapshot X status; Snapshot X never reaches Executed in BVS because
			// no one calls Space.execute(), so the SX-only history path is for cancellations.
			const isDecided = (p: ProposalInfo) => !!decisions[p.proposalId];
			const active = allProposals.filter(p =>
				!isDecided(p) && (
					p.status === ProposalStatus.VotingPeriod ||
					p.status === ProposalStatus.VotingPeriodAccepted ||
					p.status === ProposalStatus.VotingDelay
				)
			);
			const passed = allProposals.filter(p =>
				!isDecided(p) && p.status === ProposalStatus.Accepted
			);
			const history = allProposals.filter(p =>
				isDecided(p) ||
				p.status === ProposalStatus.Executed ||
				p.status === ProposalStatus.Rejected ||
				p.status === ProposalStatus.Cancelled
			);

			let votedMap: Record<number, boolean> = {};
			if ($wallet.connected && $wallet.address) {
				const checks = await Promise.all(
					active.map(p => checkHasVoted(p.proposalId, $wallet.address!).catch(() => false))
				);
				active.forEach((p, i) => { votedMap[p.proposalId] = checks[i]; });
			}

			activeProposals = active.map(p => buildCard(p, votedMap[p.proposalId] ?? false, decisions[p.proposalId] ?? null));
			passedProposals = passed.map(p => buildCard(p, false, decisions[p.proposalId] ?? null));
			historyProposals = history.map(p => buildCard(p, false, decisions[p.proposalId] ?? null));
			historyLoaded = true;
		} catch (e) {
			error = e instanceof Error ? e.message : 'Failed to load proposals';
		} finally {
			loading = false;
		}
	}

	function toggleExpand(proposalId: number) {
		if (expandedId === proposalId) {
			expandedId = null;
			return;
		}
		expandedId = proposalId;
		// Fetch document content if not already loaded
		const card = [...activeProposals, ...passedProposals, ...historyProposals].find(p => p.proposalId === proposalId);
		if (card && !card.fetched && !card.fetching && card.metadata?.contentUri) {
			fetchDocument(proposalId, card.metadata.contentUri);
		}
	}

	async function fetchDocument(proposalId: number, contentUri: string) {
		const updateCard = (list: ProposalCard[], update: Partial<ProposalCard>): ProposalCard[] =>
			list.map(p => p.proposalId === proposalId ? { ...p, ...update } : p);

		activeProposals = updateCard(activeProposals, { fetching: true });
		passedProposals = updateCard(passedProposals, { fetching: true });
		historyProposals = updateCard(historyProposals, { fetching: true });

		try {
			const card = [...activeProposals, ...passedProposals, ...historyProposals].find(p => p.proposalId === proposalId);
			const contentHash = card?.metadata?.contentHash ?? '';
			const text = await fetchFromArweave(contentUri, contentHash);
			const body = stripFrontmatter(text);
			const html = await renderSectionedMarkdown(body, contentHash || undefined);
			const vars = parseVariableSchema(text);
			const update = { htmlContent: html, templateVariables: vars, fetching: false, fetched: true };
			activeProposals = updateCard(activeProposals, update);
			passedProposals = updateCard(passedProposals, update);
			historyProposals = updateCard(historyProposals, update);
		} catch {
			const update = {
				htmlContent: '<p class="text-text-muted">Content unavailable. The document may still be confirming on Arweave.</p>',
				fetching: false,
				fetched: true
			};
			activeProposals = updateCard(activeProposals, update);
			passedProposals = updateCard(passedProposals, update);
			historyProposals = updateCard(historyProposals, update);
		}
	}

	async function handleVote(proposalId: number, choice: VoteChoice) {
		if (!$wallet.address) return;
		votingId = proposalId;

		try {
			await castVote($wallet.address, proposalId, choice);
			showToast('success', `Vote recorded on proposal #${proposalId}.`);
			// Update card state
			activeProposals = activeProposals.map(p =>
				p.proposalId === proposalId ? { ...p, userVoted: true } : p
			);
			// Refresh vote counts
			await loadPage();
		} catch (e) {
			const msg = e instanceof Error ? e.message : 'Vote failed';
			if (msg.toLowerCase().includes('user rejected') || msg.toLowerCase().includes('denied')) {
				showToast('error', 'Transaction was rejected in wallet.');
			} else if (msg.toLowerCase().includes('already voted')) {
				showToast('error', 'You have already voted on this proposal.');
				activeProposals = activeProposals.map(p =>
					p.proposalId === proposalId ? { ...p, userVoted: true } : p
				);
			} else {
				showToast('error', msg);
			}
		} finally {
			votingId = null;
		}
	}

	async function handleApprove(proposal: ProposalCard) {
		if (!proposal.metadata) {
			showToast('error', 'Proposal metadata could not be decoded.');
			return;
		}
		approvingId = proposal.proposalId;
		try {
			const m = proposal.metadata;
			const rawHash = m.contentHash ?? '';
			const contentHash = (rawHash.startsWith('0x') ? rawHash : `0x${rawHash}`) as `0x${string}`;
			const input = {
				categoryId: BigInt(m.categoryId),
				documentId: BigInt(m.documentId),
				contentUri: m.contentUri,
				contentHash,
				title: m.title,
				voteId: `snapshot-x:${proposal.proposalId}`,
				docType: m.docType
			};
			const addTxHash = await writeContract(config, {
				...bvsRegistryConfig,
				functionName: 'addDocument',
				args: [input, []]
			});
			const addReceipt = await waitForTransactionReceipt(config, { hash: addTxHash });

			// If the proposal payload bundled a setAmendmentRestrictions call,
			// sign it as a follow-up tx now that addDocument has confirmed and
			// the document ID is fixed on-chain. Bound to the same proposal —
			// no separate decision step.
			if (m.restrictions) {
				// Resolve the contract-assigned documentId from the DocumentAdded
				// event in this receipt. getDocumentCount() would race against
				// any concurrent addDocument by another admin in the same
				// category; the event's indexed documentId is authoritative.
				let resolvedDocId = m.documentId;
				if (resolvedDocId === 0) {
					try {
						const logs = parseEventLogs({
							abi: BVSRegistryAbi,
							eventName: 'DocumentAdded',
							logs: addReceipt.logs
						}) as unknown as { args: { categoryId: bigint; documentId: bigint } }[];
						const evt = logs.find((l) => l.args.categoryId === BigInt(m.categoryId));
						if (evt) {
							resolvedDocId = Number(evt.args.documentId);
						}
					} catch {
						resolvedDocId = 0;
					}
				}
				if (resolvedDocId > 0) {
					try {
						const lockedSections = m.restrictions.lockedSections.map((s) => BigInt(s));
						const restrictionsTxHash = await writeContract(config, {
							...bvsRegistryConfig,
							functionName: 'setAmendmentRestrictions',
							args: [
								BigInt(m.categoryId),
								BigInt(resolvedDocId),
								BigInt(m.restrictions.minTimeBetweenAmendments),
								lockedSections
							]
						});
						await waitForTransactionReceipt(config, { hash: restrictionsTxHash });
						showToast('success', `Approved & locked proposal #${proposal.proposalId}.`);
					} catch (e) {
						const msg = e instanceof Error ? e.message : 'Restriction tx failed';
						showToast('error', `Document recorded, but restrictions failed: ${msg}`);
					}
				} else {
					showToast('error', 'Document recorded, but resolved documentId is 0 — restrictions skipped.');
				}
			} else {
				showToast('success', `Approved & recorded proposal #${proposal.proposalId}.`);
			}
			await loadPage();
		} catch (e) {
			const msg = e instanceof Error ? e.message : 'Approval failed';
			if (msg.toLowerCase().includes('user rejected') || msg.toLowerCase().includes('denied')) {
				showToast('error', 'Transaction was rejected in wallet.');
			} else {
				showToast('error', msg);
			}
		} finally {
			approvingId = null;
		}
	}

	function openRejectModal(proposalId: number) {
		rejectModalProposalId = proposalId;
		rejectReason = '';
	}

	function closeRejectModal() {
		rejectModalProposalId = null;
		rejectReason = '';
	}

	async function handleReject() {
		const proposalId = rejectModalProposalId;
		if (proposalId === null) return;
		const proposal = [...activeProposals, ...passedProposals, ...historyProposals]
			.find(p => p.proposalId === proposalId);
		if (!proposal) return;

		rejectingId = proposalId;
		try {
			const txHash = await writeContract(config, {
				...bvsRegistryConfig,
				functionName: 'rejectProposal',
				args: [
					BigInt(proposalId),
					proposal.votesFor,
					proposal.votesAgainst,
					proposal.votesAbstain,
					rejectReason.trim()
				]
			});
			await waitForTransactionReceipt(config, { hash: txHash });
			showToast('success', `Rejected proposal #${proposalId}.`);
			closeRejectModal();
			await loadPage();
		} catch (e) {
			const msg = e instanceof Error ? e.message : 'Rejection failed';
			if (msg.toLowerCase().includes('user rejected') || msg.toLowerCase().includes('denied')) {
				showToast('error', 'Transaction was rejected in wallet.');
			} else {
				showToast('error', msg);
			}
		} finally {
			rejectingId = null;
		}
	}

	onMount(() => {
		loadPage();
		// Live countdown — tick every second
		tickInterval = setInterval(() => { tickNow = Date.now(); }, 1000);
		// Refresh block number once per chain block to recalibrate. Hardcoding
		// 12_000ms here would be 6× too slow on Polygon/Base and 48× too slow
		// on Arbitrum.
		blockRefreshInterval = setInterval(async () => {
			try {
				const client = (await import('$lib/services/wallet-config')).getClient();
				if (client) {
					const prevBlock = currentBlock;
					const block = await client.getBlockNumber();
					currentBlock = Number(block);
					blockFetchedAt = Date.now();
					// Re-fetch proposals when any active proposal's voting period has ended
					if (activeProposals.length > 0 && prevBlock > 0) {
						const anyEnded = activeProposals.some(p => currentBlock >= p.maxEndBlockNumber);
						if (anyEnded) loadPage();
					}
				}
			} catch { /* skip */ }
		}, Math.max(1000, BLOCK_TIME_SECONDS * 1000));
	});

	onDestroy(() => {
		if (tickInterval) clearInterval(tickInterval);
		if (blockRefreshInterval) clearInterval(blockRefreshInterval);
	});
</script>

<div>
	<h1 class="text-2xl font-semibold mb-6">Governance <Tooltip text={"View active proposals, cast your vote, and execute passed legislation. All voting happens on-chain via Snapshot X. Each vote is a transaction — voters pay gas."} align="left"><span class="text-sm font-normal text-text-muted cursor-help">(?)</span></Tooltip></h1>

	{#if loading}
		<p class="text-text-secondary">Loading proposals...</p>
	{:else if error}
		<p class="text-error">{error}</p>
	{:else}
		<!-- Active proposals: voting open, no admin decision yet -->
		<section class="mb-8">
			<h2 class="text-lg font-medium mb-4">Active Proposals <Tooltip text={"Proposals open for stakeholder voting. Each member casts one vote (For, Against, Abstain). Voting is on-chain. The admin can Approve or Reject at any time, even before the voting period ends."} align="left"><span class="text-sm font-normal text-text-muted cursor-help">(?)</span></Tooltip></h2>
			{#if activeProposals.length === 0}
				<p class="text-text-muted text-sm">No active proposals.</p>
			{:else}
				<div class="flex flex-col gap-4">
					{#each activeProposals as proposal}
						<ActiveProposalCard
							{proposal}
							isExpanded={expandedId === proposal.proposalId}
							{votingId}
							approvalNeeded={approvalVotesNeeded(proposal.executionStrategy, totalSupply, quorums)}
							quorumNeeded={participationVotesNeeded(proposal.executionStrategy, totalSupply, quorums)}
							{totalSupply}
							{quorums}
							restrictionsText={buildRestrictionsText(proposal)}
							timeRemainingText={timeRemaining(proposal.maxEndBlockNumber)}
							blockEndText={blockToGMT(proposal.maxEndBlockNumber)}
							onToggleExpand={() => toggleExpand(proposal.proposalId)}
							onVote={(choice) => handleVote(proposal.proposalId, choice)}
						/>
						{#if $wallet.isAdmin}
							<div class="flex gap-2 -mt-2 px-1">
								<LoadingButton
									onclick={() => handleApprove(proposal)}
									loading={approvingId === proposal.proposalId}
									loadingLabel="Approving..."
									variant="primary"
									class="px-4 py-1.5 text-sm"
								>
									Approve &amp; Record
								</LoadingButton>
								<LoadingButton
									onclick={() => openRejectModal(proposal.proposalId)}
									loading={rejectingId === proposal.proposalId}
									loadingLabel="Rejecting..."
									variant="none"
									class="px-4 py-1.5 text-sm bg-error/80 hover:bg-error"
								>
									Reject
								</LoadingButton>
							</div>
						{/if}
					{/each}
				</div>
			{/if}
		</section>

		<!-- Ready to Execute: voting closed, awaiting admin Approve/Reject -->
		<section class="mb-8">
			<h2 class="text-lg font-medium mb-4">Ready to Execute <Tooltip text={"Proposals whose voting period has ended. Admin-only: Approve & Record writes the document to the registry; Reject writes a ProposalRejected event with the final tally."} align="left"><span class="text-sm font-normal text-text-muted cursor-help">(?)</span></Tooltip></h2>
			{#if passedProposals.length === 0}
				<p class="text-text-muted text-sm">No proposals awaiting admin decision.</p>
			{:else}
				<div class="flex flex-col gap-4">
					{#each passedProposals as proposal}
						<PassedProposalCard
							{proposal}
							isExpanded={expandedId === proposal.proposalId}
							{votingId}
							approvalNeeded={approvalVotesNeeded(proposal.executionStrategy, totalSupply, quorums)}
							quorumNeeded={participationVotesNeeded(proposal.executionStrategy, totalSupply, quorums)}
							{totalSupply}
							{quorums}
							restrictionsText={buildRestrictionsText(proposal)}
							timeRemainingText={timeRemaining(proposal.maxEndBlockNumber)}
							blockEndText={blockToGMT(proposal.maxEndBlockNumber)}
							{approvingId}
							{rejectingId}
							onToggleExpand={() => toggleExpand(proposal.proposalId)}
							onVote={(choice) => handleVote(proposal.proposalId, choice)}
							onApprove={() => handleApprove(proposal)}
							onOpenReject={() => openRejectModal(proposal.proposalId)}
						/>
					{/each}
				</div>
			{/if}
		</section>

		<!-- History (collapsible). Always rendered, even when empty. -->
		<section>
			<button
				onclick={() => historyExpanded = !historyExpanded}
				class="flex items-center gap-2 text-lg font-medium cursor-pointer mb-4"
			>
				<span>History</span>
				<span class="text-text-muted text-xs">({historyProposals.length})</span>
				<span class="text-text-muted text-xs transition-transform {historyExpanded ? 'rotate-180' : ''}">&#9660;</span>
			</button>

			{#if historyProposals.length === 0}
				<p class="text-text-muted text-sm">No decisions recorded yet.</p>
			{:else if historyExpanded}
				<div class="flex flex-col gap-1">
					{#each historyProposals as proposal}
						<div class="flex items-center justify-between px-4 py-2 rounded border border-border bg-bg-light">
							<div class="flex items-center gap-3 min-w-0">
								<span class="font-mono text-text-muted text-xs w-6 text-right">#{proposal.proposalId}</span>
								<span class="text-sm truncate">{proposal.metadata?.title ?? `Proposal #${proposal.proposalId}`}</span>
								{#if proposal.decision}
									{#if proposal.decision.status === 'approved'}
										<span class="text-xs text-success">✓ Approved</span>
									{:else}
										<span class="text-xs text-error">✗ Rejected</span>
									{/if}
								{:else}
									<span class="text-xs {statusClass(proposal.status)}">{statusLabel(proposal.status)}</span>
								{/if}
							</div>
							<div class="flex items-center gap-3 text-xs text-text-muted">
								{#if proposal.decision?.status === 'rejected' && proposal.decision.reason}
									<span class="italic truncate max-w-xs" title={proposal.decision.reason}>{proposal.decision.reason}</span>
								{/if}
								{#if proposal.documentLabel}<span>{proposal.documentLabel}</span>{/if}
								<span>For: {Number(proposal.votesFor)} / Against: {Number(proposal.votesAgainst)} / Abstain: {Number(proposal.votesAbstain)}</span>
							</div>
						</div>
					{/each}
				</div>
			{/if}
		</section>

		<!-- Empty state -->
		{#if activeProposals.length === 0 && passedProposals.length === 0 && historyProposals.length === 0}
			<div class="text-center py-12 mt-6">
				<p class="text-text-muted">No proposals have been created yet.</p>
				{#if $wallet.isTokenHolder}
					<p class="text-text-muted text-sm mt-2">
						<a href="/propose" class="text-primary hover:underline">Create the first proposal</a>
					</p>
				{/if}
			</div>
		{/if}
	{/if}
</div>

{#if rejectModalProposalId !== null}
	<div
		class="fixed inset-0 bg-black/70 z-50 flex items-center justify-center p-6"
		onkeydown={(e) => { if (e.key === 'Escape') closeRejectModal(); }}
		role="button"
		tabindex="-1"
	>
		<div class="bg-bg border border-border rounded-lg p-5 max-w-md w-full flex flex-col gap-4">
			<h3 class="text-lg font-medium">Reject proposal #{rejectModalProposalId}</h3>
			<p class="text-text-muted text-sm">
				Records a rejection event on-chain with the current vote tally for the audit trail. This is irreversible.
			</p>
			<div>
				<label for="rejectReason" class="block text-sm text-text-secondary mb-1">Reason <span class="text-text-muted">(optional)</span></label>
				<textarea
					id="rejectReason"
					bind:value={rejectReason}
					rows="3"
					placeholder="Out of scope, conflicts with existing policy, etc."
					class="w-full bg-bg-light border border-border rounded p-2 text-sm outline-none focus:border-primary resize-y"
				></textarea>
			</div>
			<div class="flex justify-end gap-2">
				<button
					onclick={closeRejectModal}
					class="px-4 py-1.5 text-sm border border-border rounded text-text-muted hover:text-text"
				>
					Cancel
				</button>
				<LoadingButton
					onclick={handleReject}
					loading={rejectingId !== null}
					loadingLabel="Rejecting..."
					variant="none"
					class="px-4 py-1.5 text-sm bg-error/80 hover:bg-error"
				>
					Confirm Reject
				</LoadingButton>
			</div>
		</div>
	</div>
{/if}
