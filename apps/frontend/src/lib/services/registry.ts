import { readContract } from '@wagmi/core';
import { config } from '$lib/services/ethereum';
import { bvsRegistryConfig } from '$lib/contracts';

export interface CategoryInfo {
	id: number;
	name: string;
	versionCount: number;
}

export async function loadCategories(): Promise<CategoryInfo[]> {
	const count = (await readContract(config, {
		...bvsRegistryConfig,
		functionName: 'categoryCount'
	})) as bigint;

	const cats: CategoryInfo[] = [];
	for (let i = 0n; i < count; i++) {
		const [name, versionCount] = await Promise.all([
			readContract(config, {
				...bvsRegistryConfig,
				functionName: 'categoryNames',
				args: [i]
			}),
			readContract(config, {
				...bvsRegistryConfig,
				functionName: 'getVersionCount',
				args: [i]
			})
		]);
		cats.push({
			id: Number(i),
			name: name as string,
			versionCount: Number(versionCount as bigint)
		});
	}
	return cats;
}
