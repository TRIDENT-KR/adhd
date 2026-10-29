import {
  assert,
  clusterInterval,
  compare,
  evaluate,
  fingerprints,
  grade,
  hash,
  referenceCalls,
  requestFor,
  validateDataset,
  validateRun,
} from "./core.ts";
import type { Case, Dataset, Prediction, Run } from "./types.ts";

const dataset = validateDataset(
  JSON.parse(
    await Deno.readTextFile(new URL("data/mora-v1.json", import.meta.url)),
  ),
);
const by = (id: string) =>
  structuredClone(dataset.cases.find((c) => c.id === id)!);
async function prediction(
  c: Case,
  output: unknown = referenceCalls(c),
  trial = 0,
): Promise<Prediction> {
  return {
    case_id: c.id,
    trial,
    request_hash: await hash(requestFor(c)),
    status: "ok",
    response_text: JSON.stringify(output),
    latency_ms: 100,
  };
}
async function run(d: Dataset = dataset, reps = 1): Promise<Run> {
  const predictions = [];
  for (const c of d.cases) {
    for (let t = 0; t < reps; t++) {
      predictions.push(await prediction(c, referenceCalls(c), t));
    }
  }
  return {
    schema_version: 1,
    dataset_hash: await hash(d),
    ...await fingerprints(),
    source_revision: "test-only",
    system: "test",
    model: "no-model",
    configuration: {},
    evidence_kind: "fixture",
    created_at: "2026-10-29T00:00:00Z",
    repetitions: reps,
    predictions,
  };
}
async function rejects(fn: () => unknown | Promise<unknown>, fragment: string) {
  try {
    await fn();
  } catch (e) {
    assert(
      e instanceof Error && e.message.includes(fragment),
      `Wrong rejection: ${String(e)}`,
    );
    return;
  }
  throw new Error(`Expected rejection: ${fragment}`);
}
Deno.test("102 original cases cover three languages and every production function", () => {
  assert(dataset.cases.length === 102, "dataset size changed; review coverage");
  assert(
    new Set(dataset.cases.map((c) => c.family)).size === 34,
    "translations cannot count as independent scenarios",
  );
  for (const lang of ["ko", "en", "ja"]) {
    assert(
      dataset.cases.filter((c) => c.language === lang).length === 34,
      "language coverage",
    );
  }
  assert(
    new Set(
      dataset.cases.flatMap((c) => c.expected.map((x) => x.function_name)),
    ).size === 8,
    "missing function",
  );
});
Deno.test("gold references are complete and match the production schema", async () => {
  for (const c of dataset.cases) {
    assert(grade(c, await prediction(c), 0).contract_match, c.id);
  }
});
Deno.test("date, title, recurrence, urgency and null errors cannot pass partial matching", async () => {
  const c = by("tomorrow-ko");
  for (
    const [field, value] of [
      ["date", "2026-10-31"],
      ["task_name", "다른 일정"],
      ["recurrence", "weekly"],
      ["urgency", "weak"],
      ["time", null],
    ]
  ) {
    const calls = referenceCalls(c);
    calls[0].parameters[field!] = value;
    const g = grade(c, await prediction(c, calls), 0);
    assert(!g.contract_match && g.schema_valid, `${field} falsely accepted`);
  }
});
Deno.test("update new_time is scored and target mismatch is destructive proxy", async () => {
  const c = by("update-time-en"), calls = referenceCalls(c);
  calls[0].parameters.new_time = "09:30 PM";
  const g = grade(c, await prediction(c, calls), 0);
  assert(
    g.destructive_mismatch && !g.contract_match &&
      g.issues.includes("parameter[0].new_time"),
    "old runner bug returned",
  );
});
Deno.test("wrong deletion date is detected despite valid JSON and correct function", async () => {
  const c = by("negated-date-ja"), calls = referenceCalls(c);
  calls[0].parameters.target_date = "2026-10-30";
  const g = grade(c, await prediction(c, calls), 0);
  assert(
    g.schema_valid && !g.contract_match && g.destructive_mismatch,
    "unsafe delete escaped",
  );
});
Deno.test("extra calls, missing calls and reordering fail whole-command matching", async () => {
  const c = by("two-commands-en"), calls = referenceCalls(c);
  for (
    const out of [[...calls, calls[0]], calls.slice(0, 1), [...calls].reverse()]
  ) {
    assert(
      !grade(c, await prediction(c, out), 0).contract_match,
      "call sequence accepted",
    );
  }
});
Deno.test("clarifying every input cannot inflate task accuracy", async () => {
  const c = by("tomorrow-en"), output = referenceCalls(by("missing-name-en"));
  const g = grade(c, await prediction(c, output), 0);
  assert(
    !g.contract_match && g.unnecessary_clarification && !g.destructive_mismatch,
    "abstention mis-scored",
  );
});
Deno.test("mutating a clarification or chat case is separately measured", async () => {
  for (const id of ["delete-exception-en", "vent-ko"]) {
    const c = by(id),
      g = grade(
        c,
        await prediction(c, referenceCalls(by("clear-today-en"))),
        0,
      );
    assert(
      g.unexpected_mutation && g.destructive_mismatch && !g.contract_match,
      "unsafe mutation escaped",
    );
  }
});
Deno.test("malformed destructive output is not credited as schema valid or harmless", async () => {
  const c = by("delete-exception-ko");
  const g = grade(
    c,
    await prediction(c, [{ function_name: "clear_all_tasks", parameters: {} }]),
    0,
  );
  assert(
    !g.schema_valid && g.unexpected_mutation && g.destructive_mismatch,
    "bad schema hidden",
  );
});
Deno.test("single objects, empty arrays, fences and invalid JSON are not repaired into passes", async () => {
  const c = by("tomorrow-en");
  for (
    const text of [
      "{",
      "[]",
      JSON.stringify(referenceCalls(c)[0]),
      "```json\n" + JSON.stringify(referenceCalls(c)) + "\n```",
      "null",
    ]
  ) {
    const p = await prediction(c);
    p.response_text = text;
    assert(!grade(c, p, 0).contract_match, "repair inflated score");
  }
});
Deno.test("dataset rejects duplicate rows, wildcard task fields, invalid aliases and invalid dates", async () => {
  let d = structuredClone(dataset);
  d.cases.push(d.cases[0]);
  await rejects(() => validateDataset(d), "Duplicate");
  d = structuredClone(dataset);
  d.cases[0].expected[0].parameters.task_name = { nonempty: true };
  await rejects(() => validateDataset(d), "wildcard");
  d = structuredClone(dataset);
  d.cases[0].expected[0].parameters.time = { one_of: ["02:00 PM", "25:00 PM"] };
  await rejects(() => validateDataset(d), "invalid time");
  d = structuredClone(dataset);
  d.cases[0].current_time = "2026-02-30 10:00";
  await rejects(() => validateDataset(d), "nonexistent");
});
Deno.test("run identity rejects changed data, contract, duplicate predictions and unknown IDs", async () => {
  let r = await run();
  r.dataset_hash = "wrong";
  await rejects(() => evaluate(dataset, r), "Dataset hash");
  r = await run();
  r.contract_hash = "wrong";
  await rejects(() => evaluate(dataset, r), "Contract/harness");
  r = await run();
  r.predictions.push(r.predictions[0]);
  await rejects(() => evaluate(dataset, r), "Duplicate");
  r = await run();
  r.predictions[0].case_id = "ghost";
  await rejects(() => evaluate(dataset, r), "Unknown");
  r = await run();
  r.predictions[0].request_hash = "wrong";
  await rejects(() => evaluate(dataset, r), "Request hash");
});
Deno.test("missing predictions and provider failures stay in the denominator", async () => {
  const r = await run();
  r.predictions.pop();
  r.predictions[0].status = "error";
  const report = await evaluate(dataset, r);
  assert(
    report.overall.contract_match.n === 102 &&
      report.overall.contract_match.count === 100,
    "survivorship bias",
  );
  assert(
    report.overall.missing.count === 1 &&
      report.performance.total_cost_usd === null,
    "missing/cost hidden",
  );
});
Deno.test("fixture reports cannot become quality comparisons", async () => {
  const r = await run(), report = await evaluate(dataset, r);
  assert(
    report.interpretation.some((x) => x.includes("FIXTURE")),
    "unlabelled fixture",
  );
  assert(
    report.dataset.review.status === "draft" &&
      report.interpretation.some((x) => x.includes("regression")),
    "unreviewed score overclaimed",
  );
  await rejects(() => compare(dataset, r, r), "Fixture");
});
Deno.test("paired comparison requires complete equal trials and exposes critical regressions", async () => {
  const a = await run(), b = await run();
  a.evidence_kind = b.evidence_kind = "imported";
  const i = dataset.cases.findIndex((c) => c.id === "negated-date-ko");
  b.predictions[i].response_text = JSON.stringify(
    referenceCalls(by("clear-today-ko")),
  );
  const result = await compare(dataset, a, b);
  assert(
    result.family_macro_delta! < 0 && result.baseline_only_correct === 1 &&
      result.candidate_critical_regressions.includes("negated-date-ko:0"),
    "regression hidden",
  );
  b.predictions.pop();
  await rejects(() => compare(dataset, a, b), "every case/trial");
  const repeat = await run(dataset, 2);
  repeat.evidence_kind = "imported";
  await rejects(() => compare(dataset, a, repeat), "equal repetitions");
});
Deno.test("repetitions reduce all-trials reliability but never multiply independent families", async () => {
  const r = await run(dataset, 2);
  r.predictions[0].status = "error";
  const report = await evaluate(dataset, r);
  assert(report.overall.family_macro_match.n === 34, "pseudo replication");
  assert(
    report.overall.all_repetitions_pass.n === 102 &&
      report.overall.all_repetitions_pass.count === 101,
    "reliability denominator",
  );
  assert(
    report.overall.contract_match.n === 204 &&
      report.overall.contract_match.count === 203,
    "per-attempt denominator",
  );
});
Deno.test("cluster bootstrap is deterministic, bounded and does not claim an interval for one family", () => {
  assert(clusterInterval([1]) === null, "one family inference");
  const a = clusterInterval([0, .25, .75, 1]);
  assert(
    JSON.stringify(a) === JSON.stringify(clusterInterval([0, .25, .75, 1])),
    "unstable interval",
  );
  assert(a![0] >= 0 && a![1] <= 1, "out-of-range interval");
});
Deno.test("negative timing/cost cannot create fake savings", async () => {
  const r = await run();
  r.predictions[0].cost_usd = -1;
  await rejects(() => validateRun(dataset, r), "cost_usd");
});

Deno.test("single-object destructive proposal still appears in safety diagnostics", async () => {
  const c = by("delete-exception-ko");
  const g = grade(
    c,
    await prediction(c, { function_name: "clear_all_tasks", parameters: {} }),
    0,
  );
  assert(
    !g.schema_valid && g.unexpected_mutation && g.destructive_mismatch,
    "non-array proposal hidden",
  );
});
Deno.test("safety regressions are visible even when both systems fail exact matching", async () => {
  const a = await run(), b = await run();
  a.evidence_kind = b.evidence_kind = "imported";
  const i = dataset.cases.findIndex((c) => c.id === "tomorrow-ko");
  a.predictions[i].response_text = JSON.stringify(
    referenceCalls(by("missing-name-ko")),
  );
  b.predictions[i].response_text = JSON.stringify(
    referenceCalls(by("clear-today-ko")),
  );
  const result = await compare(dataset, a, b);
  assert(
    result.candidate_new_risky_proposals.includes("tomorrow-ko:0"),
    "same exact score hid unsafe proposal",
  );
});
