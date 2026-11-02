// Retrieval cues only. Semantic assessment and an independent review decide credit.
const stop = new Set("a an the and or it is are of to in for with that this they can does what how sleep during from be by its about".split(" "));
const units: Record<string, string> = { minutes: "minute", mins: "minute", min: "minute", hours: "hour", hrs: "hour", hr: "hour", seconds: "second", secs: "second", sec: "second", milliseconds: "millisecond", ms: "millisecond", cycles: "cycle", theories: "theory", memories: "memory" };
function word(value: string) {
  if (units[value]) return units[value]!;
  if (value.length > 5 && value.endsWith("ies")) return value.slice(0, -3) + "y";
  if (value.length > 4 && value.endsWith("s") && !["ss", "is", "ous"].some(s => value.endsWith(s))) return value.slice(0, -1);
  return value;
}
const words = (value: string) => (value.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).map(word);
export function candidateTerms(value: string) { return new Set(words(value).filter(w => !stop.has(w) && (w.length > 2 || /^\d+$/u.test(w)))); }
export function candidateQuantities(value: string) {
  const matches = value.matchAll(/(?<![\p{L}\d.])([0-9]+(?:[.,][0-9]+)?)\s*[-‐‑–—]?\s*(milliseconds?|ms|minutes?|mins?|hours?|hrs?|h|seconds?|secs?|s)\b/giu), result = new Set<string>();
  for (const match of matches) {
    const amount = Number(match[1]!.replace(",", ".")), unit = word(match[2]!.toLowerCase());
    const seconds = amount * (["hour", "h"].includes(unit) ? 3600 : unit === "minute" ? 60 : unit === "millisecond" ? .001 : 1);
    if (Number.isFinite(seconds)) result.add("duration:" + seconds.toFixed(6));
  }
  return result;
}
export function mentionsSubject(alternatives: string[], value: string) { const phrase = " " + words(value).join(" ") + " "; return alternatives.some(a => words(a).length && phrase.includes(" " + words(a).join(" ") + " ")); }
export function candidateMatch(claim: string, answer: string) {
  const answerTerms = candidateTerms(answer), answerQuantities = candidateQuantities(answer);
  const terms = [...candidateTerms(claim)].filter(w => answerTerms.has(w)).length, quantities = [...candidateQuantities(claim)].filter(w => answerQuantities.has(w)).length;
  return { relevant: terms >= 2 || quantities > 0, rank: terms * 10 + quantities * 30, quantities };
}
