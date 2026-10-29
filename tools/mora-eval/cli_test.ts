import { main } from "./cli.ts";
import { assert } from "./core.ts";
async function fails(args: string[], text: string) {
  try {
    await main(args);
  } catch (e) {
    assert(String(e).includes(text), String(e));
    return;
  }
  throw new Error("Expected CLI failure");
}
Deno.test("live inference cannot start accidentally or with an insufficient request cap", async () => {
  await fails(["live", "--out", "runs/must-not-exist"], "require --live");
  await fails([
    "live",
    "--live",
    "--model",
    "gemini-test",
    "--max-requests",
    "1",
    "--out",
    "runs/must-not-exist",
  ], "complete dataset");
  await fails(
    ["prepare", "--out", "runs/must-not-exist", "--unexpected", "1"],
    "Unknown option",
  );
});
Deno.test("CLI prepare hides gold; scoring missing outputs fails all rows; output cannot overwrite", async () => {
  await Deno.mkdir(new URL("runs/", import.meta.url), { recursive: true });
  const root = await Deno.makeTempDir({
    dir: new URL("runs/", import.meta.url).pathname,
  });
  try {
    const pack = `${root}/pack`, report = `${root}/report`;
    const args = [
      "prepare",
      "--out",
      pack,
      "--model",
      "external-test",
      "--system",
      "external-pipeline",
      "--revision",
      "test-revision",
    ];
    await main(args);
    const requests = (await Deno.readTextFile(`${pack}/requests.jsonl`)).trim()
      .split("\n").map((s) => JSON.parse(s));
    assert(
      requests.length === 102 &&
        requests.every((r) =>
          !("expected" in r) && !("rationale" in r) && !("kind" in r) &&
          typeof r.system === "string"
        ),
      "gold exported",
    );
    await fails(args, "exists");
    await main(["score", "--run", `${pack}/run.json`, "--out", report]);
    const result = JSON.parse(await Deno.readTextFile(`${report}/report.json`));
    assert(
      result.overall.contract_match.rate === 0 &&
        result.overall.missing.count === 102,
      "empty template gave a score",
    );
    assert(
      (await Deno.readTextFile(`${report}/report.md`)).includes(
        "Missing outputs",
      ),
      "missing human report",
    );
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
