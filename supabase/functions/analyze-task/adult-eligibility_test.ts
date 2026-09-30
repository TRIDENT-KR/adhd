// Exercise the real Edge handler with all outbound I/O replaced. No listener,
// real account, model request, environment secret, or network permission needed.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

type Handler = (request: Request) => Promise<Response>;

Deno.test("adult eligibility gates the actual analysis handler before quota/replay/LLM", async (t) => {
  const originalFetch = globalThis.fetch;
  const serveDescriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  const envDescriptor = Object.getOwnPropertyDescriptor(Deno.env, "get")!;
  let handler: Handler | undefined;
  let eligibility: unknown = { eligible: false, policyVersion: "adult-v1" };
  let eligibilityStatus = 200;
  let eligibilityNetworkFailure = false;
  let authenticated = true;
  let replay = false;
  let requests: string[] = [];
  const calls = [{
    function_name: "request_clarification",
    parameters: { reason: "What time should I use?" },
  }];
  const quota = { remaining: 2 };
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });

  try {
    Object.defineProperty(Deno.env, "get", {
      configurable: true,
      enumerable: envDescriptor.enumerable,
      writable: true,
      value: (key: string) =>
        ({
          SUPABASE_URL: "https://adult-eligibility-test.invalid",
          SUPABASE_ANON_KEY: "fake-public-key",
          GEMINI_API_KEY: "fake-model-key",
        } as Record<string, string>)[key],
    });
    Object.defineProperty(Deno, "serve", {
      configurable: true,
      enumerable: serveDescriptor.enumerable,
      writable: true,
      value: (receivedHandler: Handler) => {
        handler = receivedHandler;
      },
    });
    globalThis.fetch = (input) => {
      const url = new URL(
        input instanceof Request ? input.url : input.toString(),
      );
      requests.push(url.pathname);
      if (url.pathname === "/auth/v1/user") {
        return Promise.resolve(
          authenticated
            ? json({
              id: "f21078d7-a49e-439f-9c18-437c9bb53304",
              aud: "authenticated",
              role: "authenticated",
              app_metadata: {},
              user_metadata: {},
              created_at: "2026-09-30T00:00:00Z",
            })
            : json({ message: "invalid token" }, 401),
        );
      }
      if (url.pathname === "/rest/v1/rpc/get_adult_eligibility") {
        if (eligibilityNetworkFailure) {
          return Promise.reject(new TypeError("test-only network failure"));
        }
        return Promise.resolve(json(eligibility, eligibilityStatus));
      }
      if (url.pathname === "/rest/v1/rpc/mora_reserve_ai_analysis") {
        return Promise.resolve(json({
          allowed: true,
          alreadyCommitted: replay,
          cachedCalls: replay ? calls : null,
          quota,
        }));
      }
      if (url.hostname === "generativelanguage.googleapis.com") {
        return Promise.resolve(json({
          candidates: [{
            content: { parts: [{ text: JSON.stringify(calls) }] },
          }],
        }));
      }
      if (url.pathname === "/rest/v1/rpc/mora_finalize_ai_analysis") {
        return Promise.resolve(json(quota));
      }
      if (url.pathname === "/rest/v1/rpc/mora_record_operational_event") {
        return Promise.resolve(json(null));
      }
      // Never fall through to the real fetch, even if production adds a call.
      throw new Error(`Unexpected outbound request in offline test: ${url}`);
    };

    await import("./index.ts");
    if (!handler) throw new Error("Edge handler was not registered");
    const invoke = async () => {
      requests = [];
      return await handler!(
        new Request("https://edge-test.invalid/analyze-task", {
          method: "POST",
          headers: {
            Authorization: "Bearer fake-user-token",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            requestId: "67a02918-59d3-4dc0-80ba-45b6c3e834de",
            text: "Test task",
            language: "en",
            // A caller-supplied claim must never substitute for the RPC.
            eligible: true,
            policyVersion: "adult-v1",
          }),
        }),
      );
    };
    const assertBlocked = async (status: number, code: string) => {
      const response = await invoke();
      assertEquals(response.status, status);
      assertEquals(await response.json(), {
        error: { code },
        requestId: null,
      });
      // No reservation, cached-result lookup, mutation, model call, or text log.
      assertEquals(requests, [
        "/auth/v1/user",
        "/rest/v1/rpc/get_adult_eligibility",
      ]);
    };

    await t.step(
      "missing account attestation ignores caller claims and uses no quota or model",
      async () => {
        await assertBlocked(403, "adult_eligibility_required");
      },
    );
    await t.step(
      "a previously cached request is also blocked before replay",
      async () => {
        replay = true;
        await assertBlocked(403, "adult_eligibility_required");
        replay = false;
      },
    );
    await t.step(
      "old policy acceptance requires a new affirmative answer",
      async () => {
        eligibility = { eligible: true, policyVersion: "adult-v0" };
        await assertBlocked(403, "adult_eligibility_required");
      },
    );
    await t.step("malformed or absent RPC data fails closed", async () => {
      for (
        const malformed of [null, {}, [], {
          eligible: "true",
          policyVersion: "adult-v1",
        }, { eligible: true }]
      ) {
        eligibility = malformed;
        await assertBlocked(503, "adult_eligibility_unavailable");
      }
    });
    await t.step("database errors fail closed", async () => {
      eligibility = { message: "test database failure" };
      eligibilityStatus = 500;
      await assertBlocked(503, "adult_eligibility_unavailable");
      eligibilityStatus = 200;
    });
    await t.step("network errors fail closed", async () => {
      eligibilityNetworkFailure = true;
      await assertBlocked(503, "adult_eligibility_unavailable");
      eligibilityNetworkFailure = false;
    });
    await t.step(
      "eligible accounts preserve quota and model flow",
      async () => {
        eligibility = { eligible: true, policyVersion: "adult-v1" };
        const response = await invoke();
        assertEquals(response.status, 200);
        assertEquals((await response.json()).calls, calls);
        assertEquals(requests, [
          "/auth/v1/user",
          "/rest/v1/rpc/get_adult_eligibility",
          "/rest/v1/rpc/mora_reserve_ai_analysis",
          "/v1beta/models/gemini-3.5-flash-lite:generateContent",
          "/rest/v1/rpc/mora_finalize_ai_analysis",
          "/rest/v1/rpc/mora_record_operational_event",
        ]);
      },
    );
    await t.step(
      "eligible replay checks policy and does not call the model",
      async () => {
        replay = true;
        const response = await invoke();
        assertEquals(response.status, 200);
        assertEquals((await response.json()).calls, calls);
        assertEquals(requests, [
          "/auth/v1/user",
          "/rest/v1/rpc/get_adult_eligibility",
          "/rest/v1/rpc/mora_reserve_ai_analysis",
          "/rest/v1/rpc/mora_record_operational_event",
        ]);
      },
    );
    await t.step("failed authentication cannot read eligibility", async () => {
      authenticated = false;
      const response = await invoke();
      assertEquals(response.status, 401);
      assertEquals(requests, ["/auth/v1/user"]);
    });
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, "serve", serveDescriptor);
    Object.defineProperty(Deno.env, "get", envDescriptor);
  }
});
