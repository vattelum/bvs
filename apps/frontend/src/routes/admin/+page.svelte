<script lang="ts">
	import { wallet } from '$lib/stores/wallet';
	import MintForm from '$lib/components/MintForm.svelte';
	import MemberList from '$lib/components/MemberList.svelte';

	let refreshKey = $state(0);
</script>

<div>
	<h1 class="text-2xl font-semibold mb-6">Members</h1>

	{#if $wallet.connected && $wallet.isAdmin}
		<div class="flex flex-col gap-8">
			<div class="border border-border rounded-lg p-5">
				<MintForm onminted={() => refreshKey++} />
			</div>
			{#key refreshKey}
				<MemberList />
			{/key}
		</div>
	{:else}
		{#if !$wallet.connected}
			<p class="text-text-muted text-sm mb-6">Connect as admin to mint membership tokens.</p>
		{:else if !$wallet.isAdmin}
			<p class="text-text-muted text-sm mb-6">Connect as admin to mint membership tokens.</p>
		{/if}
		<MemberList />
	{/if}
</div>
