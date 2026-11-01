import {
  type AnalysisDependencies,
  AnalysisServiceError,
  executeAnalysis,
} from "./analysis-service.ts";

const requestId = "018f8f6e-4d52-7abc-8def-0123456789ab";
const validCall = [{
  function_name: "request_clarification",
  parameters: { reason: "시간을 알려주세요." },
}];

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function dependencies(overrides: Partial<AnalysisDependencies> = {}) {
  const calls = { reserve: 0, analyze: 0, finalize: 0, fail: 0 };
  const value: AnalysisDependencies = {
    reserve: () => {
      calls.reserve += 1;
      return Promise.resolve({ allowed: true, quota: { remaining: 2 } });
    },
    analyze: () => {
      calls.analyze += 1;
      return Promise.resolve(validCall);
    },
    finalize: () => {
      calls.finalize += 1;
      return Promise.resolve({ remaining: 2, usageDate: "2026-08-04" });
    },
    fail: () => {
      calls.fail += 1;
      return Promise.resolve();
    },
    ...overrides,
  };
  return { value, calls };
}

Deno.test("old or missing provider consent cannot reserve, replay, or transmit", async () => {
  for (const version of [undefined, "1", "3"]) {
    const mock = dependencies();
    try {
      await executeAnalysis({
        aiConsentVersion: version,
        requestId,
        text: "테스트",
      }, mock.value);
      throw new Error("expected consent error");
    } catch (error) {
      assert(
        error instanceof AnalysisServiceError &&
          error.code === "ai_consent_required",
        "consent gate missing",
      );
    }
    assert(
      Object.values(mock.calls).every((count) => count === 0),
      "no work is allowed without consent",
    );
  }
});

Deno.test("successful validated analyses finalize exactly once", async () => {
  const mock = dependencies();
  const result = await executeAnalysis(
    {
      aiConsentVersion: "2",
      requestId,
      text: "내일 약 먹는 시간 언제로 할까",
      language: "ko",
    },
    mock.value,
  );
  assert(result.requestId === requestId, "request ID was not preserved");
  assert(result.calls.length === 1, "validated calls missing");
  assert(mock.calls.reserve === 1, "reservation count mismatch");
  assert(mock.calls.analyze === 1, "analysis count mismatch");
  assert(mock.calls.finalize === 1, "finalize count mismatch");
  assert(mock.calls.fail === 0, "success must not fail reservation");
});

Deno.test("invalid model output fails reservation and is not finalized", async () => {
  const mock = dependencies({
    analyze: () =>
      Promise.resolve([{
        function_name: "unknown_function",
        parameters: {},
      }]),
  });
  try {
    await executeAnalysis(
      { aiConsentVersion: "2", requestId, text: "테스트" },
      mock.value,
    );
    throw new Error("expected invalid response error");
  } catch (error) {
    assert(error instanceof AnalysisServiceError, "expected service error");
    assert(error.code === "invalid_model_response", "unexpected error code");
  }
  assert(mock.calls.finalize === 0, "invalid response must not finalize");
  assert(mock.calls.fail === 1, "invalid response must release reservation");
});

Deno.test("mixed feedback and mutation cannot consume a successful quota", async () => {
  const mock = dependencies({
    analyze: () =>
      Promise.resolve([
        ...validCall,
        {
          function_name: "mark_task_complete",
          parameters: { target_task_name: "회의" },
        },
      ]),
  });
  try {
    await executeAnalysis(
      { aiConsentVersion: "2", requestId, text: "회의" },
      mock.value,
    );
    throw new Error("expected invalid response");
  } catch (error) {
    assert(
      error instanceof AnalysisServiceError &&
        error.code === "invalid_model_response",
      "expected validation failure",
    );
  }
  assert(mock.calls.finalize === 0, "mixed output must not consume quota");
  assert(mock.calls.fail === 1, "reservation must be released");
});

Deno.test("quota denial does not call Gemini or mutate a reservation", async () => {
  const mock = dependencies({
    reserve: () =>
      Promise.resolve({ allowed: false, reason: "quota_exhausted" }),
  });
  try {
    await executeAnalysis(
      { aiConsentVersion: "2", requestId, text: "테스트" },
      mock.value,
    );
    throw new Error("expected quota error");
  } catch (error) {
    assert(error instanceof AnalysisServiceError, "expected service error");
    assert(error.code === "quota_exhausted", "unexpected quota code");
    assert(error.status === 429, "unexpected quota status");
  }
  assert(mock.calls.analyze === 0, "quota denial must not call Gemini");
  assert(mock.calls.finalize === 0, "quota denial must not finalize");
  assert(mock.calls.fail === 0, "no reservation exists to fail");
});

Deno.test("logical request ID is bound to the complete input hash", async () => {
  let observedHash = "";
  const mock = dependencies({
    reserve: (_requestId, hash) => {
      observedHash = hash;
      return Promise.resolve({ allowed: true });
    },
  });
  await executeAnalysis(
    {
      aiConsentVersion: "2",
      requestId,
      text: "내일 회의",
      currentTime: "2026-08-04 09:00",
      language: "ko",
    },
    mock.value,
  );
  assert(/^[0-9a-f]{64}$/.test(observedHash), "expected SHA-256 input hash");
});

Deno.test("committed replay returns cached calls without Gemini or finalize", async () => {
  const mock = dependencies({
    reserve: () =>
      Promise.resolve({
        allowed: true,
        alreadyCommitted: true,
        cachedCalls: validCall,
        quota: { remaining: 2 },
      }),
  });
  const result = await executeAnalysis(
    { aiConsentVersion: "2", requestId, text: "같은 요청" },
    mock.value,
  );
  assert(result.calls.length === 1, "cached calls missing");
  assert(mock.calls.analyze === 0, "cached replay must not call Gemini");
  assert(mock.calls.finalize === 0, "cached replay must not finalize again");
  assert(mock.calls.fail === 0, "cached replay must not fail");
});

Deno.test("an active reservation returns 409 without duplicate Gemini work", async () => {
  const mock = dependencies({
    reserve: () => Promise.resolve({ allowed: false, reason: "in_progress" }),
  });
  try {
    await executeAnalysis({
      aiConsentVersion: "2",
      requestId,
      text: "진행 중 요청",
    }, mock.value);
    throw new Error("expected in-progress response");
  } catch (error) {
    assert(error instanceof AnalysisServiceError, "expected service error");
    assert(
      error.code === "analysis_in_progress",
      "unexpected in-progress code",
    );
    assert(error.status === 409, "in-progress response must be HTTP 409");
  }
  assert(
    mock.calls.analyze === 0,
    "active reservation must not call Gemini twice",
  );
});

const addWithLine = [{
  function_name: "add_single_task",
  parameters: {
    task_name: "약 먹기",
    time: "09:00 PM",
    date: null,
    category: "Routine",
    recurrence: null,
    urgency: "strong",
    alert_line: "약 먹을 시간이에요",
  },
}];

Deno.test("alert_line reaches only requests that sent a tone", async () => {
  const withTone = dependencies({ analyze: () => Promise.resolve(addWithLine) });
  const toned = await executeAnalysis({
    aiConsentVersion: "2",
    requestId,
    text: "매일 밤 9시 약 먹기",
    alertTone: "gentle",
  }, withTone.value);
  assert(
    toned.calls[0].parameters.alert_line === "약 먹을 시간이에요",
    "tone-aware requests keep the line",
  );

  const legacy = dependencies({ analyze: () => Promise.resolve(addWithLine) });
  const plain = await executeAnalysis({
    aiConsentVersion: "2",
    requestId,
    text: "매일 밤 9시 약 먹기",
  }, legacy.value);
  assert(
    !("alert_line" in plain.calls[0].parameters),
    "older builds must never see alert_line",
  );
});

Deno.test("unknown tones are rejected before any work", async () => {
  const mock = dependencies();
  try {
    await executeAnalysis({
      aiConsentVersion: "2",
      requestId,
      text: "테스트",
      alertTone: "rude",
    }, mock.value);
    throw new Error("expected tone error");
  } catch (error) {
    assert(
      error instanceof AnalysisServiceError && error.code === "invalid_alert_tone",
      "tone gate missing",
    );
  }
  assert(Object.values(mock.calls).every((count) => count === 0), "no work on bad tone");
});

Deno.test("requests without a tone hash exactly as before", async () => {
  const hashes: string[] = [];
  const capture = (requestHash: string) => {
    hashes.push(requestHash);
    return Promise.resolve({ allowed: true, quota: { remaining: 2 } });
  };
  const base = { aiConsentVersion: "2", requestId, text: "테스트" };
  await executeAnalysis(base, dependencies({ reserve: (_id, hash) => capture(hash) }).value);
  await executeAnalysis({ ...base, alertTone: "spicy" }, dependencies({ reserve: (_id, hash) => capture(hash) }).value);
  const legacy = JSON.stringify({
    aiConsentVersion: "2",
    text: "테스트",
    currentTime: null,
    language: "en",
  });
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(legacy));
  const expected = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  assert(hashes[0] === expected, "legacy hash changed");
  assert(hashes[1] !== expected, "tone must be part of the request hash");
});
