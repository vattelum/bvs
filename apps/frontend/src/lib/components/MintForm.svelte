<script lang="ts">
	import { writeContract, waitForTransactionReceipt } from '@wagmi/core';
	import { config } from '$lib/services/wallet-config';
	import { bvsTokenConfig } from '$lib/contracts';
	import { wallet } from '$lib/stores/wallet';
	import { toHex, isAddress } from 'viem';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import LoadingButton from '$lib/components/LoadingButton.svelte';
	import { showToast } from '$lib/stores/toasts';

	let { onminted }: { onminted?: () => void } = $props();

	let recipient = $state('');
	let credential = $state('');
	let showAdvanced = $state(false);
	let submitting = $state(false);
	let error = $state('');

	$effect(() => {
		if (!showAdvanced) credential = '';
	});

	async function handleMint() {
		error = '';
		if (!$wallet.connected || !$wallet.isAdmin) {
			error = 'Only the admin can mint membership tokens.';
			return;
		}
		const trimmedRecipient = recipient.trim();
		if (!isAddress(trimmedRecipient)) {
			error = 'Enter a valid Ethereum address.';
			return;
		}
		if (credential.length > 256) {
			error = 'Credential must be 256 characters or fewer.';
			return;
		}

		submitting = true;
		try {
			const credentialBytes = credential.trim()
				? toHex(new TextEncoder().encode(credential.trim()))
				: '0x';

			const txHash = await writeContract(config, {
				...bvsTokenConfig,
				functionName: 'mint',
				args: [trimmedRecipient as `0x${string}`, credentialBytes]
			});

			await waitForTransactionReceipt(config, { hash: txHash });

			showToast('success', `Membership token minted to ${trimmedRecipient.slice(0, 6)}…${trimmedRecipient.slice(-4)}.`);
			recipient = '';
			credential = '';
			showAdvanced = false;
			onminted?.();
		} catch (e) {
			const msg = e instanceof Error ? e.message : 'Mint failed';
			const lower = msg.toLowerCase();
			if (lower.includes('alreadymember')) {
				showToast('error', 'Recipient already holds a membership token.');
			} else if (lower.includes('user rejected') || lower.includes('denied')) {
				showToast('error', 'Transaction was rejected in wallet.');
			} else {
				showToast('error', msg);
			}
		} finally {
			submitting = false;
		}
	}
</script>

<div class="flex flex-col gap-4">
	<h2 class="text-lg font-medium">Mint Membership Token <Tooltip text={"Admin-only. Mints a soulbound (non-transferable) ERC-721 token to a recipient address. The token grants on-chain voting rights in Snapshot X proposals.\n\nThe token is locked at mint — it cannot be transferred. The holder can burn it to voluntarily resign membership."} align="left"><span class="text-sm font-normal text-text-muted cursor-help">(?)</span></Tooltip></h2>

	{#if !$wallet.connected}
		<p class="text-text-muted text-sm">Connect the admin wallet to mint membership tokens.</p>
	{:else if !$wallet.isAdmin}
		<p class="text-text-muted text-sm">This wallet is not the admin. Only the admin can mint.</p>
	{:else}
		<div>
			<label for="recipient" class="block text-sm text-text-secondary mb-1">
				Recipient address
			</label>
			<input
				id="recipient"
				type="text"
				bind:value={recipient}
				placeholder="0x…"
				class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary font-mono"
			/>
		</div>

		{#if error}
			<p class="text-error text-sm">{error}</p>
		{/if}

		<LoadingButton
			onclick={handleMint}
			loading={submitting}
			loadingLabel="Minting..."
			variant="primary"
			class="self-start px-5 font-medium"
		>
			Mint Token
		</LoadingButton>

		<div class="border-t border-border pt-3 flex flex-col gap-2">
			<label class="inline-flex items-center gap-2 text-sm text-text-secondary cursor-pointer select-none">
				<input
					type="checkbox"
					bind:checked={showAdvanced}
					class="cursor-pointer"
				/>
				Advanced credential <Tooltip text={"An optional bytes field stored on-chain alongside your membership token. The wallet address is the binding identifier on its own; the credential is an opaque commitment that a separate consumer — an identity-issuing frontend, an indexer, an integration — can resolve to a person, role, or hash.\n\nThis frontend stores the bytes at mint but does not read or display them. Consumers read via getCredential(tokenId) on BVSToken.\n\nPermanently public on-chain. Do not store sensitive data directly — use a hash of off-chain material if you need linkage to identity proof."} align="left"><span class="text-text-muted cursor-help">(?)</span></Tooltip>
			</label>

			{#if showAdvanced}
				<div>
					<label for="credential" class="block text-xs text-text-muted mb-1">
						Credential bytes (max 256 characters)
					</label>
					<input
						id="credential"
						type="text"
						bind:value={credential}
						maxlength="256"
						placeholder="Hash, DID, identifier, or leave empty"
						class="w-full bg-bg-light border border-border rounded px-3 py-2 text-sm outline-none focus:border-primary"
					/>
				</div>
			{/if}
		</div>
	{/if}
</div>
