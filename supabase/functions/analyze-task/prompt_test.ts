import { alertTones, buildAnalysisPrompt } from "./prompt.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("alert line section is added only when a tone is sent", () => {
  const base = buildAnalysisPrompt("2026-11-01 13:00", "ko");
  assert(!base.includes("alert_line"), "untoned prompt must stay unchanged");
  for (const tone of alertTones) {
    const toned = buildAnalysisPrompt("2026-11-01 13:00", "ko", tone);
    assert(toned.startsWith(base), "toned prompt extends the base prompt");
    assert(toned.includes(`"${tone}"`) && toned.includes("alert_line"), `missing ${tone} guide`);
  }
});

Deno.test("prompt separates recurrence start, inclusive end, and existing-series updates", () => {
  const prompt = buildAnalysisPrompt("2026-11-03 13:00", "ko", undefined, true);
  for (const expected of ["recurrence_end_date", "new_recurrence_end_date", "2026-12-20", "이번 달까지만", "all other new_* fields null", '"none"']) {
    assert(prompt.includes(expected), `missing end-date contract: ${expected}`);
  }
});

Deno.test("legacy prompts do not advertise unsupported recurrence end fields", () => {
  assert(!buildAnalysisPrompt("2026-11-03 13:00", "ko").includes("recurrence_end_date"), "old app must not receive new fields");
});
