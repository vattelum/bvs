/**
 * Parse `variables:` blocks declared in document YAML frontmatter.
 *
 * Templates declare optional placeholders that downstream renderers can
 * surface as labels or form fields. BVS itself does not write templates,
 * but the /propose and /vote pages parse `variables:` blocks when reading
 * existing documents so a target-document picker can show the declared
 * fields alongside the section list.
 */

export interface TemplateVariable {
	name: string;
	label: string;
	type: string;
	required: boolean;
}

/**
 * Parse `variables:` block from document YAML frontmatter.
 * Returns structured variable definitions, or empty array if none found.
 */
export function parseVariableSchema(content: string): TemplateVariable[] {
	const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
	if (!fmMatch) return [];

	const yamlBlock = fmMatch[1];
	if (!yamlBlock.includes('variables:')) return [];

	const varsMatch = yamlBlock.match(/variables:\n((?:\s+-[\s\S]*?)*)(?=\n\w|\s*$)/);
	if (!varsMatch) return [];

	const entries = varsMatch[1].split(/\n\s*-\s*/).filter(Boolean);

	return entries
		.map((entry) => {
			const nameMatch = entry.match(/name:\s*"?([^"\n,}]+)"?/);
			const labelMatch = entry.match(/label:\s*"?([^"\n,}]+)"?/);
			const typeMatch = entry.match(/type:\s*"?([^"\n,}]+)"?/);
			const reqMatch = entry.match(/required:\s*(true|false)/);

			const name = nameMatch?.[1]?.trim() ?? '';
			// Legacy templates use `type: "string"`; downstream consumers expect
			// HTML-input-aligned `'text'`. Normalise here so the rest of the
			// codebase sees one canonical value.
			let type = typeMatch?.[1]?.trim() ?? 'text';
			if (type === 'string') type = 'text';
			return {
				name,
				label: labelMatch?.[1]?.trim() ?? name,
				type,
				required: reqMatch?.[1] === 'true'
			};
		})
		.filter((v) => v.name);
}
