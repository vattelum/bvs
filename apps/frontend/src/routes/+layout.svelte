<script lang="ts">
	import '../app.css';
	import '$lib/services/ethereum';
	import { wallet } from '$lib/stores/wallet';
	import { connectWallet, disconnectWallet } from '$lib/services/ethereum';
	import { page } from '$app/stores';
	import Tooltip from '$lib/components/Tooltip.svelte';

	let { children } = $props();

	function truncateAddress(addr: string) {
		return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
	}

	const snapshotUrl = import.meta.env.VITE_SNAPSHOT_SPACE
		? `${import.meta.env.VITE_SNAPSHOT_HUB?.includes('testnet') ? 'https://testnet.snapshot.box' : 'https://snapshot.box'}/#/${import.meta.env.VITE_SNAPSHOT_SPACE}`
		: '';

	const navItems = [
		{ href: '/', label: 'Home' },
		{ href: '/propose', label: 'Propose' },
		{ href: '/admin', label: 'Members' }
	];
</script>

<svelte:head>
	<link rel="icon" type="image/png" href="/favicon.png" />
</svelte:head>

<div class="min-h-screen bg-bg text-text">
	<nav class="border-b border-border px-8 py-3 flex flex-wrap items-center justify-between gap-3">
		<div class="flex items-center gap-6 ml-2">
			{#each navItems as item}
				<a
					href={item.href}
					class="text-sm font-medium transition-colors {$page.url.pathname === item.href
						? 'text-text'
						: 'text-text-secondary hover:text-text'}"
				>
					{item.label}
				</a>
			{/each}
			{#if snapshotUrl}
				<Tooltip text={"Snapshot is an off-chain governance platform where tokenholders vote on proposals without paying gas fees. Votes are signed messages verified against on-chain token ownership.\n\nThis link opens the BVS governance space, where proposals are created, debated, and voted on. Once a proposal passes, the admin uses this frontend to record the ratified document after which it will show up in the registry."}>
					<a
						href={snapshotUrl}
						target="_blank"
						rel="noopener noreferrer"
						class="text-xs font-medium text-text-muted hover:text-text transition-colors border border-border rounded px-2 py-0.5"
					>
						Snapshot &#8599;
					</a>
				</Tooltip>
			{/if}
		</div>

		<div>
			{#if $wallet.connected && $wallet.address}
				<div class="flex items-center gap-3">
					{#if $wallet.isAdmin}
						<span class="text-xs text-primary">admin</span>
					{/if}
					<span class="text-sm text-text-secondary">
						{truncateAddress($wallet.address)}
					</span>
					<button
						onclick={() => disconnectWallet()}
						class="text-sm text-text-muted hover:text-text transition-colors cursor-pointer"
					>
						Disconnect
					</button>
				</div>
			{:else}
				<button
					onclick={() => connectWallet()}
					class="bg-primary hover:bg-primary-hover text-text text-sm px-4 py-1.5 rounded transition-colors cursor-pointer"
				>
					Connect Wallet
				</button>
			{/if}
		</div>
	</nav>

	<main class="max-w-4xl mx-auto px-6 py-8">
		{@render children()}
	</main>
</div>
