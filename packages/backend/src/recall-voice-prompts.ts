import type { Question } from "./recall-contracts.js";

/** Prepared from already reviewed question givens; never from the answer key. */
export function prepareVoicePrompts(question: Question): NonNullable<Question["voicePrompts"]> {
  const criteria = Object.fromEntries(question.criteria.map(criterion => {
    const probes: { prompt: string; clarification: string }[] = [];
    const add = (prompt: string, clarification: string) => { if (!probes.some(p => p.prompt === prompt)) probes.push({ prompt, clarification }); };
    const reviewed = question.verification?.voiceScopes;
    const scopes = reviewed && typeof reviewed === "object" && !Array.isArray(reviewed) ? (reviewed as Record<string, unknown>)[criterion.id] : [];
    // Legacy banks can narrow an explicitly named final scope without a new
    // model call. Every inserted scope must still occur in the visible prompt.
    const finalScope = question.prompt.split(/\band\s+/iu).at(-1)?.trim().replace(/[?.!]+$/u, "") ?? "";
    const legacy = finalScope !== question.prompt.replace(/[?.!]+$/u, "") && finalScope.split(/\s+/u).length <= 8 ? [finalScope] : [];
    for (const scope of [...(Array.isArray(scopes) ? scopes.filter((s): s is string => typeof s === "string") : []), ...legacy, ...(criterion.promptGivens ?? [])]) {
      const clean = scope.trim().replace(/[?.!]+$/u, "");
      if (clean && clean.length <= 160 && question.prompt.includes(scope) && scope !== question.prompt) {
        add(`What else can you say about ${clean}?`, `I'm asking about ${clean}.`);
      }
    }
    return [criterion.id, [...probes.slice(0, 2), { prompt: question.prompt, clarification: "Let me restate the question: " + question.prompt }]];
  }));
  return { version: "voice-probes-v1", criteria };
}
