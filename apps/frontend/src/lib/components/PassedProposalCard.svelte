<script lang="ts">
	import { wallet } from '$lib/stores/wallet';
	import ActiveProposalCard, { type ProposalCardData } from './ActiveProposalCard.svelte';
	import LoadingButton from './LoadingButton.svelte';
	import { VoteChoice, type StrategyQuorums } from '$lib/services/snapshot-x';

	let {
		proposal,
		isExpanded,
		votingId,
		approvalNeeded,
		quorumNeeded,
		totalSupply,
		quorums,
		restrictionsText,
		timeRemainingText,
		blockEndText,
		approvingId,
		rejectingId,
		onToggleExpand,
		onVote,
		onApprove,
		onOpenReject
	}: {
		proposal: ProposalCardData;
		isExpanded: boolean;
		votingId: number | null;
		approvalNeeded: bigint;
		quorumNeeded: bigint;
		totalSupply: bigint;
		quorums: StrategyQuorums;
		restrictionsText: string;
		timeRemainingText: string;
		blockEndText: string;
		approvingId: number | null;
		rejectingId: number | null;
		onToggleExpand: () => void;
		onVote: (choice: VoteChoice) => void;
		onApprove: () => void;
		onOpenReject: () => void;
	} = $props();
</script>

<ActiveProposalCard
	{proposal}
	{isExpanded}
	{votingId}
	{approvalNeeded}
	{quorumNeeded}
	{totalSupply}
	{quorums}
	{restrictionsText}
	{timeRemainingText}
	{blockEndText}
	{onToggleExpand}
	{onVote}
/>
{#if $wallet.isAdmin}
	<div class="flex gap-2 -mt-2 px-1">
		<LoadingButton
			onclick={onApprove}
			loading={approvingId === proposal.proposalId}
			loadingLabel="Approving..."
			variant="primary"
			class="px-4 py-1.5 text-sm"
		>
			Approve &amp; Record
		</LoadingButton>
		<LoadingButton
			onclick={onOpenReject}
			loading={rejectingId === proposal.proposalId}
			loadingLabel="Rejecting..."
			variant="none"
			class="px-4 py-1.5 text-sm bg-error/80 hover:bg-error"
		>
			Reject
		</LoadingButton>
	</div>
{/if}
