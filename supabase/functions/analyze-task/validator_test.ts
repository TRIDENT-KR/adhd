import { AnalysisValidationError, validateAnalysisCalls } from "./validator.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertThrowsValidation(action: () => unknown): void {
  try {
    action();
  } catch (error) {
    assert(
      error instanceof AnalysisValidationError,
      "expected AnalysisValidationError",
    );
    return;
  }
  throw new Error("expected validation to fail");
}

Deno.test("validator accepts a complete task call", () => {
  const calls = validateAnalysisCalls([{
    function_name: "add_single_task",
    parameters: {
      task_name: "약 먹기",
      time: "09:00 AM",
      date: "2026-08-04",
      category: "Appointment",
      recurrence: null,
      urgency: "strong",
    },
  }]);
  assert(calls.length === 1, "expected one call");
  assert(calls[0].function_name === "add_single_task", "unexpected function");
});

Deno.test("clarification and off-topic calls are valid successful analyses", () => {
  const calls = validateAnalysisCalls([
    {
      function_name: "request_clarification",
      parameters: { reason: "언제 실행할까요?" },
    },
    {
      function_name: "handle_off_topic_chat",
      parameters: { message: "할 일이라면 도와드릴게요!" },
    },
  ]);
  assert(calls.length === 2, "expected two calls");
});

Deno.test("unknown functions are rejected instead of normalized", () => {
  assertThrowsValidation(() =>
    validateAnalysisCalls([{
      function_name: "send_message",
      parameters: {},
    }])
  );
});

Deno.test("missing function names are rejected instead of defaulted", () => {
  assertThrowsValidation(() =>
    validateAnalysisCalls([{
      parameters: {
        task_name: "임의 생성 방지",
        time: null,
        date: null,
        category: "Appointment",
        recurrence: null,
        urgency: null,
      },
    }])
  );
});

Deno.test("invalid calendar dates and unexpected parameters are rejected", () => {
  assertThrowsValidation(() =>
    validateAnalysisCalls([{
      function_name: "postpone_all_tasks",
      parameters: { from_date: "2026-02-30", to_date: "2026-03-01" },
    }])
  );
  assertThrowsValidation(() =>
    validateAnalysisCalls([{
      function_name: "mark_task_complete",
      parameters: { target_task_name: "약 먹기", hidden: true },
    }])
  );
});
