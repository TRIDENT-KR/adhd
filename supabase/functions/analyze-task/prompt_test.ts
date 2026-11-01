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
