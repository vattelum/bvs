/**
 * Snapshot X on-chain governance service.
 *
 * Interacts with sx-evm contracts via viem — no @snapshot-labs/sx SDK.
 * Flow: EthTxAuthenticator.authenticate() → Space.propose/vote
 *       Space.execute() → ExecutionStrategy → Safe → BVSRegistry
 */
import { readContract, writeContract, waitForTransactionReceipt } from '@wagmi/core';
import { encodeFunctionData, encodeAbiParameters, parseAbiParameters, decodeAbiParameters, decodeEventLog, decodeFunctionData, type Hex, type PublicClient } from 'viem';
import { config, getClient } from '$lib/services/wallet-config';
import {
	sxSpaceAddress,
	executionStrategyAddress,
	authenticatorAddress,
	bvsTokenConfig,
	bvsRegistryAddress,
	bvsRegistryConfig
} from '$lib/contracts';
import BVSRegistryABI from '$lib/contracts/BVSRegistry.abi.json';
import { getPaginatedLogs } from '$lib/services/event-log-scanner';
import { toFunctionSelector } from 'viem';

// --- sx-evm ABIs (minimal, sourced from sx-evm contracts) ---

const spaceAbi = [
	{
		type: 'function',
		name: 'propose',
		inputs: [
			{ name: 'author', type: 'address' },
			{ name: 'metadataURI', type: 'string' },
			{
				name: 'executionStrategy', type: 'tuple',
				components: [
					{ name: 'addr', type: 'address' },
					{ name: 'params', type: 'bytes' }
				]
			},
			{ name: 'userParams', type: 'bytes' }
		],
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'nonpayable'
	},
	{
		type: 'function',
		name: 'vote',
		inputs: [
			{ name: 'voter', type: 'address' },
			{ name: 'proposalId', type: 'uint256' },
			{ name: 'choice', type: 'uint8' },
			{
				name: 'userVotingStrategies', type: 'tuple[]',
				components: [
					{ name: 'index', type: 'uint8' },
					{ name: 'params', type: 'bytes' }
				]
			},
			{ name: 'metadataURI', type: 'string' }
		],
		outputs: [],
		stateMutability: 'nonpayable'
	},
	{
		type: 'function',
		name: 'execute',
		inputs: [
			{ name: 'proposalId', type: 'uint256' },
			{ name: 'payload', type: 'bytes' }
		],
		outputs: [],
		stateMutability: 'nonpayable'
	},
	{
		type: 'function',
		name: 'proposals',
		inputs: [{ name: 'proposalId', type: 'uint256' }],
		outputs: [
			{ name: 'author', type: 'address' },
			{ name: 'startBlockNumber', type: 'uint32' },
			{ name: 'executionStrategy', type: 'address' },
			{ name: 'minEndBlockNumber', type: 'uint32' },
			{ name: 'maxEndBlockNumber', type: 'uint32' },
			{ name: 'finalizationStatus', type: 'uint8' },
			{ name: 'executionPayloadHash', type: 'bytes32' },
			{ name: 'activeVotingStrategies', type: 'uint256' }
		],
		stateMutability: 'view'
	},
	{
		type: 'function',
		name: 'nextProposalId',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'view'
	},
	{
		type: 'function',
		name: 'votePower',
		inputs: [
			{ name: 'proposalId', type: 'uint256' },
			{ name: 'choice', type: 'uint8' }
		],
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'view'
	},
	{
		type: 'function',
		name: 'voteRegistry',
		inputs: [
			{ name: 'proposalId', type: 'uint256' },
			{ name: 'voter', type: 'address' }
		],
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'view'
	},
	{
		type: 'event',
		name: 'ProposalCreated',
		inputs: [
			{ name: 'proposalId', type: 'uint256', indexed: false },
			{ name: 'author', type: 'address', indexed: false },
			{
				name: 'proposal', type: 'tuple', indexed: false,
				components: [
					{ name: 'author', type: 'address' },
					{ name: 'startBlockNumber', type: 'uint32' },
					{ name: 'executionStrategy', type: 'address' },
					{ name: 'minEndBlockNumber', type: 'uint32' },
					{ name: 'maxEndBlockNumber', type: 'uint32' },
					{ name: 'finalizationStatus', type: 'uint8' },
					{ name: 'executionPayloadHash', type: 'bytes32' },
					{ name: 'activeVotingStrategies', type: 'uint256' }
				]
			},
			{ name: 'metadataURI', type: 'string', indexed: false },
			{ name: 'payload', type: 'bytes', indexed: false }
		],
		anonymous: false
	},
	{
		type: 'event',
		name: 'ProposalExecuted',
		inputs: [
			{ name: 'proposalId', type: 'uint256', indexed: true }
		],
		anonymous: false
	}
] as const;

const ethTxAuthenticatorAbi = [
	{
		type: 'function',
		name: 'authenticate',
		inputs: [
			{ name: 'target', type: 'address' },
			{ name: 'functionSelector', type: 'bytes4' },
			{ name: 'data', type: 'bytes' }
		],
		outputs: [],
		stateMutability: 'nonpayable'
	}
] as const;

const executionStrategyAbi = [
	{
		type: 'function',
		name: 'getProposalStatus',
		inputs: [
			{
				name: 'proposal', type: 'tuple',
				components: [
					{ name: 'author', type: 'address' },
					{ name: 'startBlockNumber', type: 'uint32' },
					{ name: 'executionStrategy', type: 'address' },
					{ name: 'minEndBlockNumber', type: 'uint32' },
					{ name: 'maxEndBlockNumber', type: 'uint32' },
					{ name: 'finalizationStatus', type: 'uint8' },
					{ name: 'executionPayloadHash', type: 'bytes32' },
					{ name: 'activeVotingStrategies', type: 'uint256' }
				]
			},
			{ name: 'votesFor', type: 'uint256' },
			{ name: 'votesAgainst', type: 'uint256' },
			{ name: 'votesAbstain', type: 'uint256' }
		],
		outputs: [{ name: '', type: 'uint8' }],
		stateMutability: 'view'
	},
	{
		type: 'function',
		name: 'approvalThreshold',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'view'
	},
	{
		type: 'function',
		name: 'participationQuorum',
		inputs: [],
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'view'
	}
] as const;

// --- Types ---

export enum ProposalStatus {
	VotingDelay = 0,
	VotingPeriod = 1,
	VotingPeriodAccepted = 2,
	Accepted = 3,
	Executed = 4,
	Rejected = 5,
	Cancelled = 6
}

export enum VoteChoice {
	Against = 0,
	For = 1,
	Abstain = 2
}

export interface ProposalRestrictionMetadata {
	minTimeBetweenAmendments: number;
	lockedSections: number[];
}

export interface ProposalMetadata {
	title: string;
	categoryId: number;
	documentId: number;
	docType: number;
	contentUri: string;
	contentHash: string;
	/** Bundled setAmendmentRestrictions call from the proposal payload, if any.
	 *  Decoded from the second MetaTransaction; null when no restrictions
	 *  were proposed. The /vote Approve flow signs a follow-up
	 *  setAmendmentRestrictions tx using these values. */
	restrictions: ProposalRestrictionMetadata | null;
	// Target registry the addDocument call is aimed at (payload tx.to). The
	// Snapshot X Space outlives any single registry deployment, so its proposal
	// history spans every registry it ever governed; this lets callers keep
	// only the proposals belonging to the registry the app currently points at.
	target: string;
}

export interface ProposalInfo {
	proposalId: number;
	startBlockNumber: number;
	minEndBlockNumber: number;
	maxEndBlockNumber: number;
	finalizationStatus: number;
	executionPayloadHash: Hex;
	executionStrategy: string;
	author: string;
	metadataURI: string;
	metadata: ProposalMetadata | null;
	status: ProposalStatus;
	votesFor: bigint;
	votesAgainst: bigint;
	votesAbstain: bigint;
	executionPayload: Hex;
}

interface MetaTransaction {
	to: `0x${string}`;
	value: bigint;
	data: Hex;
	operation: number; // 0 = Call
	salt: bigint;
}

// Function selectors derived from ABI
const PROPOSE_SELECTOR = toFunctionSelector('propose(address,string,(address,bytes),bytes)') as Hex;
const VOTE_SELECTOR = toFunctionSelector('vote(address,uint256,uint8,(uint8,bytes)[],string)') as Hex;

// --- Encoding helpers ---

/**
 * Encode a BVSRegistry.addDocument() call as a MetaTransaction for the execution strategy.
 */
export function encodeAddDocumentTransaction(
	input: {
		categoryId: bigint;
		documentId: bigint;
		contentUri: string;
		contentHash: Hex;
		title: string;
		voteId: string;
		docType: number;
	},
	refs: Array<{
		registryAddress: string;
		chainId: bigint;
		categoryId: bigint;
		documentId: bigint;
		version: bigint;
		relationType: number;
		targetSection: string;
	}>
): MetaTransaction {
	const data = encodeFunctionData({
		abi: BVSRegistryABI,
		functionName: 'addDocument',
		args: [input, refs]
	});

	return {
		to: bvsRegistryAddress,
		value: 0n,
		data,
		operation: 0, // Call
		salt: 0n
	};
}

/**
 * Encode a BVSRegistry.setAmendmentRestrictions() call as a MetaTransaction.
 * Bundled as the 2nd transaction of a proposal payload when the proposer wants
 * the document to be locked after admin-Approve. /vote decodes this from the
 * payload and prompts admin to sign it as a follow-up tx after addDocument.
 */
export function encodeSetAmendmentRestrictionsTransaction(
	categoryId: bigint,
	documentId: bigint,
	minTimeBetweenAmendments: bigint,
	lockedSections: bigint[]
): MetaTransaction {
	const data = encodeFunctionData({
		abi: BVSRegistryABI,
		functionName: 'setAmendmentRestrictions',
		args: [categoryId, documentId, minTimeBetweenAmendments, lockedSections]
	});

	return {
		to: bvsRegistryAddress,
		value: 0n,
		data,
		operation: 0,
		salt: 0n
	};
}

/**
 * Encode a BVSRegistry.rejectProposal() call as a MetaTransaction.
 * Note: in BVS, admin calls rejectProposal directly (not via Snapshot X execution).
 * Kept here for symmetry / future on-chain auto-rejection paths.
 */
export function encodeRejectProposalTransaction(
	snapshotProposalId: bigint,
	votesFor: bigint,
	votesAgainst: bigint,
	votesAbstain: bigint,
	reason: string
): MetaTransaction {
	const data = encodeFunctionData({
		abi: BVSRegistryABI,
		functionName: 'rejectProposal',
		args: [snapshotProposalId, votesFor, votesAgainst, votesAbstain, reason]
	});

	return {
		to: bvsRegistryAddress,
		value: 0n,
		data,
		operation: 0,
		salt: 0n
	};
}

/**
 * Encode MetaTransaction[] as execution strategy params.
 */
function encodeExecutionPayload(transactions: MetaTransaction[]): Hex {
	return encodeAbiParameters(
		parseAbiParameters('(address to, uint256 value, bytes data, uint8 operation, uint256 salt)[]'),
		[transactions.map(tx => ({
			to: tx.to,
			value: tx.value,
			data: tx.data,
			operation: tx.operation,
			salt: tx.salt
		}))]
	);
}

// --- Public API ---

/**
 * Create a proposal on Snapshot X via EthTxAuthenticator.
 *
 * @param author - Proposer wallet address
 * @param metadataURI - URI for proposal metadata (e.g. Arweave link)
 * @param strategyAddress - Which execution strategy to use (normal or core)
 * @param transactions - The MetaTransaction(s) to execute if proposal passes
 * @returns proposalId from the ProposalCreated event
 */
export async function createProposal(
	author: `0x${string}`,
	metadataURI: string,
	strategyAddress: `0x${string}`,
	transactions: MetaTransaction[]
): Promise<{ proposalId: number; txHash: string }> {
	const executionPayload = encodeExecutionPayload(transactions);

	// Encode the propose call data for the authenticator
	const proposeData = encodeAbiParameters(
		parseAbiParameters('address, string, (address addr, bytes params), bytes'),
		[
			author,
			metadataURI,
			{ addr: strategyAddress, params: executionPayload },
			'0x' // userParams (empty for VanillaProposalValidation)
		]
	);

	const txHash = await writeContract(config, {
		address: authenticatorAddress,
		abi: ethTxAuthenticatorAbi,
		functionName: 'authenticate',
		args: [sxSpaceAddress, PROPOSE_SELECTOR, proposeData],
		gas: 5_000_000n
	});

	const receipt = await waitForTransactionReceipt(config, { hash: txHash });

	// Extract proposalId from ProposalCreated event
	let proposalId = 0;
	for (const log of receipt.logs) {
		try {
			const decoded = decodeEventLog({
				abi: spaceAbi,
				data: log.data,
				topics: log.topics
			});
			if (decoded.eventName === 'ProposalCreated') {
				proposalId = Number(decoded.args.proposalId);
				break;
			}
		} catch {
			// Not our event, skip
		}
	}

	return { proposalId, txHash };
}

/**
 * Vote on a proposal via EthTxAuthenticator.
 */
export async function vote(
	voter: `0x${string}`,
	proposalId: number,
	choice: VoteChoice
): Promise<string> {
	// Encode the vote call data for the authenticator
	const voteData = encodeAbiParameters(
		parseAbiParameters('address, uint256, uint8, (uint8 index, bytes params)[], string'),
		[
			voter,
			BigInt(proposalId),
			choice,
			[{ index: 0, params: '0x' as Hex }], // VanillaVotingStrategy at index 0
			'' // metadataURI
		]
	);

	const txHash = await writeContract(config, {
		address: authenticatorAddress,
		abi: ethTxAuthenticatorAbi,
		functionName: 'authenticate',
		args: [sxSpaceAddress, VOTE_SELECTOR, voteData],
		gas: 5_000_000n
	});

	await waitForTransactionReceipt(config, { hash: txHash });
	return txHash;
}

/**
 * Execute a passed proposal. Anyone can call this.
 */
export async function execute(
	proposalId: number,
	payload: Hex
): Promise<string> {
	const txHash = await writeContract(config, {
		address: sxSpaceAddress,
		abi: spaceAbi,
		functionName: 'execute',
		args: [BigInt(proposalId), payload],
		gas: 5_000_000n
	});

	await waitForTransactionReceipt(config, { hash: txHash });
	return txHash;
}

/**
 * Decode addDocument metadata (and optional setAmendmentRestrictions) from an
 * execution payload. The second MetaTransaction, if present and matching
 * setAmendmentRestrictions, is surfaced as `metadata.restrictions` so /vote can
 * include it in the admin Approve flow.
 */
function decodeProposalPayload(payload: Hex): ProposalMetadata | null {
	try {
		const [transactions] = decodeAbiParameters(
			parseAbiParameters('(address to, uint256 value, bytes data, uint8 operation, uint256 salt)[]'),
			payload
		);
		if (!transactions || transactions.length === 0) return null;
		const tx = transactions[0];
		const decoded = decodeFunctionData({
			abi: BVSRegistryABI,
			data: tx.data
		});
		if (decoded.functionName !== 'addDocument') return null;
		const input = (decoded.args as any[])[0];

		let restrictions: ProposalRestrictionMetadata | null = null;
		if (transactions.length >= 2) {
			try {
				const restrictionTx = transactions[1];
				const restrictionDecoded = decodeFunctionData({
					abi: BVSRegistryABI,
					data: restrictionTx.data
				});
				if (restrictionDecoded.functionName === 'setAmendmentRestrictions') {
					const args = restrictionDecoded.args as any[];
					restrictions = {
						minTimeBetweenAmendments: Number(args[2]),
						lockedSections: (args[3] as readonly bigint[]).map(Number)
					};
				}
			} catch {
				// Second tx exists but isn't a recognised restriction call — ignore.
			}
		}

		return {
			title: input.title,
			categoryId: Number(input.categoryId),
			documentId: Number(input.documentId),
			docType: Number(input.docType),
			contentUri: input.contentUri,
			contentHash: input.contentHash,
			restrictions,
			target: tx.to
		};
	} catch {
		return null;
	}
}

/**
 * Check if an address has voted on a proposal.
 */
export async function hasVoted(proposalId: number, voter: `0x${string}`): Promise<boolean> {
	const result = (await readContract(config, {
		address: sxSpaceAddress,
		abi: spaceAbi,
		functionName: 'voteRegistry',
		args: [BigInt(proposalId), voter]
	})) as bigint;
	return result > 0n;
}

/**
 * Get total membership count from BVSToken.
 */
export async function getTotalSupply(): Promise<bigint> {
	return (await readContract(config, {
		...bvsTokenConfig,
		functionName: 'totalSupply'
	})) as bigint;
}

/**
 * Get full proposal info including status and vote counts.
 */
export async function getProposalInfo(proposalId: number, metadataURI?: string, metadata?: ProposalMetadata | null, executionPayload?: Hex): Promise<ProposalInfo> {
	const proposal = (await readContract(config, {
		address: sxSpaceAddress,
		abi: spaceAbi,
		functionName: 'proposals',
		args: [BigInt(proposalId)]
	})) as [string, number, string, number, number, number, Hex, bigint];

	const [author, startBlockNumber, executionStrategy, minEndBlockNumber,
		maxEndBlockNumber, finalizationStatus, executionPayloadHash, activeVotingStrategies] = proposal;

	// Get vote counts
	const [votesFor, votesAgainst, votesAbstain] = await Promise.all([
		readContract(config, {
			address: sxSpaceAddress,
			abi: spaceAbi,
			functionName: 'votePower',
			args: [BigInt(proposalId), VoteChoice.For]
		}) as Promise<bigint>,
		readContract(config, {
			address: sxSpaceAddress,
			abi: spaceAbi,
			functionName: 'votePower',
			args: [BigInt(proposalId), VoteChoice.Against]
		}) as Promise<bigint>,
		readContract(config, {
			address: sxSpaceAddress,
			abi: spaceAbi,
			functionName: 'votePower',
			args: [BigInt(proposalId), VoteChoice.Abstain]
		}) as Promise<bigint>
	]);

	// Get status from execution strategy
	const proposalStruct = {
		author: author as `0x${string}`,
		startBlockNumber,
		executionStrategy: executionStrategy as `0x${string}`,
		minEndBlockNumber,
		maxEndBlockNumber,
		finalizationStatus,
		executionPayloadHash,
		activeVotingStrategies
	};

	const status = (await readContract(config, {
		address: executionStrategy as `0x${string}`,
		abi: executionStrategyAbi,
		functionName: 'getProposalStatus',
		args: [proposalStruct, votesFor, votesAgainst, votesAbstain]
	})) as number;

	return {
		proposalId,
		startBlockNumber,
		minEndBlockNumber,
		maxEndBlockNumber,
		finalizationStatus,
		executionPayloadHash,
		executionStrategy,
		author,
		metadataURI: metadataURI ?? '',
		metadata: metadata ?? null,
		status: status as ProposalStatus,
		votesFor,
		votesAgainst,
		votesAbstain,
		executionPayload: executionPayload ?? '0x'
	};
}

/**
 * Scan BVSRegistry for admin decisions on Snapshot X proposals.
 *
 * Returns a map keyed by snapshotProposalId. A proposal is "approved" if a
 * DocumentAdded event exists whose stored Document.voteId matches the pattern
 * `snapshot-x:<proposalId>`, "rejected" if a ProposalRejected event was emitted
 * for that ID. Both states are terminal from the admin-record point of view.
 */
export interface DecisionRecord {
	status: 'approved' | 'rejected';
	txOrCategory?: number;
	documentId?: number;
	version?: number;
	reason?: string;
	votesFor?: bigint;
	votesAgainst?: bigint;
	votesAbstain?: bigint;
}

const documentAddedEvent = {
	type: 'event' as const,
	name: 'DocumentAdded' as const,
	inputs: [
		{ name: 'categoryId', type: 'uint256' as const, indexed: true },
		{ name: 'documentId', type: 'uint256' as const, indexed: true },
		{ name: 'version', type: 'uint256' as const, indexed: true },
		{ name: 'contentUri', type: 'string' as const, indexed: false },
		{ name: 'contentHash', type: 'bytes32' as const, indexed: false },
		{ name: 'docType', type: 'uint8' as const, indexed: false }
	]
};

const proposalRejectedEvent = {
	type: 'event' as const,
	name: 'ProposalRejected' as const,
	inputs: [
		{ name: 'snapshotProposalId', type: 'uint256' as const, indexed: true },
		{ name: 'votesFor', type: 'uint256' as const, indexed: false },
		{ name: 'votesAgainst', type: 'uint256' as const, indexed: false },
		{ name: 'votesAbstain', type: 'uint256' as const, indexed: false },
		{ name: 'reason', type: 'string' as const, indexed: false }
	]
};

export async function getAdminDecisions(): Promise<Record<number, DecisionRecord>> {
	const client = getClient() as unknown as PublicClient | undefined;
	if (!client) return {};

	const deployBlock = import.meta.env.VITE_DEPLOY_BLOCK
		? BigInt(import.meta.env.VITE_DEPLOY_BLOCK) : 0n;

	const decisions: Record<number, DecisionRecord> = {};

	// Rejections — direct match by indexed snapshotProposalId.
	const rejected = await getPaginatedLogs(client, {
		address: bvsRegistryAddress,
		event: proposalRejectedEvent,
		fromBlock: deployBlock
	}, 'rejections');
	for (const log of rejected.logs as any[]) {
		const id = Number(log.args.snapshotProposalId);
		decisions[id] = {
			status: 'rejected',
			reason: log.args.reason ?? '',
			votesFor: log.args.votesFor as bigint,
			votesAgainst: log.args.votesAgainst as bigint,
			votesAbstain: log.args.votesAbstain as bigint
		};
	}

	// Approvals — DocumentAdded doesn't carry voteId, so we read each document's
	// voteId from the registry to find the snapshot-x:<id> we wrote at approve time.
	const added = await getPaginatedLogs(client, {
		address: bvsRegistryAddress,
		event: documentAddedEvent,
		fromBlock: deployBlock
	}, 'approvals');
	const reads = (added.logs as any[]).map((log) => {
		const catId = log.args.categoryId as bigint;
		const docId = log.args.documentId as bigint;
		const ver = log.args.version as bigint;
		return readContract(config, {
			...bvsRegistryConfig,
			functionName: 'getDocument',
			args: [catId, docId, ver]
		}).then((doc: any) => ({
			catId: Number(catId),
			docId: Number(docId),
			ver: Number(ver),
			voteId: (doc?.voteId ?? '') as string
		})).catch(() => null);
	});
	const docs = await Promise.all(reads);
	for (const d of docs) {
		if (!d) continue;
		const m = d.voteId.match(/^snapshot-x:(\d+)$/);
		if (!m) continue;
		const id = Number(m[1]);
		// Don't overwrite a rejection — admin can only do one of the two for a given proposal
		// in practice, but if both exist (out-of-order writes), preserve rejection priority.
		if (decisions[id]) continue;
		decisions[id] = {
			status: 'approved',
			txOrCategory: d.catId,
			documentId: d.docId,
			version: d.ver
		};
	}

	return decisions;
}

/**
 * Get all proposals by scanning ProposalCreated events.
 * Extracts metadata from execution payload in each event.
 */
export async function getProposals(): Promise<ProposalInfo[]> {
	// Cast to bare PublicClient — the multi-chain wallet config returns a union
	// of chain-narrowed clients (Optimism's OP-stack tx types don't unify with
	// standard chains), but getPaginatedLogs only needs the unparameterised shape.
	const client = getClient() as unknown as PublicClient | undefined;
	if (!client) return [];

	const deployBlock = import.meta.env.VITE_DEPLOY_BLOCK
		? BigInt(import.meta.env.VITE_DEPLOY_BLOCK) : 0n;

	const proposalCreatedEvent = {
		type: 'event' as const,
		name: 'ProposalCreated' as const,
		inputs: [
			{ name: 'proposalId', type: 'uint256' as const, indexed: false },
			{ name: 'author', type: 'address' as const, indexed: false },
			{
				name: 'proposal', type: 'tuple' as const, indexed: false,
				components: [
					{ name: 'author', type: 'address' as const },
					{ name: 'startBlockNumber', type: 'uint32' as const },
					{ name: 'executionStrategy', type: 'address' as const },
					{ name: 'minEndBlockNumber', type: 'uint32' as const },
					{ name: 'maxEndBlockNumber', type: 'uint32' as const },
					{ name: 'finalizationStatus', type: 'uint8' as const },
					{ name: 'executionPayloadHash', type: 'bytes32' as const },
					{ name: 'activeVotingStrategies', type: 'uint256' as const }
				]
			},
			{ name: 'metadataURI', type: 'string' as const, indexed: false },
			{ name: 'payload', type: 'bytes' as const, indexed: false }
		]
	};

	const result = await getPaginatedLogs(client, {
		address: sxSpaceAddress,
		event: proposalCreatedEvent,
		fromBlock: deployBlock
	}, 'proposals');

	if (!result.complete) {
		console.warn('[proposals] Scan incomplete — showing partial results');
	}

	const allEvents = result.logs.map((log: any) => ({
		proposalId: Number(log.args.proposalId),
		metadataURI: log.args.metadataURI ?? '',
		payload: log.args.payload as string
	}));

	// Fetch live status for all proposals in parallel. Each getProposalInfo fires ~3
	// sequential RPC round trips on its own; serializing the outer loop turns that into
	// O(3N) round trips for no reason — proposals are independent lookups. allSettled
	// preserves the prior skip-on-error behaviour.
	const settled = await Promise.allSettled(
		allEvents.map((ev) =>
			getProposalInfo(
				ev.proposalId,
				ev.metadataURI,
				decodeProposalPayload(ev.payload as Hex),
				ev.payload as Hex
			)
		)
	);
	const currentRegistry = bvsRegistryAddress.toLowerCase();
	const proposals: ProposalInfo[] = settled
		.filter((r): r is PromiseFulfilledResult<ProposalInfo> => r.status === 'fulfilled')
		.map((r) => r.value)
		.filter((p) =>
			!p.metadata?.target ||
			p.metadata.target.toLowerCase() === currentRegistry
		);

	return proposals;
}

/**
 * Get the approval threshold for a strategy.
 */
export async function getApprovalThreshold(strategyAddress: `0x${string}`): Promise<number> {
	const pct = (await readContract(config, {
		address: strategyAddress,
		abi: executionStrategyAbi,
		functionName: 'approvalThreshold'
	})) as bigint;
	return Number(pct);
}

/**
 * Get the participation quorum for a strategy (0 = disabled).
 */
export async function getParticipationQuorum(strategyAddress: `0x${string}`): Promise<number> {
	const pct = (await readContract(config, {
		address: strategyAddress,
		abi: executionStrategyAbi,
		functionName: 'participationQuorum'
	})) as bigint;
	return Number(pct);
}

/**
 * Human-readable status label.
 */
export function statusLabel(status: ProposalStatus): string {
	switch (status) {
		case ProposalStatus.VotingDelay: return 'Pending';
		case ProposalStatus.VotingPeriod: return 'Active';
		case ProposalStatus.VotingPeriodAccepted: return 'Passing';
		case ProposalStatus.Accepted: return 'Passed';
		case ProposalStatus.Executed: return 'Executed';
		case ProposalStatus.Rejected: return 'Rejected';
		case ProposalStatus.Cancelled: return 'Cancelled';
		default: return 'Unknown';
	}
}

/**
 * Tailwind class mapping for a proposal status. Pairs with statusLabel().
 */
export function statusClass(status: ProposalStatus): string {
	switch (status) {
		case ProposalStatus.VotingPeriod: return 'text-success';
		case ProposalStatus.VotingPeriodAccepted: return 'text-cat-blue';
		case ProposalStatus.Accepted: return 'text-cat-gold';
		case ProposalStatus.Executed: return 'text-text-secondary';
		case ProposalStatus.Rejected:
		case ProposalStatus.Cancelled: return 'text-error';
		default: return 'text-text-muted';
	}
}

/**
 * Compute For/Against/Abstain percentages for a 3-segment tally bar.
 * Returns integer percents that sum to ≤100 (bigint floor division).
 */
export function tallyBar(
	votesFor: bigint,
	votesAgainst: bigint,
	votesAbstain: bigint
): { forPct: number; againstPct: number; abstainPct: number } {
	const total = votesFor + votesAgainst + votesAbstain;
	if (total === 0n) return { forPct: 0, againstPct: 0, abstainPct: 0 };
	return {
		forPct: Number((votesFor * 100n) / total),
		againstPct: Number((votesAgainst * 100n) / total),
		abstainPct: Number((votesAbstain * 100n) / total)
	};
}

/**
 * Per-strategy threshold/quorum percentages. Keys MUST be lowercase addresses.
 * The consumer page (e.g. /vote) loads these once from each execution strategy
 * (getApprovalThreshold / getParticipationQuorum) and passes this map into the
 * voting-math helpers below, so the helpers stay strategy-list-agnostic.
 */
export interface StrategyQuorums {
	approvalPct: Record<string, number>;
	participationPct: Record<string, number>;
}

/** Ceiling-rounded vote count required to meet the approval threshold. */
export function approvalVotesNeeded(
	strategyAddress: string,
	totalSupply: bigint,
	quorums: StrategyQuorums
): bigint {
	const pct = quorums.approvalPct[strategyAddress.toLowerCase()] ?? 0;
	if (totalSupply === 0n || pct === 0) return 0n;
	return (totalSupply * BigInt(pct) + 99n) / 100n;
}

/** Ceiling-rounded vote count required to meet the participation quorum. */
export function participationVotesNeeded(
	strategyAddress: string,
	totalSupply: bigint,
	quorums: StrategyQuorums
): bigint {
	const pct = quorums.participationPct[strategyAddress.toLowerCase()] ?? 0;
	if (totalSupply === 0n || pct === 0) return 0n;
	return (totalSupply * BigInt(pct) + 99n) / 100n;
}

/** Minimal proposal shape required by the passing/context helpers. */
export interface ProposalTally {
	executionStrategy: string;
	votesFor: bigint;
	votesAgainst: bigint;
	votesAbstain: bigint;
}

/** True iff the proposal meets both the approval threshold and the participation quorum. */
export function isPassing(
	proposal: ProposalTally,
	totalSupply: bigint,
	quorums: StrategyQuorums
): boolean {
	const approvalNeeded = approvalVotesNeeded(proposal.executionStrategy, totalSupply, quorums);
	const approvalMet = proposal.votesFor >= approvalNeeded && proposal.votesFor > proposal.votesAgainst;
	const quorumNeeded = participationVotesNeeded(proposal.executionStrategy, totalSupply, quorums);
	const totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;
	const quorumMet = quorumNeeded === 0n || totalVotes >= quorumNeeded;
	return approvalMet && quorumMet;
}

/** Short sentence describing voting progress (awaiting / in progress / passing / all voted). */
export function votingContext(
	proposal: ProposalTally,
	totalSupply: bigint,
	quorums: StrategyQuorums
): string {
	const totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;
	const allVoted = totalVotes >= totalSupply && totalSupply > 0n;
	const passing = isPassing(proposal, totalSupply, quorums);
	if (allVoted && passing) return 'All members voted — passing';
	if (allVoted && !passing) return 'All members voted — failing';
	if (passing) return 'Quorum reached — passing';
	if (totalVotes > 0n) return 'Voting in progress';
	return 'Awaiting votes';
}

/** Tailwind class for the votingContext() chip. */
export function votingContextClass(
	proposal: ProposalTally,
	totalSupply: bigint,
	quorums: StrategyQuorums
): string {
	const totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;
	const allVoted = totalVotes >= totalSupply && totalSupply > 0n;
	if (isPassing(proposal, totalSupply, quorums)) return 'text-success';
	if (allVoted) return 'text-error';
	return 'text-text-secondary';
}

/**
 * Single execution strategy. Returned for any proposal.
 */
export function selectStrategy(): `0x${string}` {
	return executionStrategyAddress;
}

/**
 * Label for the execution strategy. With a single strategy, this returns a
 * generic label — the page can show approval/quorum percentages from the
 * strategy contract if more detail is needed.
 */
export function strategyLabel(_strategyAddress: string): string {
	return 'Snapshot X';
}
