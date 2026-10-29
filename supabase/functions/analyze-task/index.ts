import { buildAnalysisPrompt } from "./prompt.ts";
import { createClient } from "@supabase/supabase-js";
import {
  type AnalysisInput,
  AnalysisServiceError,
  executeAnalysis,
  type QuotaReservation,
} from "./analysis-service.ts";

import { geminiModel } from "./model-config.ts";
import { requireAdultEligibility } from "./adult-eligibility.ts";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");

// 유저당 분당 최대 호출 횟수 (Gemini 비용 증폭 방지)
const RATE_LIMIT_MAX = 30;
const RATE_LIMIT_WINDOW_MS = 60_000;

// 인메모리 rate limit 맵 (Edge Function 인스턴스 내 유효)
const rateLimitMap = new Map<string, number[]>();

function isRateLimited(userId: string): boolean {
  const now = Date.now();
  const windowStart = now - RATE_LIMIT_WINDOW_MS;
  const timestamps = (rateLimitMap.get(userId) ?? []).filter((t) =>
    t > windowStart
  );
  if (timestamps.length >= RATE_LIMIT_MAX) return true;
  timestamps.push(now);
  rateLimitMap.set(userId, timestamps);
  return false;
}

function promptTimeInSeoul(now = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const value = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${value("year")}-${value("month")}-${value("day")} ${value("hour")}:${
    value("minute")
  }`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function geminiResponseText(value: unknown): string | null {
  if (!isRecord(value) || !Array.isArray(value.candidates)) return null;
  const candidate = value.candidates[0];
  if (
    !isRecord(candidate) || !isRecord(candidate.content) ||
    !Array.isArray(candidate.content.parts)
  ) return null;
  const part = candidate.content.parts[0];
  return isRecord(part) && typeof part.text === "string" ? part.text : null;
}

Deno.serve(async (req: Request) => {
  const traceId = crypto.randomUUID();
  const startedAt = performance.now();
  let logicalRequestId: string | undefined;
  // iOS 클라이언트 전용 — CORS를 Supabase 프로젝트 도메인으로 제한
  const origin = req.headers.get("Origin") ?? "";
  const supabaseProjectOrigin = Deno.env.get("SUPABASE_URL") ?? "";
  // iOS 클라이언트는 Origin 헤더를 보내지 않음 → Dashboard/웹 테스트 요청만 CORS 검증
  const corsOrigin =
    (origin === supabaseProjectOrigin || origin === "https://supabase.com")
      ? origin
      : "https://supabase.com";

  const headers = {
    "Access-Control-Allow-Origin": corsOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Content-Type": "application/json",
  };

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers });
  }
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        error: { code: "method_not_allowed" },
        requestId: null,
      }),
      { headers: { ...headers, Allow: "POST" }, status: 405 },
    );
  }

  try {
    // JWT 인증 검증
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({
          error: { code: "missing_authorization" },
          requestId: null,
        }),
        { headers, status: 401 },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !supabaseAnonKey || !GEMINI_API_KEY) {
      throw new AnalysisServiceError("server_not_configured", 503);
    }
    const model = geminiModel(Deno.env.get("GEMINI_MODEL"));
    if (!model) throw new AnalysisServiceError("invalid_model_config", 503);
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({
          error: { code: "unauthorized" },
          requestId: null,
        }),
        { headers, status: 401 },
      );
    }

    // Check the authenticated account before parsing text, consuming quota,
    // replaying cached output, or sending any content to the model provider.
    await requireAdultEligibility(() => supabase.rpc("get_adult_eligibility"));

    // Rate limiting: 유저당 분당 30회 초과 시 429 반환
    if (isRateLimited(user.id)) {
      return new Response(
        JSON.stringify({
          error: { code: "rate_limited" },
          requestId: null,
        }),
        { headers, status: 429 },
      );
    }

    const rawBody: unknown = await req.json();
    if (!isRecord(rawBody)) {
      throw new AnalysisServiceError("invalid_request_body", 400);
    }
    const input: AnalysisInput = {
      requestId: typeof rawBody.requestId === "string" ? rawBody.requestId : "",
      text: typeof rawBody.text === "string" ? rawBody.text : "",
      currentTime: typeof rawBody.currentTime === "string"
        ? rawBody.currentTime
        : undefined,
      language: typeof rawBody.language === "string"
        ? rawBody.language
        : undefined,
    };
    logicalRequestId = input.requestId || undefined;
    const text = input.text;
    const localTimeStr = input.currentTime ?? promptTimeInSeoul();
    const userLanguage = input.language ?? "en";

    const finalPrompt = buildAnalysisPrompt(localTimeStr, userLanguage);

    const recordEvent = async (
      eventName: "analysis_succeeded" | "analysis_failed" | "quota_denied",
      statusCode: number,
      outputCount: number | null,
      failureCode: string | null,
    ) => {
      const { error } = await supabase.rpc("mora_record_operational_event", {
        p_request_id: input.requestId,
        p_event_name: eventName,
        p_status_code: statusCode,
        p_duration_ms: Math.round(performance.now() - startedAt),
        p_input_length: text.length,
        p_output_count: outputCount,
        p_failure_code: failureCode,
      });
      if (error) console.error("operational_event_write_failed", { traceId });
    };

    const result = await executeAnalysis(input, {
      reserve: async (requestId, inputHash): Promise<QuotaReservation> => {
        const { data, error } = await supabase.rpc("mora_reserve_ai_analysis", {
          p_request_id: requestId,
          p_input_hash: inputHash,
        });
        if (error || !isRecord(data) || typeof data.allowed !== "boolean") {
          throw new AnalysisServiceError("quota_backend_failed", 503);
        }
        const reservation: QuotaReservation = {
          allowed: data.allowed,
          reason: typeof data.reason === "string" ? data.reason : null,
          alreadyCommitted: data.alreadyCommitted === true,
          cachedCalls: data.cachedCalls,
          quota: data.quota,
        };
        if (!reservation.allowed) {
          await recordEvent(
            "quota_denied",
            reservation.reason === "quota_exhausted" ? 429 : 409,
            null,
            reservation.reason ?? "quota_denied",
          );
        }
        return reservation;
      },
      analyze: async () => {
        let response: Response;
        try {
          response = await fetch(
            `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "x-goog-api-key": GEMINI_API_KEY,
              },
              body: JSON.stringify({
                system_instruction: { parts: [{ text: finalPrompt }] },
                contents: [{ role: "user", parts: [{ text }] }],
                generationConfig: {
                  response_mime_type: "application/json",
                  temperature: 0.1,
                },
              }),
            },
          );
        } catch {
          throw new AnalysisServiceError("gemini_network_failed", 502);
        }
        const data: unknown = await response.json();
        if (!response.ok) {
          console.error("gemini_request_failed", {
            traceId,
            status: response.status,
          });
          throw new AnalysisServiceError("gemini_request_failed", 502);
        }
        const responseText = geminiResponseText(data);
        if (!responseText) {
          console.error("gemini_response_empty", { traceId });
          throw new AnalysisServiceError("invalid_model_response", 502);
        }
        const cleanedText = responseText.replace(/```json/g, "").replace(
          /```/g,
          "",
        )
          .trim();
        try {
          return JSON.parse(cleanedText) as unknown;
        } catch {
          throw new AnalysisServiceError("invalid_model_response", 502);
        }
      },
      finalize: async (requestId, calls) => {
        const { data, error } = await supabase.rpc(
          "mora_finalize_ai_analysis",
          {
            p_request_id: requestId,
            p_validated_calls: calls,
          },
        );
        if (error || !isRecord(data)) {
          throw new AnalysisServiceError("quota_finalize_failed", 503);
        }
        return data;
      },
      fail: async (requestId, failureCode) => {
        const { error } = await supabase.rpc("mora_fail_ai_analysis", {
          p_request_id: requestId,
          p_failure_code: failureCode,
        });
        if (error) throw new AnalysisServiceError("quota_fail_failed", 503);
        await recordEvent("analysis_failed", 502, null, failureCode);
      },
    });

    await recordEvent("analysis_succeeded", 200, result.calls.length, null);
    console.log("analysis_succeeded", {
      traceId,
      requestId: result.requestId,
      durationMs: Math.round(performance.now() - startedAt),
      inputLength: text.length,
      outputCount: result.calls.length,
    });
    return new Response(JSON.stringify(result), { headers, status: 200 });
  } catch (error) {
    const serviceError = error instanceof AnalysisServiceError
      ? error
      : error instanceof SyntaxError
      ? new AnalysisServiceError("invalid_request_body", 400)
      : new AnalysisServiceError("analysis_failed", 500);
    console.error("analysis_failed", {
      traceId,
      requestId: logicalRequestId ?? null,
      code: serviceError.code,
      durationMs: Math.round(performance.now() - startedAt),
    });
    return new Response(
      JSON.stringify({
        error: { code: serviceError.code },
        requestId: logicalRequestId ?? null,
      }),
      {
        headers,
        status: serviceError.status,
      },
    );
  }
});
