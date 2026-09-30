function assertEquals(actual: unknown, expected: unknown) {
  if (actual !== expected) {
    throw new Error(`Expected ${expected}, got ${actual}`);
  }
}
import { geminiModel } from "./model-config.ts";

Deno.test("release model defaults and explicit override", () => {
  assertEquals(geminiModel(undefined), "gemini-3.5-flash-lite");
  assertEquals(geminiModel("  "), "gemini-3.5-flash-lite");
  assertEquals(geminiModel(" gemini-2.5-flash "), "gemini-2.5-flash");
});
Deno.test("model config rejects path and query injection", () => {
  for (
    const invalid of [
      "https://example.com",
      "gemini-x?key=abc",
      "gemini-x/other",
      "gpt-5",
    ]
  ) {
    assertEquals(geminiModel(invalid), null);
  }
});
