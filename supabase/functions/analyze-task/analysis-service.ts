import {
  type AnalysisCall,
  AnalysisValidationError,
  validateAnalysisCalls,
} from "./validator.ts";

export interface AnalysisInput {
  requestId: string;
  text: string;
  currentTime?: string;
  language?: string;
}

export interface QuotaReservation {
  allowed: boolean;
  reason?: string | null;
  alreadyCommitted?: boolean;
  cachedCalls?: unknown;
  quota?: unknown;
}

export interface AnalysisDependencies {
  reserve(requestId: string, inputHash: string): Promise<QuotaReservation>;
  analyze(input: AnalysisInput): Promise<unknown>;
  finalize(requestId: string, calls: AnalysisCall[]): Promise<unknown>;
  fail(requestId: string, failureCode: string): Promise<void>;
}

export interface AnalysisResult {
  requestId: string;
  calls: AnalysisCall[];
  quota: unknown;
}

export class AnalysisServiceError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
    message = code,
  ) {
    super(message);
    this.name = "AnalysisServiceError";
  }
}

const requestIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const currentTimePattern = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/;
const languages = new Set(["en", "ko", "ja"]);

function validateInput(input: AnalysisInput): void {
  if (!requestIdPattern.test(input.requestId)) {
    throw new AnalysisServiceError("invalid_request_id", 400);
  }
  if (typeof input.text !== "string" || input.text.trim().length === 0) {
    throw new AnalysisServiceError("empty_text", 400);
  }
  if (input.text.length > 1000) {
    throw new AnalysisServiceError("input_too_long", 400);
  }
  if (
    input.currentTime !== undefined &&
    !currentTimePattern.test(input.currentTime)
  ) {
    throw new AnalysisServiceError("invalid_current_time", 400);
  }
  if (input.language !== undefined && !languages.has(input.language)) {
    throw new AnalysisServiceError("invalid_language", 400);
  }
}

async function inputHash(input: AnalysisInput): Promise<string> {
  const canonical = JSON.stringify({
    text: input.text,
    currentTime: input.currentTime ?? null,
    language: input.language ?? "en",
  });
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

function reservationError(
  reason: string | null | undefined,
): AnalysisServiceError {
  switch (reason) {
    case "quota_exhausted":
      return new AnalysisServiceError("quota_exhausted", 429);
    case "replay_limit":
      return new AnalysisServiceError("request_replay_limit", 429);
    case "request_conflict":
      return new AnalysisServiceError("request_conflict", 409);
    case "in_progress":
      return new AnalysisServiceError("analysis_in_progress", 409);
    case "request_failed":
    case "reservation_expired":
    case "result_expired":
      return new AnalysisServiceError("new_request_id_required", 409);
    default:
      return new AnalysisServiceError("quota_unavailable", 503);
  }
}

function failureCode(error: unknown): string {
  if (error instanceof AnalysisValidationError) return "invalid_model_response";
  if (error instanceof AnalysisServiceError) return error.code;
  return "analysis_failed";
}

export async function executeAnalysis(
  input: AnalysisInput,
  dependencies: AnalysisDependencies,
): Promise<AnalysisResult> {
  validateInput(input);
  const hash = await inputHash(input);
  const reservation = await dependencies.reserve(input.requestId, hash);
  if (!reservation.allowed) throw reservationError(reservation.reason);
  if (reservation.alreadyCommitted) {
    try {
      const calls = validateAnalysisCalls(reservation.cachedCalls);
      return { requestId: input.requestId, calls, quota: reservation.quota };
    } catch {
      throw new AnalysisServiceError("cached_result_invalid", 500);
    }
  }

  try {
    const raw = await dependencies.analyze(input);
    const calls = validateAnalysisCalls(raw);
    const quota = await dependencies.finalize(input.requestId, calls);
    return { requestId: input.requestId, calls, quota };
  } catch (error) {
    try {
      await dependencies.fail(input.requestId, failureCode(error));
    } catch {
      // Preserve the primary analysis error. Expired reservations are also
      // reclaimed by the bounded database cleanup function.
    }
    if (error instanceof AnalysisValidationError) {
      throw new AnalysisServiceError("invalid_model_response", 502);
    }
    if (error instanceof AnalysisServiceError) throw error;
    throw new AnalysisServiceError("analysis_failed", 502);
  }
}
