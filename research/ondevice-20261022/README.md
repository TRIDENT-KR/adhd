# MORA on-device research — 2026-10-22

Decision: [Korean report](/Users/gimgihong/Desktop/TRIDENT/adhd/MORA_ONDEVICE_DECISION_20261022.md).

This directory contains research evidence, not an enabled product feature. All
inputs are synthetic. No output was sent to MORA, persisted as a task, or used to
schedule an alarm. No paid inference was performed.

## Reproduce the corrected comparison

Use the exact runtime/model versions and SHA256 values in
[artifacts.json](/Users/gimgihong/Desktop/TRIDENT/adhd/research/ondevice-20261022/artifacts.json).
The verified local copies are under `/tmp/mora-ondevice-20261022`; temporary
storage may be reclaimed. Download replacements only from the pinned artifact
repositories/releases and verify their hashes before executing them. Weights are
not included in this Git repository or the iOS application.

Run from the repository root. Run the models sequentially, especially on an 8GB
host. Choose a different `--name` to preserve the recorded results.

```sh
python3 research/ondevice-20261022/run_probe.py \
  --server /tmp/mora-ondevice-20261022/bin/llama-server \
  --model /tmp/mora-ondevice-20261022/models/qwen35-08b-q4_0.gguf \
  --name qwen35-08b-repeat \
  --cases research/ondevice-20261022/control-cases.json research/ondevice-20261022/adversarial-cases.json \
  --prompt-mode compact

python3 research/ondevice-20261022/run_probe.py \
  --server /tmp/mora-ondevice-20261022/bin/llama-server \
  --model /tmp/mora-ondevice-20261022/models/qwen3-17b-q4_k_m.gguf \
  --name qwen3-17b-repeat \
  --cases research/ondevice-20261022/control-cases.json research/ondevice-20261022/adversarial-cases.json \
  --prompt-mode compact

deno run --no-remote --allow-read research/ondevice-20261022/validate_outputs.ts \
  research/ondevice-20261022/results/qwen35-08b-q4_0-compact/outputs.jsonl \
  research/ondevice-20261022/results/qwen3-17b-q4_k_m-compact/outputs.jsonl

xcrun swift research/ondevice-20261022/check_apple_availability.swift
```

The Python runner uses the standard library, launches a temporary model server
on `127.0.0.1` with no tools or UI, and terminates its child process in `finally`.
`--offline` prevents model fetching by the inference server. Only the supplied
synthetic cases are submitted to the local server. No external analysis endpoint
is used. The Apple script checks availability only; it does not run generation,
enable Apple Intelligence, or request model assets.

## What is measured

- Corrected `compact` runs: 12 controls + 18 model-level adversarial cases each.
- Cases 19–20: integration requirements only, deliberately excluded from scoring.
- `outputs.jsonl`: literal output, parse result, stop reason, timing and prompt hash.
- `metadata.json`: model hash, launch parameters and schema used for that run.
- `validation-*.json`: results from the actual production TypeScript validator.
- `adjudication-*.json`: independent semantic grading and per-case explanations.

The controls contain four translated patterns, not twelve unrelated skills.
C11 repeats an in-prompt example. These are development probes, not a held-out
accuracy estimate. The fixture was frozen before the corrected runs; only
integration-case authorization wording was refined afterward, not model inputs.

The grammar ensures field shape, but time strings and dates still require the
production validator. Even that validator does not establish intended meaning.
Semantic grading distinguishes exact interpretation, nonmutating safe abstention,
and semantic failure. An inaccurate clarification may itself be a semantic
failure, but is not counted as an unintended write. No model output was executed.

All corrected outputs stopped normally; there were no token-budget-censored
cases. Greedy decoding with a fixed seed is a bounded diagnostic condition, not
the publishers' maximum-quality recommendation or a guarantee of cross-device
bitwise reproducibility. Mac timings may benefit from prompt caching and are not
iPhone latency, memory, energy or battery results.

## Superseded diagnostic runs

`qwen35-08b-q4_0-current` contains two initial checks using the production prompt.
`qwen35-08b-q4_0-compact-v1-incomplete-prompt` contains twelve early controls whose
prompt did not make the whole schema visible to the model. Adversarial review
caught this confound. Those twelve are retained for transparency and excluded
from the comparison. The corrected runner explicitly supplies the schema,
one-time recurrence rule and multilingual examples.

## Follow-up qualification

The selected architecture is a strict local fast path, an independently qualified
Apple path only when already available, and the existing consent-bound
Claude→Gemini path. The research does not enable any of these new paths.

Before activation: validate real uncoached KO/EN/JA coverage, negation/correction/
exception handling, typed date/target compilation, account switching/cancellation,
offline/no-consent behavior, and Release builds on the weakest supported iPhones.
See the decision report for gates and test-flow requirements. A successful
capability check on this Mac is not evidence of an iPhone model's quality.
