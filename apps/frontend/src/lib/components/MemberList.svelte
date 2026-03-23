<script lang="ts">
	import { onMount } from 'svelte';
	import { getClient } from '$lib/services/ethereum';
	import { bvsTokenAddress } from '$lib/contracts';
	import { parseAbiItem } from 'viem';
	import { getPaginatedLogs, getCachedMembers, setCachedMembers } from '$lib/services/logs';

	const deployBlock = BigInt(import.meta.env.VITE_DEPLOY_BLOCK || '0');

	interface Member {
		address: string;
		tokenId: bigint;
	}

	let members = $state<Member[]>([]);
	let loading = $state(true);
	let error = $state('');

	const mintEvent = parseAbiItem('event Minted(address indexed to, uint256 indexed tokenId)');
	const burnEvent = parseAbiItem('event Burned(address indexed from, uint256 indexed tokenId)');

	async function loadMembers() {
		try {
			const client = getClient();
			if (!client) {
				error = 'No RPC client available';
				return;
			}

			const cached = getCachedMembers();
			const fromBlock = cached ? BigInt(cached.lastBlock) + 1n : deployBlock;

			const [mintLogs, burnLogs] = await Promise.all([
				getPaginatedLogs(client, {
					address: bvsTokenAddress,
					event: mintEvent,
					fromBlock
				}),
				getPaginatedLogs(client, {
					address: bvsTokenAddress,
					event: burnEvent,
					fromBlock
				})
			]);

			const allMinted = [
				...(cached?.minted ?? []),
				...mintLogs.map((log: any) => ({
					address: log.args.to as string,
					tokenId: log.args.tokenId.toString()
				}))
			];

			const allBurned = new Set([
				...(cached?.burned ?? []),
				...burnLogs.map((log: any) => log.args.tokenId.toString())
			]);

			const currentBlock = await client.getBlockNumber();
			setCachedMembers({
				lastBlock: currentBlock.toString(),
				minted: allMinted,
				burned: [...allBurned]
			});

			members = allMinted
				.filter((m) => !allBurned.has(m.tokenId))
				.map((m) => ({ address: m.address, tokenId: BigInt(m.tokenId) }));
		} catch (e) {
			error = e instanceof Error ? e.message : 'Failed to load members';
		} finally {
			loading = false;
		}
	}

	export function refresh() {
		loading = true;
		error = '';
		loadMembers();
	}

	onMount(loadMembers);
</script>

<div class="flex flex-col gap-3">
	<h2 class="text-lg font-medium">Members</h2>

	{#if loading}
		<p class="text-text-secondary text-sm">Loading members...</p>
	{:else if error}
		<p class="text-error text-sm">{error}</p>
	{:else if members.length === 0}
		<p class="text-text-muted text-sm">No members yet.</p>
	{:else}
		<div class="border border-border rounded-lg overflow-hidden">
			<table class="w-full text-sm">
				<thead>
					<tr class="border-b border-border bg-bg-lighter">
						<th class="text-left px-4 py-2 text-text-secondary font-medium">Token</th>
						<th class="text-left px-4 py-2 text-text-secondary font-medium">Address</th>
					</tr>
				</thead>
				<tbody>
					{#each members as member}
						<tr class="border-b border-border last:border-b-0">
							<td class="px-4 py-2 font-mono text-text-muted"
								>#{member.tokenId.toString()}</td
							>
							<td class="px-4 py-2 font-mono">{member.address}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
		<p class="text-text-muted text-xs">
			{members.length}
			{members.length === 1 ? 'member' : 'members'}
		</p>
	{/if}
</div>
