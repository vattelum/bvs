import BVSTokenABI from './BVSToken.abi.json';
import BVSRegistryABI from './BVSRegistry.abi.json';

export const bvsTokenAddress = import.meta.env.VITE_BVS_TOKEN_ADDRESS as `0x${string}`;
export const bvsRegistryAddress = import.meta.env.VITE_BVS_REGISTRY_ADDRESS as `0x${string}`;

export const bvsTokenConfig = {
	address: bvsTokenAddress,
	abi: BVSTokenABI
} as const;

export const bvsRegistryConfig = {
	address: bvsRegistryAddress,
	abi: BVSRegistryABI
} as const;

export { BVSTokenABI, BVSRegistryABI };
