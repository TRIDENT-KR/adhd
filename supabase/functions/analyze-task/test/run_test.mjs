import fs from 'fs';
import path from 'path';

/**
 * Node.js LLM Prompt Test Runner
 * 
 * Usage:
 *   GEMINI_API_KEY=<your_key> node run_test.mjs
 */

const SYSTEM_PROMPT = `You are an AI assistant specialized in analyzing rambling, ADHD-style voice transcripts to extract structured tasks. 
Users may change their minds mid-sentence, repeat themselves, or provide multiple instructions at once. 

Your task is to extract a list of actions in JSON array format.
Each object must have these 4 keys:
1. "action": One of ["add", "delete", "update"].
2. "task": A concise, natural, and action-oriented name for the task (e.g., "Morning Meditation", "Water Plants", "Doctor Appointment"). Use the same language as the user.
3. "time": Time in "hh:mm AM/PM" format. Use null if not specified.
4. "category": Either "Routine" (daily/recurring habits) or "Appointment" (one-time events/meetings).

Example:
Input: "Ah, today's 3 PM meeting got canceled. I'll hit the gym at 4 PM instead."
Output: [
  {"action": "delete", "task": "Meeting", "time": "03:00 PM", "category": "Appointment"},
  {"action": "add", "task": "Hit the gym", "time": "04:00 PM", "category": "Appointment"}
]`;

// Load sample inputs
const sampleInputsPath = path.resolve(process.cwd(), 'supabase/functions/analyze-task/test/sample_inputs.json');
const testData = JSON.parse(fs.readFileSync(sampleInputsPath, 'utf8'));

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
  let parsed = JSON.parse(rawText);
  if (!Array.isArray(parsed)) parsed = [parsed];

  return { result: parsed, latencyMs };
}

function validateResult(testCase, items) {
  const issues = [];
  const VALID_ACTIONS = ["add", "delete", "update"];
  const VALID_CATEGORIES = ["Routine", "Appointment"];

  for (const [i, item] of items.entries()) {
    if (!VALID_ACTIONS.includes(item.action)) issues.push(`[${i}] Invalid action: "${item.action}"`);
    if (!item.task) issues.push(`[${i}] Task is empty`);
    if (item.time !== null && !/^\d{2}:\d{2} (AM|PM)$/.test(item.time)) issues.push(`[${i}] Invalid time format: "${item.time}"`);
    if (!VALID_CATEGORIES.includes(item.category)) issues.push(`[${i}] Invalid category: "${item.category}"`);
  }

  if (testCase.expected_count !== undefined && items.length !== testCase.expected_count) {
    issues.push(`Count mismatch: expected ${testCase.expected_count}, got ${items.length}`);
  }

  return issues;
}

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
