// Canonical prompt lines are shared with Recall Lab without parsing TypeScript source.
import policyLines from "./policies.json" with { type: "json" };

export const policies = Object.fromEntries(
  Object.entries(policyLines).map(([key, lines]) => [key, lines.join("\n")]),
) as { [Key in keyof typeof policyLines]: string };
