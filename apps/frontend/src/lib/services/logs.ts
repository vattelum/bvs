import type { PublicClient, AbiEvent, GetLogsParameters } from 'viem';

const BLOCK_RANGE = 50_000n;

export async function getPaginatedLogs<T extends AbiEvent>(
	client: PublicClient,
	params: Omit<GetLogsParameters<T>, 'fromBlock' | 'toBlock'> & { fromBlock: bigint }
): Promise<Awaited<ReturnType<PublicClient['getLogs']>>> {
	const currentBlock = await client.getBlockNumber();
	let from = params.fromBlock;
	const allLogs: Awaited<ReturnType<PublicClient['getLogs']>> = [];

	while (from <= currentBlock) {
		const to = from + BLOCK_RANGE - 1n > currentBlock ? currentBlock : from + BLOCK_RANGE - 1n;
		const logs = await client.getLogs({ ...params, fromBlock: from, toBlock: to } as any);
		allLogs.push(...logs);
		from = to + 1n;
	}

	return allLogs;
}

interface CachedMembers {
	lastBlock: string;
	minted: Array<{ address: string; tokenId: string }>;
	burned: string[];
}

const CACHE_KEY = 'bvs:members';

export function getCachedMembers(): CachedMembers | null {
	try {
		const raw = localStorage.getItem(CACHE_KEY);
		return raw ? JSON.parse(raw) : null;
	} catch {
		return null;
	}
}

export function setCachedMembers(data: CachedMembers) {
	try {
		localStorage.setItem(CACHE_KEY, JSON.stringify(data));
	} catch {
		// storage full or unavailable
	}
}
