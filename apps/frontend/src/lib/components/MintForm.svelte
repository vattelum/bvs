<script lang="ts">
	import { readContract, writeContract, waitForTransactionReceipt } from '@wagmi/core';
	import { config, checkRoles } from '$lib/services/ethereum';
	import { wallet } from '$lib/stores/wallet';
	import { bvsTokenConfig } from '$lib/contracts';
	import { toHex } from 'viem';
	import { get } from 'svelte/store';
	import Tooltip from '$lib/components/Tooltip.svelte';

	let { onminted }: { onminted?: () => void } = $props();

	let recipient = $state('');
	let credential = $state('');
	let submitting = $state(false);
	let error = $state('');
	let success = $state('');

	async function handleMint() {
		if (!recipient.match(/^0x[0-9a-fA-F]{40}$/)) {
			error = 'Invalid Ethereum address.';
			return;
		}

		submitting = true;
		error = '';
		success = '';

		try {
			const balance = await readContract(config, {
				...bvsTokenConfig,
				functionName: 'balanceOf',
				args: [recipient as `0x${string}`]
			}) as bigint;

			if (balance > 0n) {
				error = 'This address already holds a membership token.';
				submitting = false;
				return;
			}
			const credentialBytes = credential.trim()
				? toHex(new TextEncoder().encode(credential.trim()))
				: '0x';

			const txHash = await writeContract(config, {
				...bvsTokenConfig,
				functionName: 'mint',
				args: [recipient as `0x${string}`, credentialBytes]
			});

			await waitForTransactionReceipt(config, { hash: txHash });

			success = `Token minted to ${recipient.slice(0, 6)}...${recipient.slice(-4)}`;
			recipient = '';
			credential = '';
			const w = get(wallet);
			if (w.address) await checkRoles(w.address);
			onminted?.();
		} catch (e) {
			const msg = e instanceof Error ? e.message : 'Mint failed';
			const lower = msg.toLowerCase();
			if (lower.includes('already holds a token') || lower.includes('singletokenperaddress')) {
				error = 'This address already holds a membership token.';
			} else if (lower.includes('gas limit') || lower.includes('reverted')) {
				error = 'Transaction reverted. The address may already hold a token.';
			} else if (lower.includes('user rejected') || lower.includes('denied')) {
				error = 'Transaction was rejected in wallet.';
			} else {
				error = msg;
			}
		} finally {
			submitting = false;
		}
	}
</script>

<div class="flex flex-col gap-4">
	<h2 class="text-lg font-medium">Mint Membership Token <Tooltip text={"Issues a soulbound (non-transferable) ERC-721 token to the recipient. This token serves as verifiable on-chain proof of membership and grants one vote in Snapshot governance proposals.\n\nThe token is locked at mint \u2014 it cannot be sold, transferred, or moved to another wallet. The governance authority can mint and burn membership tokens. Holders can burn their own tokens to voluntarily renounce membership."} align="left"><span class="text-sm font-normal text-text-muted cursor-help">(?)</span></Tooltip></h2>

	<div>
		<label for="recipient" class="block text-sm text-text-secondary mb-1">Recipient Address <Tooltip text={"The Ethereum wallet address that will receive the membership token. The contract enforces one token per address. If this wallet already holds a membership token, the transaction will revert. Once minted, the token is permanently bound to this address and cannot be transferred."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip></label>
		<input
			id="recipient"
			type="text"
			bind:value={recipient}
			placeholder="0x..."
			class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm font-mono outline-none focus:border-primary"
		/>
	</div>

	<div>
		<label for="credential" class="block text-sm text-text-secondary mb-1">
			Credential <span class="text-text-muted">(optional)</span> <Tooltip text={"An optional byte field stored on-chain with the token. It can hold any identifier: a DID, an organizational role, or a hashed credential. Any contract or application can read this field to implement access control, identity verification, or role-based permissions.\n\nBecause it is permanently public on-chain, do not store sensitive data directly."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip>
		</label>
		<input
			id="credential"
			type="text"
			bind:value={credential}
			placeholder="DID, role, or leave empty"
			class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary"
		/>
	</div>

	{#if error}
		<p class="text-error text-sm">{error}</p>
	{/if}

	{#if success}
		<p class="text-success text-sm">{success}</p>
	{/if}

	<button
		onclick={handleMint}
		disabled={submitting}
		class="self-start px-5 py-2 rounded bg-primary hover:bg-primary-hover text-text text-sm font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
	>
		{submitting ? 'Minting...' : 'Mint Token'}
	</button>
</div>
