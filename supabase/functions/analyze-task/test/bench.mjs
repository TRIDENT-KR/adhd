#!/usr/bin/env node
/**
 * 다국어 함수 호출 정확도 · 레이턴시 벤치마크
 *
 * 시스템 프롬프트는 index.ts 에서 직접 추출하므로 항상 배포본과 동기화된다.
 *
 * 사용법:
 *   GEMINI_API_KEY=... node test/bench.mjs --models gemini:gemini-3.5-flash-lite
 *   OPENAI_API_KEY=... node test/bench.mjs --models openai:gpt-5-nano,openai:gpt-4o-mini
 *   node test/bench.mjs --models gemini:gemini-3.5-flash-lite --lang ko
 *
 * 옵션:
 *   --models  provider:model 쉼표 구분 (provider: gemini | openai | kimi)
 *   --lang    ko | ja | en (기본: 전체)
 *   --repeat  케이스당 반복 횟수 (기본 1)
 *   --json    결과를 JSON 파일로 저장
 */

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXED_TIME = "2026-08-19 14:00";

// ─────────────────────────────────────────────
// 인자 파싱
// ─────────────────────────────────────────────
function parseArgs() {
  const a = process.argv.slice(2);
  const get = (flag, def) => {
    const i = a.indexOf(flag);
    return i >= 0 && a[i + 1] ? a[i + 1] : def;
  };
  return {
    models: get("--models", "gemini:gemini-3.5-flash-lite").split(","),
    lang: get("--lang", null),
    repeat: parseInt(get("--repeat", "1"), 10),
    json: a.includes("--json") ? get("--json", "bench-results.json") : null,
  };
}

// ─────────────────────────────────────────────
// index.ts 에서 시스템 프롬프트 추출
// ─────────────────────────────────────────────
function extractPrompt(localTimeStr, userLanguage) {
  const src = readFileSync(join(__dirname, "..", "index.ts"), "utf-8");
  const start = src.indexOf("You are an AI Command Router");
  if (start < 0) throw new Error("index.ts 에서 시스템 프롬프트를 찾지 못했습니다.");
  const end = src.indexOf("`;", start);
  let p = src.slice(start, end);
  // 템플릿 변수 치환 — Edge Function 런타임과 동일하게
  p = p.replaceAll("${localTimeStr}", localTimeStr);
  p = p.replaceAll("${userLanguage}", userLanguage);
  if (p.includes("${")) {
    const leftover = p.match(/\$\{[^}]+\}/g);
    throw new Error(`치환되지 않은 템플릿 변수: ${leftover.join(", ")}`);
  }
  return p;
}

// ─────────────────────────────────────────────
// Provider 호출
// ─────────────────────────────────────────────
async function callGemini(model, systemPrompt, userText) {
  const key = process.env.GEMINI_API_KEY;
  if (!key) throw new Error("GEMINI_API_KEY 미설정");
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: systemPrompt }] },
        contents: [{ role: "user", parts: [{ text: userText }] }],
        generationConfig: {
          response_mime_type: "application/json",
          temperature: 0.1,
        },
      }),
    },
  );
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${data.error?.message ?? JSON.stringify(data).slice(0, 200)}`);
  }
  const cand = data.candidates?.[0];
  if (!cand) throw new Error(`no candidates: ${JSON.stringify(data).slice(0, 200)}`);
  const text = cand.content?.parts?.map((p) => p.text).join("") ?? "";
  if (!text) throw new Error(`empty text (finishReason=${cand.finishReason})`);
  return text;
}

async function callOpenAICompatible(baseUrl, apiKeyEnv, model, systemPrompt, userText) {
  const key = process.env[apiKeyEnv];
  if (!key) throw new Error(`${apiKeyEnv} 미설정`);
  const body = {
    model,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userText },
    ],
    response_format: { type: "json_object" },
  };
  // 추론 모델(gpt-5 계열)은 temperature 고정값만 허용 → 생략
  if (!/^(gpt-5|o[134])/.test(model)) body.temperature = 0.1;

  const res = await fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${key}`,
    },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${data.error?.message ?? JSON.stringify(data).slice(0, 200)}`);
  }
  const content = data.choices?.[0]?.message?.content;
  if (!content) throw new Error(`no content: ${JSON.stringify(data).slice(0, 200)}`);
  return content;
}

function dispatch(spec) {
  const [provider, ...rest] = spec.split(":");
  const model = rest.join(":");
  if (!model) throw new Error(`모델 지정 형식 오류: "${spec}" (provider:model 이어야 함)`);
  switch (provider) {
    case "gemini":
      return (sp, ut) => callGemini(model, sp, ut);
    case "openai":
      return (sp, ut) => callOpenAICompatible("https://api.openai.com/v1", "OPENAI_API_KEY", model, sp, ut);
    case "kimi":
      return (sp, ut) =>
        callOpenAICompatible(
          process.env.MOONSHOT_BASE_URL ?? "https://api.moonshot.ai/v1",
          "MOONSHOT_API_KEY",
          model,
          sp,
          ut,
        );
    default:
      throw new Error(`알 수 없는 provider: ${provider}`);
  }
}

// ─────────────────────────────────────────────
// 응답 정규화 — Edge Function 의 방어 로직과 동일
// ─────────────────────────────────────────────
function normalize(raw) {
  const cleaned = raw.replace(/```json/g, "").replace(/```/g, "").trim();
  let parsed = JSON.parse(cleaned);
  if (!Array.isArray(parsed) && parsed && typeof parsed === "object" && !parsed.function_name) {
    const inner = Object.values(parsed).find((v) => Array.isArray(v));
    if (inner) parsed = inner;
  }
  if (!Array.isArray(parsed)) parsed = [parsed];
  return parsed;
}

// ─────────────────────────────────────────────
// 채점
// ─────────────────────────────────────────────
function detectLang(s) {
  if (/[가-힣]/.test(s)) return "ko";
  if (/[ぁ-んァ-ヶ]/.test(s)) return "ja";
  if (/[a-zA-Z]/.test(s)) return "en";
  return "unknown";
}

function grade(calls, expect) {
  const issues = [];
  const first = calls[0] ?? {};
  const params = first.parameters ?? {};

  if (expect.count !== undefined && calls.length !== expect.count) {
    issues.push(`호출 수 ${calls.length} (기대 ${expect.count})`);
  }
  if (expect.function_name && first.function_name !== expect.function_name) {
    issues.push(`함수 ${first.function_name} (기대 ${expect.function_name})`);
  }
  if (expect.function_names) {
    const got = calls.map((c) => c.function_name);
    for (const fn of expect.function_names) {
      if (!got.includes(fn)) issues.push(`함수 ${fn} 누락`);
    }
  }
  if (expect.category && params.category !== expect.category) {
    issues.push(`카테고리 ${params.category} (기대 ${expect.category})`);
  }
  if (expect.time && params.time !== expect.time) {
    issues.push(`시각 ${params.time} (기대 ${expect.time})`);
  }
  if (expect.time_is_null && params.time !== null && params.time !== undefined) {
    issues.push(`시각을 추측함: ${params.time} (null 이어야 함)`);
  }
  if (expect.date && params.date !== expect.date) {
    issues.push(`날짜 ${params.date} (기대 ${expect.date})`);
  }
  if (expect.new_date && params.new_date !== expect.new_date) {
    issues.push(`변경일 ${params.new_date} (기대 ${expect.new_date})`);
  }
  if (expect.reply_language) {
    const got = detectLang(params.message ?? "");
    if (got !== expect.reply_language) {
      issues.push(`응답 언어 ${got} (기대 ${expect.reply_language})`);
    }
  }
  return issues;
}

// ─────────────────────────────────────────────
// 실행
// ─────────────────────────────────────────────
async function main() {
  const args = parseArgs();
  const suite = JSON.parse(
    readFileSync(join(__dirname, "sample_inputs_multilingual.json"), "utf-8"),
  );
  let cases = suite.test_cases;
  if (args.lang) cases = cases.filter((c) => c.language === args.lang);

  console.log(`기준 시각: ${FIXED_TIME} · 케이스 ${cases.length}개 · 반복 ${args.repeat}회`);
  console.log(`모델: ${args.models.join(", ")}\n`);

  const allResults = {};

  for (const spec of args.models) {
    const call = dispatch(spec);
    const results = [];
    process.stdout.write(`▶ ${spec}\n`);

    for (const tc of cases) {
      for (let r = 0; r < args.repeat; r++) {
        const systemPrompt = extractPrompt(FIXED_TIME, tc.language);
        const t0 = performance.now();
        let status, issues = [], output = null, error = null;
        try {
          const raw = await call(systemPrompt, tc.input);
          output = normalize(raw);
          issues = grade(output, tc.expect);
          status = issues.length === 0 ? "PASS" : "FAIL";
        } catch (e) {
          status = "ERROR";
          error = e.message;
        }
        const latency = Math.round(performance.now() - t0);
        results.push({ id: tc.id, language: tc.language, status, issues, error, latency, output });

        const mark = status === "PASS" ? "✅" : status === "FAIL" ? "❌" : "💥";
        const detail = status === "ERROR" ? error : issues.join(" / ");
        console.log(`  ${mark} ${tc.id} [${tc.language}] ${String(latency).padStart(5)}ms  ${detail}`);
      }
    }
    allResults[spec] = results;
    console.log("");
  }

  // ── 요약 ──
  console.log("─".repeat(72));
  console.log("요약");
  console.log("─".repeat(72));
  const langs = [...new Set(cases.map((c) => c.language))];
  const header = ["모델", ...langs.map((l) => l.toUpperCase()), "전체", "중앙 지연"];
  const rows = [header];

  for (const [spec, results] of Object.entries(allResults)) {
    const row = [spec];
    for (const l of langs) {
      const sub = results.filter((r) => r.language === l);
      const pass = sub.filter((r) => r.status === "PASS").length;
      row.push(sub.length ? `${pass}/${sub.length}` : "-");
    }
    const pass = results.filter((r) => r.status === "PASS").length;
    row.push(`${pass}/${results.length} (${Math.round((pass / results.length) * 100)}%)`);
    const oks = results.filter((r) => r.status !== "ERROR").map((r) => r.latency).sort((a, b) => a - b);
    row.push(oks.length ? `${oks[Math.floor(oks.length / 2)]}ms` : "-");
    rows.push(row);
  }

  const widths = header.map((_, i) => Math.max(...rows.map((r) => [...String(r[i])].length)));
  for (const [i, row] of rows.entries()) {
    console.log(row.map((c, j) => String(c).padEnd(widths[j])).join("  "));
    if (i === 0) console.log(widths.map((w) => "─".repeat(w)).join("  "));
  }

  if (args.json) {
    writeFileSync(args.json, JSON.stringify(allResults, null, 2));
    console.log(`\n상세 결과 저장: ${args.json}`);
  }
}

main().catch((e) => {
  console.error("실패:", e.message);
  process.exit(1);
});
