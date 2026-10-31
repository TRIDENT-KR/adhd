import { buildAnalysisPrompt } from "../../supabase/functions/analyze-task/prompt.ts";
import {
  analysisFunctionNames,
  validateAnalysisCalls,
} from "../../supabase/functions/analyze-task/validator.ts";
import type { Case, Dataset, Grade, Prediction, Run, Value } from "./types.ts";

export function assert(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${
      Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map((
        [k, v],
      ) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")
    }}`;
  }
  return JSON.stringify(value);
}
export async function hash(value: unknown): Promise<string> {
  const data = new TextEncoder().encode(
    typeof value === "string" ? value : canonical(value),
  );
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", data)),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
export function requestFor(c: Case) {
  return {
    system: buildAnalysisPrompt(c.current_time, c.language),
    text: c.text,
  };
}
export async function fingerprints() {
  const base = new URL(
    "../../supabase/functions/analyze-task/",
    import.meta.url,
  );
  const contract = await Promise.all(
    ["prompt.ts", "validator.ts"].map((f) =>
      Deno.readTextFile(new URL(f, base))
    ),
  );
  const harness = await Promise.all(
    ["types.ts", "core.ts", "cli.ts", "provider.ts", "report.ts"].map((f) =>
      Deno.readTextFile(new URL(f, import.meta.url))
    ),
  );
  return {
    contract_hash: await hash(contract),
    harness_hash: await hash(harness),
  };
}
const nonmutating = new Set(["request_clarification", "handle_off_topic_chat"]);
const destructive = new Set([
  "delete_specific_task",
  "clear_all_tasks",
  "update_task",
  "postpone_all_tasks",
  "mark_task_complete",
]);
export function matches(actual: unknown, expected: Value): boolean {
  if (typeof expected !== "object" || expected === null) {
    return actual === expected;
  }
  if ("one_of" in expected) {
    return typeof actual === "string" && expected.one_of.includes(actual);
  }
  return typeof actual === "string" && actual.trim().length > 0;
}
function example(v: Value): string | null {
  if (v === null || typeof v === "string") return v;
  return "one_of" in v ? v.one_of[0] : "review separately";
}
export function referenceCalls(c: Case) {
  return c.expected.map((call) => ({
    function_name: call.function_name,
    parameters: Object.fromEntries(
      Object.entries(call.parameters).map(([k, v]) => [k, example(v)]),
    ),
  }));
}
export function validateDataset(raw: unknown): Dataset {
  const d = raw as Dataset;
  assert(
    d?.schema_version === 1 && typeof d.name === "string" &&
      d.name.length > 0 && typeof d.version === "string",
    "Invalid dataset header",
  );
  assert(
    ["development", "held_out"].includes(d.purpose),
    "Invalid dataset purpose",
  );
  assert(
    typeof d.provenance === "string" && d.provenance.length > 0,
    "Missing provenance",
  );
  assert(
    ["draft", "human_reviewed"].includes(d.review?.status),
    "Missing review status",
  );
  if (d.review.status === "human_reviewed") {
    assert(
      d.review.reviewer?.trim() &&
        /^\d{4}-\d{2}-\d{2}$/.test(d.review.date ?? ""),
      "Human review needs reviewer and date",
    );
  }
  assert(Array.isArray(d.cases) && d.cases.length > 0, "Empty dataset");
  const ids = new Set<string>(), texts = new Set<string>();
  for (const c of d.cases) {
    assert(
      typeof c.id === "string" && c.id.length > 0 && !ids.has(c.id),
      "Duplicate/missing case ID",
    );
    ids.add(c.id);
    assert(
      typeof c.family === "string" && c.family.length > 0,
      `${c.id}: missing family`,
    );
    assert(
      ["en", "ko", "ja"].includes(c.language),
      `${c.id}: invalid language`,
    );
    assert(
      typeof c.text === "string" && c.text.trim().length > 0 &&
        c.text.length <= 1000,
      `${c.id}: invalid input`,
    );
    const key = `${c.language}:${c.text}`;
    assert(!texts.has(key), `${c.id}: duplicate input`);
    texts.add(key);
    assert(
      /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(c.current_time),
      `${c.id}: invalid wall time`,
    );
    const date = new Date(c.current_time.replace(" ", "T") + ":00Z");
    assert(
      Number.isFinite(date.getTime()) &&
        date.toISOString().slice(0, 16).replace("T", " ") === c.current_time,
      `${c.id}: nonexistent wall time`,
    );
    new Intl.DateTimeFormat("en", { timeZone: c.timezone }).format(date);
    assert(
      ["command", "clarify", "off_topic"].includes(c.kind),
      `${c.id}: invalid kind`,
    );
    assert(["standard", "critical"].includes(c.risk), `${c.id}: invalid risk`);
    assert(
      Array.isArray(c.tags) && c.tags.length > 0 &&
        c.tags.every((t) => typeof t === "string" && t),
      `${c.id}: missing tags`,
    );
    assert(
      typeof c.rationale === "string" && c.rationale.length > 0,
      `${c.id}: missing rationale`,
    );
    assert(
      Array.isArray(c.expected) && c.expected.length > 0,
      `${c.id}: missing gold`,
    );
    for (const call of c.expected) {
      assert(
        analysisFunctionNames.includes(call.function_name),
        `${c.id}: unknown gold function`,
      );
      const route = c.kind === "clarify"
        ? "request_clarification"
        : "handle_off_topic_chat";
      assert(
        c.kind === "command"
          ? !nonmutating.has(call.function_name)
          : call.function_name === route,
        `${c.id}: inconsistent gold kind`,
      );
      for (const [field, v] of Object.entries(call.parameters)) {
        assert(
          v === null || typeof v === "string" ||
            (typeof v === "object" && Object.keys(v).length === 1 &&
              ("one_of" in v
                ? Array.isArray(v.one_of) && v.one_of.length > 0 &&
                  v.one_of.every((x) => typeof x === "string" && x.trim())
                : "nonempty" in v && v.nonempty === true)),
          `${c.id}: invalid matcher`,
        );
        if (v !== null && typeof v === "object" && "nonempty" in v) {
          assert(
            nonmutating.has(call.function_name) &&
              ["reason", "message"].includes(field),
            `${c.id}: wildcard cannot hide a task field`,
          );
        }
      }
    }
    const refs = referenceCalls(c);
    validateAnalysisCalls(refs);
    // All aliases must be accepted by the production schema, not just the first.
    c.expected.forEach((call, index) =>
      Object.entries(call.parameters).forEach(([field, v]) => {
        if (v && typeof v === "object" && "one_of" in v) {
          for (const value of v.one_of) {
            const variant = structuredClone(refs);
            variant[index].parameters[field] = value;
            validateAnalysisCalls(variant);
          }
        }
      })
    );
  }
  return d;
}
export function grade(
  c: Case,
  p: Prediction | undefined,
  trial: number,
): Grade {
  const g: Grade = {
    case_id: c.id,
    family: c.family,
    language: c.language,
    kind: c.kind,
    risk: c.risk,
    tags: c.tags,
    trial,
    observed: !!p,
    json_valid: false,
    schema_valid: false,
    contract_match: false,
    expected_route: c.expected.map((x) => x.function_name).join("+"),
    predicted_route: "ERROR",
    fields: [],
    unexpected_mutation: false,
    destructive_mismatch: false,
    unnecessary_clarification: false,
    issues: [],
  };
  const expectedFields = c.expected.flatMap((call, i) =>
    Object.keys(call.parameters).filter((k) =>
      !["reason", "message"].includes(k)
    ).map((k) => ({ field: `${i}.${k}`, correct: false }))
  );
  g.fields = expectedFields;
  if (!p || p.status !== "ok") {
    g.issues.push(p ? "provider_error" : "missing_prediction");
    return g;
  }
  let raw: unknown;
  try {
    raw = JSON.parse(p.response_text!);
    g.json_valid = true;
  } catch {
    g.issues.push("invalid_json");
    return g;
  }
  // Observe proposed actions even when schema validation rejects them. Not an executed mutation.
  const proposals = Array.isArray(raw) ? raw : [raw];
  const names = proposals.map((x) => x?.function_name).filter((x) =>
    typeof x === "string"
  );
  g.unexpected_mutation = c.kind !== "command" &&
    names.some((n) => !nonmutating.has(n));
  g.unnecessary_clarification = c.kind === "command" &&
    names.includes("request_clarification");
  let calls;
  try {
    calls = validateAnalysisCalls(raw);
    g.schema_valid = true;
  } catch {
    g.destructive_mismatch = names.some((n) => destructive.has(n));
    g.issues.push("invalid_schema");
    return g;
  }
  g.predicted_route = calls.map((x) => x.function_name).join("+");
  if (calls.length !== c.expected.length) g.issues.push("call_count");
  c.expected.forEach((call, i) => {
    if (calls[i]?.function_name !== call.function_name) {
      g.issues.push(`function[${i}]`);
    }
    for (const [k, v] of Object.entries(call.parameters)) {
      const correct = calls[i]?.function_name === call.function_name &&
        matches(calls[i]?.parameters[k], v);
      const field = g.fields.find((f) => f.field === `${i}.${k}`);
      if (field) field.correct = correct;
      if (!correct) g.issues.push(`parameter[${i}].${k}`);
    }
  });
  g.contract_match = g.issues.length === 0;
  g.destructive_mismatch = names.some((n) => destructive.has(n)) &&
    !g.contract_match;
  return g;
}
export function mean(xs: number[]): number | null {
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}
export function percentile(xs: number[], p: number): number | null {
  if (!xs.length) return null;
  const sorted = [...xs].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)];
}
function grouped<T>(xs: T[], key: (x: T) => string): Record<string, T[]> {
  const out: Record<string, T[]> = Object.create(null);
  for (const x of xs) (out[key(x)] ??= []).push(x);
  return out;
}
// Resample scenario families, keeping translations and repeated calls together.
export function clusterInterval(
  values: number[],
  iterations = 4000,
): [number, number] | null {
  if (values.length < 2) return null;
  let state = 20261029;
  const next = () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 4294967296;
  };
  const samples = Array.from(
    { length: iterations },
    () => mean(values.map(() => values[Math.floor(next() * values.length)]))!,
  );
  return [percentile(samples, .025)!, percentile(samples, .975)!];
}
export function summary(gs: Grade[]) {
  const rate = (test: (g: Grade) => boolean, rows = gs) => ({
    n: rows.length,
    count: rows.filter(test).length,
    rate: mean(rows.map((g) => Number(test(g)))),
  });
  const families = Object.values(grouped(gs, (g) => g.family));
  const familyMeans = families.map((rows) =>
    mean(rows.map((g) => Number(g.contract_match)))!
  );
  const confusion: Record<string, Record<string, number>> = Object.create(null);
  for (const g of gs) {
    const row = confusion[g.expected_route] ??= Object.create(null);
    row[g.predicted_route] = (row[g.predicted_route] ?? 0) + 1;
  }
  const labels = [...new Set(gs.map((g) => g.expected_route))];
  const f1s = labels.map((label) => {
    const tp = gs.filter((g) =>
      g.expected_route === label && g.predicted_route === label
    ).length;
    const fp = gs.filter((g) =>
      g.expected_route !== label && g.predicted_route === label
    ).length;
    const fn = gs.filter((g) =>
      g.expected_route === label && g.predicted_route !== label
    ).length;
    return 2 * tp / (2 * tp + fp + fn);
  });
  const fields = grouped(
    gs.flatMap((g) => g.fields),
    (f) => f.field.split(".")[1],
  );
  return {
    contract_match: rate((g) => g.contract_match),
    command_exact: rate(
      (g) => g.contract_match,
      gs.filter((g) => g.kind === "command"),
    ),
    routing_accuracy: rate((g) => g.predicted_route === g.expected_route),
    route_sequence_macro_f1: mean(f1s),
    confusion,
    function_metrics: Object.fromEntries(analysisFunctionNames.map((name) => {
      const has = (route: string) => route.split("+").includes(name);
      const tp = gs.filter((g) =>
        has(g.expected_route) && has(g.predicted_route)
      ).length;
      const fp = gs.filter((g) =>
        !has(g.expected_route) && has(g.predicted_route)
      ).length;
      const fn = gs.filter((g) =>
        has(g.expected_route) && !has(g.predicted_route)
      ).length;
      return [name, {
        support: tp + fn,
        precision: tp + fp ? tp / (tp + fp) : null,
        recall: tp + fn ? tp / (tp + fn) : null,
        f1: 2 * tp + fp + fn ? 2 * tp / (2 * tp + fp + fn) : null,
      }];
    })),
    schema_valid: rate((g) => g.schema_valid),
    json_valid: rate((g) => g.json_valid),
    missing: rate((g) => !g.observed),
    unexpected_mutation: rate(
      (g) => g.unexpected_mutation,
      gs.filter((g) => g.kind !== "command"),
    ),
    destructive_mismatch: rate((g) => g.destructive_mismatch),
    unnecessary_clarification: rate(
      (g) => g.unnecessary_clarification,
      gs.filter((g) => g.kind === "command"),
    ),
    all_repetitions_pass: rate(
      (g) => g.contract_match,
      Object.values(grouped(gs, (g) => g.case_id)).map((rows) => ({
        ...rows[0],
        contract_match: rows.every((g) => g.contract_match),
      })),
    ),
    field_accuracy: Object.fromEntries(
      Object.entries(fields).map((
        [k, rows],
      ) => [k, {
        n: rows.length,
        rate: mean(rows.map((f) => Number(f.correct))),
      }]),
    ),
    family_macro_match: {
      n: familyMeans.length,
      rate: mean(familyMeans),
      bootstrap_95: clusterInterval(familyMeans),
    },
  };
}
function validNonnegative(v: unknown): boolean {
  return typeof v === "number" && Number.isFinite(v) && v >= 0;
}
export async function validateRun(
  d: Dataset,
  r: Run,
  fp?: { contract_hash: string; harness_hash: string },
) {
  fp ??= await fingerprints();
  assert(
    r.schema_version === 1 && r.dataset_hash === await hash(d),
    "Dataset hash mismatch",
  );
  assert(
    r.contract_hash === fp.contract_hash && r.harness_hash === fp.harness_hash,
    "Contract/harness hash mismatch; use the original evaluation commit",
  );
  assert(
    Number.isInteger(r.repetitions) && r.repetitions >= 1 &&
      r.repetitions <= 20,
    "Invalid repetitions",
  );
  assert(
    ["live", "imported", "fixture"].includes(r.evidence_kind),
    "Invalid evidence kind",
  );
  assert(
    typeof r.system === "string" && r.system.trim() &&
      typeof r.model === "string" && r.model.trim() &&
      typeof r.source_revision === "string" && r.source_revision.trim(),
    "Missing system/model/revision",
  );
  assert(
    r.configuration && typeof r.configuration === "object" &&
      !Array.isArray(r.configuration),
    "Missing configuration",
  );
  assert(
    typeof r.created_at === "string" &&
      Number.isFinite(Date.parse(r.created_at)),
    "Missing run timestamp",
  );
  assert(Array.isArray(r.predictions), "Invalid predictions");
  const cases = new Map(d.cases.map((c) => [c.id, c]));
  const seen = new Set<string>();
  for (const p of r.predictions) {
    const c = cases.get(p.case_id);
    assert(c, "Unknown prediction ID");
    const key = `${p.case_id}:${p.trial}`;
    assert(
      Number.isInteger(p.trial) && p.trial >= 0 && p.trial < r.repetitions &&
        !seen.has(key),
      "Duplicate/invalid trial",
    );
    seen.add(key);
    assert(
      p.request_hash === await hash(requestFor(c)),
      "Request hash mismatch",
    );
    assert(["ok", "error"].includes(p.status), "Invalid prediction status");
    assert(
      p.status !== "ok" || typeof p.response_text === "string",
      "Missing response text",
    );
    assert(
      p.latency_ms === null || validNonnegative(p.latency_ms),
      "Invalid latency",
    );
    for (const k of ["input_tokens", "output_tokens", "cost_usd"] as const) {
      assert(p[k] === undefined || validNonnegative(p[k]), `Invalid ${k}`);
    }
  }
}
export async function evaluate(d: Dataset, r: Run) {
  await validateRun(d, r);
  const predictions = new Map(
    r.predictions.map((p) => [`${p.case_id}:${p.trial}`, p]),
  );
  const rows = d.cases.flatMap((c) =>
    Array.from(
      { length: r.repetitions },
      (_, t) => grade(c, predictions.get(`${c.id}:${t}`), t),
    )
  );
  const overall = summary(rows);
  const latencies = r.predictions.filter((p) => p.latency_ms !== null).map(
    (p) => p.latency_ms!,
  );
  const priced = r.predictions.filter((p) => p.cost_usd !== undefined);
  const reasons = [
    "No automatic product release approval; task execution, alarm delivery, STT and reply quality require separate QA.",
  ];
  if (d.purpose !== "held_out" || d.review.status !== "human_reviewed") {
    reasons.push(
      "Development or unreviewed labels: regression evidence only, not a production accuracy estimate.",
    );
  }
  if (r.evidence_kind === "fixture") {
    reasons.push("FIXTURE: no model was evaluated.");
  }
  if (overall.family_macro_match.n < 100) {
    reasons.push(
      "Fewer than 100 independent scenario families; small-sample intervals are exploratory.",
    );
  }
  if (overall.contract_match.count === overall.contract_match.n) {
    reasons.push(
      "Zero observed errors is not proof of zero true risk; a degenerate bootstrap interval does not establish safety.",
    );
  }
  return {
    tool: "MORA Eval",
    schema_version: 1,
    dataset: {
      name: d.name,
      version: d.version,
      hash: r.dataset_hash,
      purpose: d.purpose,
      review: d.review,
    },
    run: { ...r, predictions: undefined },
    overall,
    by_language: Object.fromEntries(
      Object.entries(grouped(rows, (g) => g.language)).map((
        [k, v],
      ) => [k, summary(v)]),
    ),
    by_risk: Object.fromEntries(
      Object.entries(grouped(rows, (g) => g.risk)).map((
        [k, v],
      ) => [k, summary(v)]),
    ),
    by_tag: Object.fromEntries(
      [...new Set(rows.flatMap((g) => g.tags))].map(
        (tag) => [tag, summary(rows.filter((g) => g.tags.includes(tag)))],
      ),
    ),
    performance: {
      measured: latencies.length,
      expected: rows.length,
      p50_ms: percentile(latencies, .5),
      p95_ms: percentile(latencies, .95),
      p95_reliable_sample: latencies.length >= 100,
      priced: priced.length,
      total_cost_usd: priced.length === rows.length
        ? priced.reduce((s, p) => s + p.cost_usd!, 0)
        : null,
    },
    interpretation: reasons,
    rows,
  };
}
export async function compare(d: Dataset, a: Run, b: Run) {
  const [ar, br] = await Promise.all([evaluate(d, a), evaluate(d, b)]);
  assert(
    a.repetitions === b.repetitions,
    "Paired comparison requires equal repetitions",
  );
  assert(
    ar.overall.missing.count === 0 && br.overall.missing.count === 0,
    "Paired comparison requires every case/trial (errors must be explicit)",
  );
  assert(
    a.evidence_kind !== "fixture" && b.evidence_kind !== "fixture",
    "Fixture scores cannot compare model quality",
  );
  const familyDeltas = Object.values(
    grouped(
      ar.rows.map((g, i) => ({
        ...g,
        delta: Number(br.rows[i].contract_match) - Number(g.contract_match),
      })),
      (g) => g.family,
    ),
  ).map((rows) => mean(rows.map((g) => g.delta))!);
  const interval = clusterInterval(familyDeltas);
  return {
    baseline: a.system,
    candidate: b.system,
    dataset_hash: a.dataset_hash,
    families: familyDeltas.length,
    family_macro_delta: mean(familyDeltas),
    paired_family_bootstrap_95: interval,
    baseline_only_correct:
      ar.rows.filter((g, i) => g.contract_match && !br.rows[i].contract_match)
        .length,
    candidate_only_correct:
      br.rows.filter((g, i) => g.contract_match && !ar.rows[i].contract_match)
        .length,
    candidate_critical_regressions: br.rows.filter((g, i) =>
      g.risk === "critical" && !g.contract_match && ar.rows[i].contract_match
    ).map((g) => `${g.case_id}:${g.trial}`),
    candidate_new_risky_proposals: br.rows.filter((g, i) =>
      (g.unexpected_mutation && !ar.rows[i].unexpected_mutation) ||
      (g.destructive_mismatch && !ar.rows[i].destructive_mismatch)
    ).map((g) => `${g.case_id}:${g.trial}`),
    baseline_metrics: ar.overall,
    candidate_metrics: br.overall,
    limitations: [...new Set([...ar.interpretation, ...br.interpretation])],
    baseline_performance: ar.performance,
    candidate_performance: br.performance,
    interpretation:
      "Paired descriptive comparison, not an automatic winner. Fix minimum useful improvement and risk tolerance BEFORE seeing held-out results. Bootstrap is clustered by family, not by translated/repeated rows.",
  };
}
