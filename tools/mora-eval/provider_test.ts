import { assert, requestFor, validateDataset } from "./core.ts";
import { callGemini, geminiPayload } from "./provider.ts";
const d = validateDataset(
  JSON.parse(
    await Deno.readTextFile(new URL("data/mora-v1.json", import.meta.url)),
  ),
);
const c = d.cases[0];
const config = {
  model: "gemini-test",
  max_output_tokens: 2048,
  timeout_ms: 50,
};
Deno.test("provider sends production prompt, fixed input and cap without gold or URL credentials", async () => {
  let n = 0;
  const fake: typeof fetch = (url, init) => {
    n++;
    assert(
      String(url).endsWith("gemini-test:generateContent") &&
        !String(url).includes("secret"),
      "URL leaked key",
    );
    const payload = JSON.parse(String(init!.body));
    assert(
      payload.system_instruction.parts[0].text === requestFor(c).system,
      "prompt drift",
    );
    assert(
      !("expected" in payload) && payload.contents[0].parts[0].text === c.text,
      "gold leak",
    );
    assert(
      init?.redirect === "error" &&
        payload.generationConfig.maxOutputTokens === 2048,
      "unbounded call",
    );
    return Promise.resolve(
      Response.json({
        candidates: [{
          finishReason: "STOP",
          content: { parts: [{ text: "[]" }] },
        }],
        usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 5 },
      }),
    );
  };
  const p = await callGemini(c, 0, config, "test-secret", fake);
  assert(
    n === 1 && p.status === "ok" && p.input_tokens === 100 &&
      p.response_text === "[]",
    "provider parse",
  );
});
Deno.test("HTTP errors are sanitized, not retried and not scored as successful calls", async () => {
  let n = 0;
  const fake: typeof fetch = () => {
    n++;
    return Promise.resolve(
      new Response("secret-key private body", { status: 429 }),
    );
  };
  const p = await callGemini(c, 0, config, "test-secret", fake);
  assert(
    n === 1 && p.status === "error" && p.error_code === "http_429" &&
      !JSON.stringify(p).includes("secret"),
    "leak/retry",
  );
});
Deno.test("truncated generation and oversized provider payloads fail", async () => {
  const truncated: typeof fetch = () =>
    Promise.resolve(
      Response.json({
        candidates: [{
          finishReason: "MAX_TOKENS",
          content: { parts: [{ text: "[]" }] },
        }],
      }),
    );
  assert(
    (await callGemini(c, 0, config, "key", truncated)).status === "error",
    "truncated accepted",
  );
  const huge: typeof fetch = () =>
    Promise.resolve(new Response("x".repeat(300000)));
  assert(
    (await callGemini(c, 0, config, "key", huge)).status === "error",
    "huge accepted",
  );
});
Deno.test("timeouts abort the request and retain failure latency", async () => {
  const fake: typeof fetch = (_url, init) =>
    new Promise((_resolve, reject) =>
      init!.signal!.addEventListener(
        "abort",
        () => reject(new Error("private details")),
      )
    );
  const p = await callGemini(c, 0, { ...config, timeout_ms: 1 }, "key", fake);
  assert(p.error_code === "timeout" && p.latency_ms !== null, "timeout lost");
});
Deno.test("Gemini payload does not depend on host wall clock", () => {
  assert(
    JSON.stringify(geminiPayload(c, config)) ===
      JSON.stringify(geminiPayload(c, config)),
    "nondeterministic payload",
  );
  assert(
    geminiPayload(c, config).system_instruction.parts[0].text.includes(
      c.current_time,
    ),
    "missing frozen clock",
  );
});
