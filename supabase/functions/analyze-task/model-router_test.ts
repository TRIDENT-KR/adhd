import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  createModelRouter,
  type ModelAttempt,
  readBoundedJSON,
} from "./model-router.ts";
import { AnalysisServiceError, executeAnalysis } from "./analysis-service.ts";
import type { AnalysisCall } from "./validator.ts";
import { claudeModel } from "./model-config.ts";

const calls: AnalysisCall[] = [{
  function_name: "request_clarification",
  parameters: { reason: "언제 할까요?" },
}];
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
const claude = () =>
  json({
    stop_reason: "end_turn",
    content: [{ type: "thinking", thinking: "hidden" }, {
      type: "text",
      text: JSON.stringify(calls),
    }],
  });
const gemini = () =>
  json({
    candidates: [{
      finishReason: "STOP",
      content: {
        parts: [{ thought: true, text: "hidden" }, {
          text: JSON.stringify(calls),
        }],
      },
    }],
  });
const config = { anthropicKey: "fake-claude", geminiKey: "fake-gemini" };

Deno.test("provider evidence reports failed Claude then successful Gemini without secrets", async () => {
  const events: ModelAttempt[] = [];
  const route = createModelRouter(config, {
    fetch: (url) =>
      Promise.resolve(
        url.includes("anthropic.com")
          ? json({ message: "private input" }, 503)
          : gemini(),
      ),
  });
  assertEquals(
    await route(
      "private prompt",
      "private text",
      (event) => events.push(event),
    ),
    calls,
  );
  assertEquals(
    events.map(({ provider, outcome, status, failure }) => ({
      provider,
      outcome,
      status,
      failure,
    })),
    [
      { provider: "claude", outcome: "failed", status: 503, failure: "http" },
      { provider: "gemini", outcome: "succeeded", status: 200, failure: null },
    ],
  );
  assertEquals(JSON.stringify(events).includes("private"), false);
  assertEquals(JSON.stringify(events).includes("fake-"), false);
});

Deno.test("broken diagnostics cannot trigger fallback after a valid Claude result", async () => {
  let count = 0;
  const route = createModelRouter(config, {
    fetch: () => {
      count++;
      return Promise.resolve(claude());
    },
  });
  assertEquals(
    await route("system", "input", () => {
      throw new Error("observer failed");
    }),
    calls,
  );
  assertEquals(count, 1);
});

Deno.test("Claude succeeds first without sending the text to Gemini", async () => {
  let count = 0;
  const route = createModelRouter(config, {
    fetch: (url, init) => {
      count++;
      assertEquals(url, "https://api.anthropic.com/v1/messages");
      assertEquals(init.redirect, "error");
      assertEquals(new Headers(init.headers).get("x-api-key"), "fake-claude");
      const body = JSON.parse(init.body as string);
      assertEquals(body.model, "claude-haiku-5-5");
      assertEquals(body.messages, [{ role: "user", content: "input" }]);
      assertEquals(body.max_tokens, 4096);
      assertEquals(body.temperature, undefined);
      return Promise.resolve(claude());
    },
  });
  assertEquals(await route("system", "input"), calls);
  assertEquals(count, 1);
});

for (const status of [400, 401, 402, 403, 404, 429, 500, 529]) {
  Deno.test(`Claude HTTP ${status} falls back and cools down`, async () => {
    const seen: string[] = [];
    let now = 1000;
    const route = createModelRouter(config, {
      now: () => now,
      fetch: (url, init) => {
        seen.push(url);
        if (url.includes("anthropic.com")) {
          return Promise.resolve(
            json({ error: "private provider details" }, status),
          );
        }
        assertEquals(
          new Headers(init.headers).get("x-goog-api-key"),
          "fake-gemini",
        );
        assertEquals(JSON.parse(init.body as string).generationConfig, {
          response_mime_type: "application/json",
          maxOutputTokens: 4096,
        });
        return Promise.resolve(gemini());
      },
    });
    assertEquals(await route("system", "input"), calls);
    assertEquals(await route("system", "input"), calls);
    assertEquals(seen.filter((url) => url.includes("anthropic.com")).length, 1);
    now += 300_001;
    await route("system", "input");
    assertEquals(seen.filter((url) => url.includes("anthropic.com")).length, 2);
  });
}

for (
  const invalid of [
    { stop_reason: "end_turn", content: [{ type: "text", text: "not JSON" }] },
    {
      stop_reason: "end_turn",
      content: [{
        type: "text",
        text: '[{"function_name":"run_shell","parameters":{}}]',
      }],
    },
    {
      stop_reason: "max_tokens",
      content: [{ type: "text", text: JSON.stringify(calls) }],
    },
    { stop_reason: "refusal", content: [] },
  ]
) {
  Deno.test(`invalid Claude result falls back: ${JSON.stringify(invalid)}`, async () => {
    const route = createModelRouter(config, {
      fetch: (url) =>
        Promise.resolve(
          url.includes("anthropic.com") ? json(invalid) : gemini(),
        ),
    });
    assertEquals(await route("system", "input"), calls);
  });
}

Deno.test("Claude timeout aborts upstream and falls back", async () => {
  let aborted = false;
  const route = createModelRouter(config, {
    timeoutMs: 5,
    fetch: (url, init) => {
      if (!url.includes("anthropic.com")) return Promise.resolve(gemini());
      return new Promise((_resolve, reject) =>
        init.signal!.addEventListener("abort", () => {
          aborted = true;
          reject(new DOMException("aborted", "AbortError"));
        })
      );
    },
  });
  assertEquals(await route("system", "input"), calls);
  assertEquals(aborted, true);
});

Deno.test("absent/disabled Claude uses only Gemini; invalid model paths never become URLs", async () => {
  assertEquals(claudeModel("claude-x?key=secret"), null);
  assertEquals(claudeModel("https://attacker.invalid"), null);
  for (
    const overrides of [{ anthropicKey: undefined }, {
      anthropicEnabled: "false",
    }, { anthropicModel: "claude-x/path" }]
  ) {
    const route = createModelRouter({ ...config, ...overrides }, {
      fetch: (url) => {
        assertEquals(
          url.startsWith("https://generativelanguage.googleapis.com/"),
          true,
        );
        return Promise.resolve(gemini());
      },
    });
    assertEquals(await route("system", "input"), calls);
  }
});

Deno.test("both failures release one reservation and never finalize or expose upstream details", async () => {
  let reserved = 0, failed = 0, finalized = 0, fetched = 0;
  const route = createModelRouter(config, {
    fetch: () => {
      fetched++;
      return Promise.resolve(json({ secret: "private" }, 503));
    },
  });
  const error = await assertRejects(
    () =>
      executeAnalysis({
        aiConsentVersion: "2",
        requestId: "018f8f6e-4d52-7abc-8def-0123456789ab",
        text: "내일 약속",
      }, {
        reserve: () => {
          reserved++;
          return Promise.resolve({ allowed: true });
        },
        analyze: () => route("system", "input"),
        finalize: () => {
          finalized++;
          return Promise.resolve({});
        },
        fail: (_id, code) => {
          failed++;
          assertEquals(code, "model_providers_unavailable");
          return Promise.resolve();
        },
      }),
    AnalysisServiceError,
  );
  assertEquals(error.code, "model_providers_unavailable");
  assertEquals([reserved, failed, finalized, fetched], [1, 1, 0, 2]);
});

Deno.test("fallback success finalizes once, cached replay calls neither provider", async () => {
  let fetched = 0, finalized = 0, replay = false;
  const route = createModelRouter(config, {
    fetch: (url) => {
      fetched++;
      return Promise.resolve(
        url.includes("anthropic.com") ? json({}, 402) : gemini(),
      );
    },
  });
  const input = {
    aiConsentVersion: "2",
    requestId: "018f8f6e-4d52-7abc-8def-0123456789ab",
    text: "내일 약속",
  };
  const deps = {
    reserve: () =>
      Promise.resolve({
        allowed: true,
        alreadyCommitted: replay,
        cachedCalls: calls,
      }),
    analyze: () => route("system", input.text),
    finalize: () => {
      finalized++;
      return Promise.resolve({});
    },
    fail: () => {
      throw new Error("unexpected failure");
    },
  };
  await executeAnalysis(input, deps);
  replay = true;
  await executeAnalysis(input, deps);
  assertEquals([fetched, finalized], [2, 1]);
});

Deno.test("bounded JSON rejects oversized chunked bodies without Content-Length", async () => {
  await assertRejects(
    () =>
      readBoundedJSON(
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(
                new TextEncoder().encode('"' + "x".repeat(20) + '"'),
              );
              controller.close();
            },
          }),
        ),
        10,
      ),
    Error,
    "body_too_large",
  );
});
