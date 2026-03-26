import fs from 'fs';
import path from 'path';
import { SYSTEM_PROMPT } from './prompt.mjs'; // Task 1: Single Source of Truth

/**
 * Node.js LLM Prompt Test Runner (Refactored)
 *
 * Usage:
 *   GEMINI_API_KEY=<your_key> node supabase/functions/analyze-task/test/run_test.mjs
 */

// ─── 데이터 로드 ───────────────────────────────────────────────────────────────
const sampleInputsPath = path.resolve(process.cwd(), 'supabase/functions/analyze-task/test/sample_inputs.json');
const testData = JSON.parse(fs.readFileSync(sampleInputsPath, 'utf8'));

// ─── Gemini API 호출 ───────────────────────────────────────────────────────────
async function callGemini(text) {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new Error("GEMINI_API_KEY environment variable is missing.");

  const start = Date.now();
  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
        contents: [{ role: "user", parts: [{ text }] }],
        generationConfig: {
          response_mime_type: "application/json",
          temperature: 0.1,
        },
      }),
    }
  );

  const latencyMs = Date.now() - start;
  const data = await response.json();

  if (!response.ok) {
    throw new Error(`Gemini API Error: ${data.error?.message || response.status}`);
  }

  const rawText = data.candidates[0].content.parts[0].text;

  // Task 2: 운영 환경(index.ts)과 동일한 마크다운 클리닝 로직 적용
  const cleanedText = rawText.replace(/```json/g, "").replace(/```/g, "").trim();

  let parsed = JSON.parse(cleanedText);
  if (!Array.isArray(parsed)) parsed = [parsed];

  return { result: parsed, latencyMs };
}

// ─── 검증 로직 ─────────────────────────────────────────────────────────────────
/**
 * Task 3: Deep Validation Check
 *
 * 3단계 계층적 검증:
 *   1. Hard Rules   — 스키마 정합성 (action, task, time, category 형식)
 *   2. Count Check  — expected_count와 추출 결과 개수 일치 여부
 *   3. Logic Match  — expected 기대값과의 논리적 일치 여부 (action, category, time 조건)
 */
function validateResult(testCase, items) {
  const issues = [];
  const VALID_ACTIONS = ["add", "delete", "update"];
  const VALID_CATEGORIES = ["Routine", "Appointment"];

  // ── 1단계: 기본 스키마 정합성 (Hard Rules) ──────────────────────────────────
  for (const [i, item] of items.entries()) {
    if (!VALID_ACTIONS.includes(item.action)) {
      issues.push(`[item ${i}] Invalid action: "${item.action}" — must be one of ${VALID_ACTIONS.join(", ")}`);
    }
    if (!item.task || !String(item.task).trim()) {
      issues.push(`[item ${i}] Task field is empty or missing`);
    }
    if (item.time !== null && !/^\d{2}:\d{2} (AM|PM)$/.test(item.time)) {
      issues.push(`[item ${i}] Invalid time format: "${item.time}" — expected "hh:mm AM/PM" or null`);
    }
    if (!VALID_CATEGORIES.includes(item.category)) {
      issues.push(`[item ${i}] Invalid category: "${item.category}" — must be "Routine" or "Appointment"`);
    }
  }

  // 1단계 실패 시 이후 검증 의미 없음
  if (issues.length > 0) return issues;

  // ── 2단계: 요청 개수 일치성 (Count Validation) ──────────────────────────────
  if (testCase.expected_count !== undefined && items.length !== testCase.expected_count) {
    issues.push(`Count mismatch: expected ${testCase.expected_count} item(s), but got ${items.length}`);
    return issues; // 개수 불일치 시 이후 논리 검증 불가
  }

  // ── 3단계: 논리적 기대값 검증 (Logic Match) ─────────────────────────────────
  if (!testCase.expected) return issues;

  // expected가 단일 객체인지 배열인지 판별하여 통일된 배열로 처리
  const expectedList = Array.isArray(testCase.expected)
    ? testCase.expected
    : [testCase.expected];

  for (const [i, exp] of expectedList.entries()) {
    const item = items[i];
    if (!item) {
      issues.push(`[item ${i}] No result found to match expected[${i}]`);
      continue;
    }

    // action 일치 검증
    if (exp.action !== undefined && item.action !== exp.action) {
      issues.push(`[item ${i}] Expected action "${exp.action}" but got "${item.action}"`);
    }

    // category 일치 검증
    if (exp.category !== undefined && item.category !== exp.category) {
      issues.push(`[item ${i}] Expected category "${exp.category}" but got "${item.category}"`);
    }

    // time_not_null: true → time이 null이 아니어야 함
    if (exp.time_not_null === true && item.time === null) {
      issues.push(`[item ${i}] Expected time to be non-null, but got null`);
    }

    // time_not_null: false → time이 null이어야 함
    if (exp.time_not_null === false && item.time !== null) {
      issues.push(`[item ${i}] Expected time to be null, but got "${item.time}"`);
    }

    // time_contains: 특정 시간 문자열 포함 여부
    if (exp.time_contains !== undefined) {
      if (item.time === null || !item.time.includes(exp.time_contains)) {
        issues.push(`[item ${i}] Expected time to contain "${exp.time_contains}", but got "${item.time}"`);
      }
    }
  }

  return issues;
}

// ─── 메인 실행 ─────────────────────────────────────────────────────────────────
async function main() {
  const cases = testData.test_cases;
  console.log(`\n🧪 Starting LLM Tests (${cases.length} cases)\n`);

  let passed = 0;
  for (const tc of cases) {
    process.stdout.write(`  ${tc.id} (${tc.description}): `);
    try {
      const { result, latencyMs } = await callGemini(tc.input);
      const issues = validateResult(tc, result);

      if (issues.length === 0) {
        console.log(`\x1b[32mPASS\x1b[0m (${latencyMs}ms)`);
        passed++;
      } else {
        console.log(`\x1b[31mFAIL\x1b[0m (${latencyMs}ms)`);
        issues.forEach(msg => console.log(`    ⚠️  ${msg}`));
        console.log(`    Output: ${JSON.stringify(result)}`);
      }
    } catch (e) {
      console.log(`\x1b[33mERROR\x1b[0m: ${e.message}`);
    }
    // Rate limit delay
    await new Promise(r => setTimeout(r, 500));
  }

  console.log(`\nSummary: ${passed}/${cases.length} passed\n`);
}

main();
