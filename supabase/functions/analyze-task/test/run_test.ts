/**
 * LLM Prompt 테스트 스크립트
 * 
 * 사용법:
 *   GEMINI_API_KEY=<your_key> deno run --allow-net --allow-read --allow-env test/run_test.ts
 * 
 * 옵션:
 *   --single "텍스트"  : 단일 텍스트 직접 테스트
 *   --id TC001        : 특정 테스트 케이스만 실행
 *   --all             : 모든 테스트 케이스 실행 (기본값)
 */

import sampleInputs from "./sample_inputs.json" assert { type: "json" };

// ─────────────────────────────────────────────
// 현재 시스템 프롬프트 (index.ts 와 동기화)
// ─────────────────────────────────────────────
const SYSTEM_PROMPT = `너는 ADHD 사용자의 횡설수설하는 음성을 분석하여 의도(Intent)를 추출하는 비서야. 사용자는 말을 번복하거나 한 번에 여러 지시를 내릴 수 있어. 결과를 반드시 JSON 배열(Array) 형식으로만 반환해. 
    
각 JSON 객체는 다음 4개의 키를 가져야 해:
1. "action": "add" (추가), "delete" (삭제), "update" (수정) 중 택 1
2. "task": 할 일의 이름. (단순한 명사가 아니라 "Morning Meditation", "Water Plants", "Doctor Appointment", "Do the laundry" 처럼 자연스럽고 직관적인 일상 루틴/행동 표현으로 다듬어서 작성해. 언어는 사용자가 말한 언어를 따르되 행동이 명확해야 해.)
3. "time": 시간 (파악 불가면 null, 시간 형식은 "hh:mm AM/PM")
4. "category": 매일 하는 일상적인 일이면 "Routine", 특정 시간의 약속이나 일회성 일정이면 "Appointment"

예시 1) 
입력: "아 오늘 3시 미팅 취소됨. 대신 4시에 헬스 갈래" 
출력: [
  {"action": "delete", "task": "Meeting", "time": "03:00 PM", "category": "Appointment"}, 
  {"action": "add", "task": "Hit the gym", "time": "04:00 PM", "category": "Appointment"}
]`;

// ─────────────────────────────────────────────
// 타입 정의
// ─────────────────────────────────────────────
interface TaskItem {
  action: string;
  task: string;
  time: string | null;
  category: string;
}

interface TestCase {
  id: string;
  description: string;
  input: string;
  expected?: Record<string, unknown>;
  expected_count?: number;
}

interface TestResult {
  id: string;
  description: string;
  input: string;
  status: "PASS" | "FAIL" | "ERROR";
  output: TaskItem[] | null;
  issues: string[];
  latencyMs: number;
}

// ─────────────────────────────────────────────
// Gemini API 호출
// ─────────────────────────────────────────────
async function callGemini(text: string): Promise<{ result: TaskItem[]; latencyMs: number }> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("GEMINI_API_KEY 환경변수가 없습니다.");

  const start = performance.now();

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`,
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

  const latencyMs = Math.round(performance.now() - start);
  const data = await response.json();

  if (!response.ok) {
    throw new Error(`Gemini API Error: ${data.error?.message || response.status}`);
  }

  const rawText = data.candidates[0].content.parts[0].text;
  const cleaned = rawText.replace(/```json/g, "").replace(/```/g, "").trim();
  let parsed = JSON.parse(cleaned);

  if (!Array.isArray(parsed)) parsed = [parsed];

  return { result: parsed, latencyMs };
}

// ─────────────────────────────────────────────
// 결과 검증
// ─────────────────────────────────────────────
function validateResult(testCase: TestCase, items: TaskItem[]): string[] {
  const issues: string[] = [];
  const VALID_ACTIONS = ["add", "delete", "update"];
  const VALID_CATEGORIES = ["Routine", "Appointment"];

  // 기본 스키마 검증
  for (const [i, item] of items.entries()) {
    if (!VALID_ACTIONS.includes(item.action))
      issues.push(`[${i}] action 값 이상: "${item.action}"`);
    if (!item.task || item.task.trim() === "")
      issues.push(`[${i}] task 비어있음`);
    if (item.time !== null && !/^\d{2}:\d{2} (AM|PM)$/.test(item.time))
      issues.push(`[${i}] time 형식 이상: "${item.time}"`);
    if (!VALID_CATEGORIES.includes(item.category))
      issues.push(`[${i}] category 값 이상: "${item.category}"`);
  }

  // expected_count 검증
  if (testCase.expected_count !== undefined && items.length !== testCase.expected_count) {
    issues.push(`결과 개수 불일치: 기대 ${testCase.expected_count}개, 실제 ${items.length}개`);
  }

  // 단일 expected 검증
  if (testCase.expected && !testCase.expected_count) {
    const exp = testCase.expected as Record<string, unknown>;
    const item = items[0];
    if (exp.action && item.action !== exp.action)
      issues.push(`action 불일치: 기대 "${exp.action}", 실제 "${item.action}"`);
    if (exp.category && item.category !== exp.category)
      issues.push(`category 불일치: 기대 "${exp.category}", 실제 "${item.category}"`);
    if (exp.time_not_null === true && item.time === null)
      issues.push(`time이 null이지만 값이 있어야 함`);
    if (exp.time_contains && item.time !== exp.time_contains)
      issues.push(`time 불일치: 기대 "${exp.time_contains}", 실제 "${item.time}"`);
  }

  return issues;
}

// ─────────────────────────────────────────────
// 결과 출력 (컬러 터미널)
// ─────────────────────────────────────────────
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const BLUE = "\x1b[34m";
const CYAN = "\x1b[36m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

function printResult(result: TestResult) {
  const statusColor = result.status === "PASS" ? GREEN : result.status === "FAIL" ? RED : YELLOW;
  console.log(`\n${BOLD}${statusColor}[${result.status}]${RESET} ${CYAN}${result.id}${RESET} - ${result.description}`);
  console.log(`  ${BLUE}입력:${RESET} ${result.input}`);
  console.log(`  ${BLUE}응답 시간:${RESET} ${result.latencyMs}ms`);

  if (result.output) {
    console.log(`  ${BLUE}출력:${RESET}`);
    for (const item of result.output) {
      console.log(`    • [${item.action}] ${item.task} | ${item.time ?? "시간없음"} | ${item.category}`);
    }
  }

  if (result.issues.length > 0) {
    console.log(`  ${RED}이슈:${RESET}`);
    for (const issue of result.issues) {
      console.log(`    ⚠️  ${issue}`);
    }
  }
}

function printSummary(results: TestResult[]) {
  const total = results.length;
  const passed = results.filter((r) => r.status === "PASS").length;
  const failed = results.filter((r) => r.status === "FAIL").length;
  const errors = results.filter((r) => r.status === "ERROR").length;
  const avgLatency = Math.round(results.reduce((sum, r) => sum + r.latencyMs, 0) / total);

  console.log(`\n${"═".repeat(60)}`);
  console.log(`${BOLD}📊 테스트 요약${RESET}`);
  console.log(`${"─".repeat(60)}`);
  console.log(`  전체: ${total}  ${GREEN}✅ 통과: ${passed}${RESET}  ${RED}❌ 실패: ${failed}${RESET}  ${YELLOW}💥 오류: ${errors}${RESET}`);
  console.log(`  평균 응답 시간: ${avgLatency}ms`);
  console.log(`${"═".repeat(60)}\n`);
}

// ─────────────────────────────────────────────
// 메인 실행
// ─────────────────────────────────────────────
async function runSingleText(text: string) {
  console.log(`\n${BOLD}🔬 단일 테스트 모드${RESET}`);
  console.log(`입력: "${text}"\n`);

  try {
    const { result, latencyMs } = await callGemini(text);
    console.log(`응답 시간: ${latencyMs}ms\n출력:`);
    console.log(JSON.stringify(result, null, 2));
  } catch (e) {
    console.error(`오류: ${(e as Error).message}`);
  }
}

async function runTestCase(tc: TestCase): Promise<TestResult> {
  try {
    const { result, latencyMs } = await callGemini(tc.input);
    const issues = validateResult(tc, result);
    return {
      id: tc.id,
      description: tc.description,
      input: tc.input,
      status: issues.length === 0 ? "PASS" : "FAIL",
      output: result,
      issues,
      latencyMs,
    };
  } catch (e) {
    return {
      id: tc.id,
      description: tc.description,
      input: tc.input,
      status: "ERROR",
      output: null,
      issues: [(e as Error).message],
      latencyMs: 0,
    };
  }
}

async function main() {
  const args = Deno.args;
  const singleIndex = args.indexOf("--single");
  const idIndex = args.indexOf("--id");

  if (singleIndex !== -1) {
    const text = args[singleIndex + 1];
    if (!text) { console.error("--single 다음에 텍스트를 입력하세요."); Deno.exit(1); }
    await runSingleText(text);
    return;
  }

  let cases: TestCase[] = (sampleInputs as { test_cases: TestCase[] }).test_cases;

  if (idIndex !== -1) {
    const id = args[idIndex + 1];
    cases = cases.filter((tc) => tc.id === id);
    if (cases.length === 0) { console.error(`TC ID "${id}"를 찾을 수 없습니다.`); Deno.exit(1); }
  }

  console.log(`\n${BOLD}🧪 LLM 프롬프트 테스트 시작 (${cases.length}개 케이스)${RESET}`);
  console.log(`${"─".repeat(60)}`);

  const results: TestResult[] = [];
  for (const tc of cases) {
    process.stdout?.write?.(`  ${tc.id} 실행 중...`);
    const result = await runTestCase(tc);
    results.push(result);
    printResult(result);
    // API Rate limit 방지
    await new Promise((r) => setTimeout(r, 500));
  }

  printSummary(results);

  // JSON 결과 저장
  const outputPath = "./test/results/latest_run.json";
  try {
    await Deno.mkdir("./test/results", { recursive: true });
    await Deno.writeTextFile(outputPath, JSON.stringify({ 
      timestamp: new Date().toISOString(),
      results 
    }, null, 2));
    console.log(`📁 결과 저장됨: ${outputPath}\n`);
  } catch {
    // 저장 실패 무시
  }
}

main();
