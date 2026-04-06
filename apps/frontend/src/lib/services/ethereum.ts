import {
	createConfig,
	http,
	connect,
	disconnect,
	reconnect,
	readContract,
	watchAccount,
	getPublicClient
} from '@wagmi/core';
import { sepolia, mainnet } from 'viem/chains';
import { injected } from '@wagmi/connectors';
import { wallet } from '$lib/stores/wallet';
import { resetTurbo } from '$lib/services/arweave';
import { bvsTokenConfig, bvsRegistryConfig } from '$lib/contracts';

const chainId = Number(import.meta.env.VITE_CHAIN_ID);
const rpcUrl = import.meta.env.VITE_RPC_URL as string;

const chain = chainId === 1 ? mainnet : sepolia;

export const config = createConfig({
	chains: [chain],
	connectors: [injected()],
	transports: {
		[chain.id]: http(rpcUrl)
	}
});

watchAccount(config, {
	onChange(account) {
		resetTurbo();
		wallet.set({
			address: account.address ?? null,
			connected: account.isConnected,
			connecting: account.isConnecting,
			isAdmin: false,
			isTokenHolder: false
		});
		if (account.address) {
			checkRoles(account.address);
		}
	}
});

reconnect(config);

export async function connectWallet() {
	return connect(config, { connector: injected() });
}

export async function disconnectWallet() {
	return disconnect(config);
}

export function getClient() {
	return getPublicClient(config);
}

export async function checkRoles(address: `0x${string}`) {
	try {
		const [tokenOwner, govAuthority, balance] = await Promise.all([
			readContract(config, { ...bvsTokenConfig, functionName: 'owner' }),
			readContract(config, { ...bvsRegistryConfig, functionName: 'governanceAuthority' }),
			readContract(config, { ...bvsTokenConfig, functionName: 'balanceOf', args: [address] })
		]);
		const admin =
			address.toLowerCase() === (tokenOwner as string).toLowerCase() ||
			address.toLowerCase() === (govAuthority as string).toLowerCase();
		const holder = (balance as bigint) > 0n;
		wallet.update((w) => ({ ...w, isAdmin: admin, isTokenHolder: holder }));
	} catch {
		wallet.update((w) => ({ ...w, isAdmin: false, isTokenHolder: false }));
	}
}
