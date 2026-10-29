import { markdown } from "./report.ts";
import {
  assert,
  compare,
  evaluate,
  fingerprints,
  hash,
  referenceCalls,
  requestFor,
  validateDataset,
} from "./core.ts";
import { callGemini } from "./provider.ts";
import type { Run } from "./types.ts";

const help = `MORA Eval — MORA AI 평가 하네스
Offline (no API calls):
  deno task validate
  deno task prepare --out ./runs/request-pack --model MODEL --system SYSTEM --revision COMMIT
  deno task fixture --out ./runs/self-check
  deno task score --run ./runs/run.json --out ./runs/report
  deno task compare --baseline ./runs/a.json --candidate ./runs/b.json --out ./runs/comparison
Live (explicit opt-in; Gemini only; sequential, no retries):
  deno task live --live --model gemini-MODEL --max-requests 102 --out ./runs/gemini
Common: --dataset PATH --repetitions 1..20 --revision COMMIT
Live options: --max-output-tokens 2048 --timeout-ms 30000
Outputs must be new directories. Keys: GEMINI_API_KEY environment only.
prepare exports gold-free requests and a run template for external pipelines (e.g. Jev+Gemini).
FIXTURE results prove scorer plumbing only. No automatic product release PASS is emitted.`;

export async function main(args = Deno.args) {
  const [command, ...rest] = args;
  if (!command || command === "--help") {
    console.log(help);
    return;
  }
  const options: Record<string, string> = {};
  const allowed = new Set([
    "dataset",
    "out",
    "model",
    "system",
    "revision",
    "run",
    "baseline",
    "candidate",
    "repetitions",
    "max-requests",
    "max-output-tokens",
    "timeout-ms",
  ]);
  let live = false;
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (arg === "--live") {
      assert(!live, "Duplicate --live");
      live = true;
      continue;
    }
    assert(
      arg.startsWith("--") && allowed.has(arg.slice(2)),
      `Unknown option: ${arg}`,
    );
    const k = arg.slice(2);
    assert(
      !(k in options) && rest[i + 1] && !rest[i + 1].startsWith("--"),
      `Missing or duplicate ${arg}`,
    );
    options[k] = rest[++i];
  }
  assert(
    ["validate", "prepare", "fixture", "score", "compare", "live"].includes(
      command,
    ),
    "Unknown command; use --help",
  );
  const d = validateDataset(
    JSON.parse(
      await Deno.readTextFile(
        options.dataset ?? new URL("data/mora-v1.json", import.meta.url),
      ),
    ),
  );
  if (command === "validate") {
    console.log(
      JSON.stringify(
        {
          tool: "MORA Eval",
          cases: d.cases.length,
          families: new Set(d.cases.map((c) => c.family)).size,
          review: d.review,
          dataset_hash: await hash(d),
        },
        null,
        2,
      ),
    );
    return;
  }
  const out = options.out;
  assert(out, "--out must be a new directory");
  const readRun = async (p: string | undefined): Promise<Run> => {
    assert(p, "Missing run path");
    return JSON.parse(await Deno.readTextFile(p));
  };
  if (command === "score" || command === "compare") {
    const report = command === "score"
      ? await evaluate(d, await readRun(options.run))
      : await compare(
        d,
        await readRun(options.baseline),
        await readRun(options.candidate),
      );
    await Deno.mkdir(out);
    await Deno.writeTextFile(
      `${out}/report.json`,
      JSON.stringify(report, null, 2) + "\n",
    );
    if ("rows" in report) {
      await Deno.writeTextFile(`${out}/report.md`, markdown(report));
    }
    console.log(`${out}/report.json`);
    return;
  }
  const repetitions = Number(options.repetitions ?? 1);
  assert(
    Number.isInteger(repetitions) && repetitions >= 1 && repetitions <= 20,
    "repetitions must be 1..20",
  );
  const maxRequests = Number(options["max-requests"]);
  const cfg = {
    model: options.model ?? "",
    max_output_tokens: Number(options["max-output-tokens"] ?? 2048),
    timeout_ms: Number(options["timeout-ms"] ?? 30000),
  };
  let key = "";
  if (command === "live") {
    assert(live, "Live calls require --live");
    assert(
      /^gemini-[a-z0-9._-]+$/.test(cfg.model),
      "Explicit --model gemini-... required",
    );
    assert(
      Number.isInteger(maxRequests) &&
        maxRequests >= d.cases.length * repetitions && maxRequests <= 10000,
      "--max-requests must cover the complete dataset and be <=10000",
    );
    assert(
      Number.isInteger(cfg.max_output_tokens) && cfg.max_output_tokens >= 1 &&
        cfg.max_output_tokens <= 8192,
      "Invalid token cap",
    );
    assert(
      Number.isInteger(cfg.timeout_ms) && cfg.timeout_ms >= 1 &&
        cfg.timeout_ms <= 120000,
      "Invalid timeout",
    );
    key = Deno.env.get("GEMINI_API_KEY") ?? "";
    assert(key.trim(), "GEMINI_API_KEY is not set");
  }
  if (command === "prepare") {
    assert(
      options.model && options.system && options.revision,
      "prepare needs --model, --system and --revision",
    );
  }
  const run: Run = {
    schema_version: 1,
    dataset_hash: await hash(d),
    ...await fingerprints(),
    source_revision: options.revision ?? "not-recorded",
    system: options.system ??
      (command === "fixture" ? "FIXTURE-reference" : "gemini-direct"),
    model: options.model ?? "FIXTURE-no-model",
    configuration: command === "live"
      ? {
        ...cfg,
        temperature: 0.1,
        max_requests: maxRequests,
        concurrency: 1,
        retries: 0,
        scope: "model-only; no Supabase quota/task mutation",
      }
      : {
        note:
          "External pipelines must record versions, thresholds, fallback policy and total pipeline timing/cost here.",
      },
    evidence_kind: command === "fixture"
      ? "fixture"
      : command === "live"
      ? "live"
      : "imported",
    created_at: new Date().toISOString(),
    repetitions,
    predictions: [],
  };
  if (command === "live") {
    assert(
      options.revision,
      "--revision must identify the evaluated source commit",
    );
  }
  await Deno.mkdir(out);
  const save = async () => {
    await Deno.writeTextFile(
      `${out}/run.tmp`,
      JSON.stringify(run, null, 2) + "\n",
    );
    await Deno.rename(`${out}/run.tmp`, `${out}/run.json`);
  };
  await save();
  if (command === "prepare") {
    const requests = await Promise.all(
      d.cases.map(async (c) => ({
        case_id: c.id,
        request_hash: await hash(requestFor(c)),
        language: c.language,
        current_time: c.current_time,
        timezone: c.timezone,
        ...requestFor(c),
      })),
    );
    await Deno.writeTextFile(
      `${out}/requests.jsonl`,
      requests.map((x) => JSON.stringify(x)).join("\n") + "\n",
    );
    console.log(
      `${out}/requests.jsonl + run.json (empty template, NOT model evidence)`,
    );
    return;
  }
  for (let trial = 0; trial < repetitions; trial++) {
    for (const c of d.cases) {
      run.predictions.push(
        command === "fixture"
          ? {
            case_id: c.id,
            trial,
            request_hash: await hash(requestFor(c)),
            status: "ok",
            response_text: JSON.stringify(referenceCalls(c)),
            latency_ms: null,
          }
          : await callGemini(c, trial, cfg, key),
      );
      await save();
      console.log(
        `${run.evidence_kind}: ${run.predictions.length}/${
          d.cases.length * repetitions
        } ${c.id}`,
      );
    }
  }
  const report = await evaluate(d, run);
  await Deno.writeTextFile(
    `${out}/report.json`,
    JSON.stringify(report, null, 2) + "\n",
  );
  await Deno.writeTextFile(`${out}/report.md`, markdown(report));
  console.log(
    `${out}/report.json — ${run.evidence_kind}; not a release approval`,
  );
}
if (import.meta.main) {
  try {
    await main();
  } catch (e) {
    console.error(e instanceof Error ? e.message : "Evaluation failed");
    Deno.exitCode = 1;
  }
}
