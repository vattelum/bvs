import BVSTokenABI from './BVSToken.abi.json';
import BVSRegistryABI from './BVSRegistry.abi.json';

export const bvsTokenAddress = import.meta.env.VITE_BVS_TOKEN_ADDRESS as `0x${string}`;
export const bvsRegistryAddress = import.meta.env.VITE_BVS_REGISTRY_ADDRESS as `0x${string}`;
export const sxSpaceAddress = import.meta.env.VITE_SX_SPACE_ADDRESS as `0x${string}`;
export const executionStrategyAddress = import.meta.env.VITE_EXECUTION_STRATEGY_ADDRESS as `0x${string}`;
export const authenticatorAddress = import.meta.env.VITE_AUTHENTICATOR_ADDRESS as `0x${string}`;
export const adminAddress = import.meta.env.VITE_ADMIN_ADDRESS as `0x${string}`;

export const membersCanPropose =
	(import.meta.env.VITE_MEMBERS_CAN_PROPOSE ?? 'false').toString().toLowerCase() === 'true';

export const bvsTokenConfig = {
	address: bvsTokenAddress,
	abi: BVSTokenABI
} as const;

export const bvsRegistryConfig = {
	address: bvsRegistryAddress,
	abi: BVSRegistryABI
} as const;

export { BVSTokenABI, BVSRegistryABI };
