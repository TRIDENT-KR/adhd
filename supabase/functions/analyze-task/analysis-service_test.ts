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

Deno.test("successful validated analyses finalize exactly once", async () => {
  const mock = dependencies();
  const result = await executeAnalysis(
    { requestId, text: "내일 약 먹는 시간 언제로 할까", language: "ko" },
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
    await executeAnalysis({ requestId, text: "테스트" }, mock.value);
    throw new Error("expected invalid response error");
  } catch (error) {
    assert(error instanceof AnalysisServiceError, "expected service error");
    assert(error.code === "invalid_model_response", "unexpected error code");
  }
  assert(mock.calls.finalize === 0, "invalid response must not finalize");
  assert(mock.calls.fail === 1, "invalid response must release reservation");
});

Deno.test("quota denial does not call Gemini or mutate a reservation", async () => {
  const mock = dependencies({
    reserve: () =>
      Promise.resolve({ allowed: false, reason: "quota_exhausted" }),
  });
  try {
    await executeAnalysis({ requestId, text: "테스트" }, mock.value);
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
    { requestId, text: "같은 요청" },
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
    await executeAnalysis({ requestId, text: "진행 중 요청" }, mock.value);
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
