// Read-only reuse of the actual production response validator, not a duplicate.
import { validateAnalysisCalls } from "../../supabase/functions/analyze-task/validator.ts";

for (const path of Deno.args) {
  const lines = (await Deno.readTextFile(path)).trim().split("\n");
  const cases = lines.map((line) => {
    const row = JSON.parse(line);
    try {
      if (row.finish_reason !== "stop") throw new Error(`finish_reason=${row.finish_reason}`);
      validateAnalysisCalls(row.parsed);
      return { id: row.id, valid: true };
    } catch (error) {
      return { id: row.id, valid: false, reason: String(error) };
    }
  });
  console.log(JSON.stringify({ path, count: cases.length, valid: cases.filter(c => c.valid).length, cases }));
}
