import type { evaluate } from "./core.ts";
const percent = (n: number | null) =>
  n === null ? "N/A" : `${(n * 100).toFixed(1)}%`;
export function markdown(r: Awaited<ReturnType<typeof evaluate>>): string {
  const m = r.overall;
  return `# MORA Eval — ${r.run.system}

Evidence: **${r.run.evidence_kind}**. Dataset: ${r.dataset.name} ${r.dataset.version}, ${r.dataset.purpose}, labels ${r.dataset.review.status}.

${r.interpretation.map((x) => `- ${x}`).join("\n")}

| Metric | Result | Denominator |
|---|---:|---:|
| Full contract match (including nonmutating route only) | ${
    percent(m.contract_match.rate)
  } | ${m.contract_match.n} attempts |
| Command exact (all calls and arguments) | ${
    percent(m.command_exact.rate)
  } | ${m.command_exact.n} command attempts |
| Route sequence exact | ${
    percent(m.routing_accuracy.rate)
  } | ${m.routing_accuracy.n} attempts |
| Route sequence macro F1 | ${
    m.route_sequence_macro_f1?.toFixed(3) ?? "N/A"
  } | observed gold sequences |
| Schema valid | ${
    percent(m.schema_valid.rate)
  } | ${m.schema_valid.n} attempts |
| Unexpected mutation proposal | ${m.unexpected_mutation.count} | ${m.unexpected_mutation.n} nonmutating attempts |
| Destructive mismatch proxy | ${m.destructive_mismatch.count} | ${m.destructive_mismatch.n} attempts |
| Unnecessary clarification | ${
    percent(m.unnecessary_clarification.rate)
  } | ${m.unnecessary_clarification.n} command attempts |
| All repetitions correct | ${
    percent(m.all_repetitions_pass.rate)
  } | ${m.all_repetitions_pass.n} cases |
| Missing outputs (count as failure) | ${m.missing.count} | ${m.missing.n} attempts |

Scenario family macro match: ${
    percent(m.family_macro_match.rate)
  } across ${m.family_macro_match.n} families. Exploratory family bootstrap 95% interval: ${
    m.family_macro_match.bootstrap_95?.map(percent).join(" – ") ?? "N/A"
  }.

| Language | Full contract | Command exact | Destructive mismatch |
|---|---:|---:|---:|
${
    Object.entries(r.by_language).map(([k, v]) =>
      `| ${k} | ${percent(v.contract_match.rate)} | ${
        percent(v.command_exact.rate)
      } | ${v.destructive_mismatch.count} |`
    ).join("\n")
  }

Latency p50/p95: ${r.performance.p50_ms ?? "unknown"}/${
    r.performance.p95_ms ?? "unknown"
  } ms, ${r.performance.measured}/${r.performance.expected} measured attempts. Cost: ${
    r.performance.total_cost_usd ?? "unknown"
  } USD (${r.performance.priced} priced attempts). This is model/pipeline measurement, not iPhone or end-to-end app latency.

## Failed cases

${
    r.rows.filter((g) => !g.contract_match).map((g) =>
      `- ${g.case_id} trial ${g.trial}: ${g.issues.join(", ")}`
    ).join("\n") ||
    "None in this run. Fixture/reference runs do not establish model quality."
  }

Hashes and per-field/per-function metrics are in report.json. Free-text clarification reasons and off-topic replies require separate human assessment.
`;
}
