import fs from 'fs';
import path from 'path';
import { SYSTEM_PROMPT } from './prompt.mjs';

/**
 * Node.js LLM Prompt Test Runner (Function Calling Architecture)
 *
 * Usage:
 *   GEMINI_API_KEY=<your_key> node supabase/functions/analyze-task/test/run_test.mjs
 */

const sampleInputsPath = path.resolve(process.cwd(), 'supabase/functions/analyze-task/test/sample_inputs.json');
const testData = JSON.parse(fs.readFileSync(sampleInputsPath, 'utf8'));

async function callGemini(text) {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new Error("GEMINI_API_KEY environment variable is missing.");

  const start = Date.now();
  
  const now = new Date();
  const todayStr = now.toISOString().split('T')[0];
  const tomorrow = new Date(now);
  tomorrow.setDate(tomorrow.getDate() + 1);
  const tomorrowStr = tomorrow.toISOString().split('T')[0];

  const finalPrompt = SYSTEM_PROMPT
    .replaceAll("{{TODAY}}", todayStr)
    .replaceAll("{{TOMORROW}}", tomorrowStr);

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: finalPrompt }] },
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
  const cleanedText = rawText.replace(/```json/g, "").replace(/```/g, "").trim();

  let parsed = [];
  try {
     parsed = JSON.parse(cleanedText);
     if (!Array.isArray(parsed)) parsed = [parsed];
  } catch(e) {
     throw new Error("Failed to parse LLM response: " + cleanedText);
  }

  return { result: parsed, latencyMs };
}

function validateResult(testCase, items) {
  const issues = [];
  const VALID_FUNCTIONS = [
    "add_single_task", "update_task", "delete_specific_task", 
    "clear_all_tasks", "postpone_all_tasks", "mark_task_complete", "request_clarification"
  ];

  for (const [i, item] of items.entries()) {
    if (!VALID_FUNCTIONS.includes(item.function_name)) {
      issues.push(`[item ${i}] Invalid function_name: "${item.function_name}"`);
    }
    if (!item.parameters) {
      issues.push(`[item ${i}] Missing "parameters" object`);
    }
  }

  if (issues.length > 0) return issues;

  if (testCase.expected_count !== undefined && items.length !== testCase.expected_count) {
    issues.push(`Count mismatch: expected ${testCase.expected_count} item(s), but got ${items.length}`);
    return issues;
  }

  if (!testCase.expected) return issues;

  const expectedList = Array.isArray(testCase.expected) ? testCase.expected : [testCase.expected];

  for (const [i, exp] of expectedList.entries()) {
    const item = items[i];
    if (!item) {
      issues.push(`[item ${i}] No result found to match expected[${i}]`);
      continue;
    }

    if (exp.function_name && item.function_name !== exp.function_name) {
      issues.push(`[item ${i}] Expected function "${exp.function_name}" but got "${item.function_name}"`);
    }

    if (exp.parameters && item.parameters) {
      if (exp.parameters.category && item.parameters.category !== exp.parameters.category) {
         issues.push(`[item ${i}] Expected category "${exp.parameters.category}" got "${item.parameters.category}"`);
      }
      
      if (exp.parameters.time_not_null === true && item.parameters.time === null) {
         issues.push(`[item ${i}] Expected time to be non-null`);
      }
      
      if (exp.parameters.time_not_null === false && item.parameters.time !== null) {
         issues.push(`[item ${i}] Expected time to be null, got "${item.parameters.time}"`);
      }
      
      if (exp.parameters.time_contains) {
         if (!item.parameters.time || !item.parameters.time.includes(exp.parameters.time_contains)) {
            issues.push(`[item ${i}] Expected time to contain "${exp.parameters.time_contains}", got "${item.parameters.time}"`);
         }
      }
    }
  }

  return issues;
}

async function main() {
  const cases = testData.test_cases;
  console.log(`\n🧪 Starting LLM Tests: Function Calling (${cases.length} cases)\n`);

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
    await new Promise(r => setTimeout(r, 600)); // Rate limit
  }

  console.log(`\nSummary: ${passed}/${cases.length} passed\n`);
}

main();
