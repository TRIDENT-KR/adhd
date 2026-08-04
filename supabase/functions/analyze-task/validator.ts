export const analysisFunctionNames = [
  "add_single_task",
  "update_task",
  "delete_specific_task",
  "clear_all_tasks",
  "postpone_all_tasks",
  "mark_task_complete",
  "request_clarification",
  "handle_off_topic_chat",
] as const;

export type AnalysisFunctionName = typeof analysisFunctionNames[number];

export interface AnalysisCall {
  function_name: AnalysisFunctionName;
  parameters: Record<string, unknown>;
}

export class AnalysisValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AnalysisValidationError";
  }
}

const functionNameSet = new Set<string>(analysisFunctionNames);
const recurrenceSet = new Set(["weekly", "biweekly", "monthly", "yearly"]);
const taskCategorySet = new Set(["Routine", "Appointment"]);
const targetCategorySet = new Set(["Routine", "Appointment", "all"]);
const urgencySet = new Set(["strong", "weak"]);
const timePattern = /^(0[1-9]|1[0-2]):[0-5][0-9] (AM|PM)$/;
const datePattern = /^(\d{4})-(\d{2})-(\d{2})$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fail(index: number, message: string): never {
  throw new AnalysisValidationError(`calls[${index}]: ${message}`);
}

function assertExactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  required: readonly string[],
  index: number,
): void {
  const allowedSet = new Set(allowed);
  const unexpected = Object.keys(value).find((key) => !allowedSet.has(key));
  if (unexpected) fail(index, `unexpected parameter "${unexpected}"`);
  const missing = required.find((key) => !(key in value));
  if (missing) fail(index, `missing parameter "${missing}"`);
}

function assertNonEmptyString(
  value: unknown,
  field: string,
  index: number,
  maximumLength = 200,
): asserts value is string {
  if (
    typeof value !== "string" || value.trim().length === 0 ||
    value.length > maximumLength
  ) {
    fail(index, `invalid ${field}`);
  }
}

function assertNullableTime(
  value: unknown,
  field: string,
  index: number,
): void {
  if (
    value !== null && (typeof value !== "string" || !timePattern.test(value))
  ) {
    fail(index, `invalid ${field}`);
  }
}

function isValidDate(value: string): boolean {
  const match = datePattern.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day;
}

function assertNullableDate(
  value: unknown,
  field: string,
  index: number,
): void {
  if (value !== null && (typeof value !== "string" || !isValidDate(value))) {
    fail(index, `invalid ${field}`);
  }
}

function assertDateOrAll(value: unknown, field: string, index: number): void {
  if (typeof value !== "string" || (value !== "all" && !isValidDate(value))) {
    fail(index, `invalid ${field}`);
  }
}

function assertNullableEnum(
  value: unknown,
  allowed: ReadonlySet<string>,
  field: string,
  index: number,
): void {
  if (value !== null && (typeof value !== "string" || !allowed.has(value))) {
    fail(index, `invalid ${field}`);
  }
}

function validateAdd(parameters: Record<string, unknown>, index: number): void {
  const keys = [
    "task_name",
    "time",
    "date",
    "category",
    "recurrence",
    "urgency",
  ];
  assertExactKeys(parameters, keys, keys, index);
  assertNonEmptyString(parameters.task_name, "task_name", index);
  assertNullableTime(parameters.time, "time", index);
  assertNullableDate(parameters.date, "date", index);
  if (
    typeof parameters.category !== "string" ||
    !taskCategorySet.has(parameters.category)
  ) {
    fail(index, "invalid category");
  }
  assertNullableEnum(parameters.recurrence, recurrenceSet, "recurrence", index);
  assertNullableEnum(parameters.urgency, urgencySet, "urgency", index);
}

function validateUpdate(
  parameters: Record<string, unknown>,
  index: number,
): void {
  const optional = [
    "new_time",
    "new_date",
    "new_task_name",
    "new_category",
    "new_recurrence",
  ];
  assertExactKeys(
    parameters,
    ["target_task_name", ...optional],
    ["target_task_name", ...optional],
    index,
  );
  assertNonEmptyString(parameters.target_task_name, "target_task_name", index);
  if ("new_time" in parameters) {
    assertNullableTime(parameters.new_time, "new_time", index);
  }
  if ("new_date" in parameters) {
    assertNullableDate(parameters.new_date, "new_date", index);
  }
  if ("new_task_name" in parameters && parameters.new_task_name !== null) {
    assertNonEmptyString(parameters.new_task_name, "new_task_name", index);
  }
  if ("new_category" in parameters) {
    assertNullableEnum(
      parameters.new_category,
      taskCategorySet,
      "new_category",
      index,
    );
  }
  if ("new_recurrence" in parameters) {
    assertNullableEnum(
      parameters.new_recurrence,
      recurrenceSet,
      "new_recurrence",
      index,
    );
  }
  if (!optional.some((key) => key in parameters && parameters[key] !== null)) {
    fail(index, "update contains no change");
  }
}

function validateDelete(
  parameters: Record<string, unknown>,
  index: number,
): void {
  assertExactKeys(
    parameters,
    ["target_task_name", "target_category", "target_date"],
    ["target_task_name", "target_category", "target_date"],
    index,
  );
  assertNonEmptyString(parameters.target_task_name, "target_task_name", index);
  if (
    "target_category" in parameters &&
    (typeof parameters.target_category !== "string" ||
      !targetCategorySet.has(parameters.target_category))
  ) {
    fail(index, "invalid target_category");
  }
  if ("target_date" in parameters) {
    assertDateOrAll(parameters.target_date, "target_date", index);
  }
}

function validateClear(
  parameters: Record<string, unknown>,
  index: number,
): void {
  assertExactKeys(
    parameters,
    ["target_category", "target_date"],
    ["target_category", "target_date"],
    index,
  );
  if (
    "target_category" in parameters &&
    (typeof parameters.target_category !== "string" ||
      !targetCategorySet.has(parameters.target_category))
  ) {
    fail(index, "invalid target_category");
  }
  assertDateOrAll(parameters.target_date, "target_date", index);
}

function validatePostpone(
  parameters: Record<string, unknown>,
  index: number,
): void {
  const keys = ["from_date", "to_date"];
  assertExactKeys(parameters, keys, keys, index);
  if (
    typeof parameters.from_date !== "string" ||
    !isValidDate(parameters.from_date)
  ) {
    fail(index, "invalid from_date");
  }
  if (
    typeof parameters.to_date !== "string" || !isValidDate(parameters.to_date)
  ) {
    fail(index, "invalid to_date");
  }
}

function validateCall(
  call: Record<string, unknown>,
  index: number,
): AnalysisCall {
  assertExactKeys(call, ["function_name", "parameters"], [
    "function_name",
    "parameters",
  ], index);
  if (
    typeof call.function_name !== "string" ||
    !functionNameSet.has(call.function_name)
  ) {
    fail(index, "unknown function_name");
  }
  if (!isRecord(call.parameters)) fail(index, "parameters must be an object");

  const functionName = call.function_name as AnalysisFunctionName;
  const parameters = call.parameters as Record<string, unknown>;
  switch (functionName) {
    case "add_single_task":
      validateAdd(parameters, index);
      break;
    case "update_task":
      validateUpdate(parameters, index);
      break;
    case "delete_specific_task":
      validateDelete(parameters, index);
      break;
    case "clear_all_tasks":
      validateClear(parameters, index);
      break;
    case "postpone_all_tasks":
      validatePostpone(parameters, index);
      break;
    case "mark_task_complete":
      assertExactKeys(
        parameters,
        ["target_task_name"],
        ["target_task_name"],
        index,
      );
      assertNonEmptyString(
        parameters.target_task_name,
        "target_task_name",
        index,
      );
      break;
    case "request_clarification":
      assertExactKeys(parameters, ["reason"], ["reason"], index);
      assertNonEmptyString(parameters.reason, "reason", index, 500);
      break;
    case "handle_off_topic_chat":
      assertExactKeys(parameters, ["message"], ["message"], index);
      assertNonEmptyString(parameters.message, "message", index, 500);
      break;
  }

  return { function_name: functionName, parameters: { ...parameters } };
}

export function validateAnalysisCalls(value: unknown): AnalysisCall[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 50) {
    throw new AnalysisValidationError("response must contain 1 to 50 calls");
  }
  return value.map((item, index) => {
    if (!isRecord(item)) fail(index, "call must be an object");
    return validateCall(item, index);
  });
}
