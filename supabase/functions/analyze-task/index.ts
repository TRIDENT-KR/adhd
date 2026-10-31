import { buildAnalysisPrompt } from "./prompt.ts";
import { createClient } from "@supabase/supabase-js";
import {
  type AnalysisInput,
  AnalysisServiceError,
  executeAnalysis,
  type QuotaReservation,
} from "./analysis-service.ts";

import { createModelRouter, readBoundedJSON } from "./model-router.ts";
import { bindAccountEnvironment } from "./account-environment.ts";

const analyzeWithFallback = createModelRouter({
  anthropicKey: Deno.env.get("ANTHROPIC_API_KEY"),
  anthropicModel: Deno.env.get("ANTHROPIC_MODEL"),
  anthropicEnabled: Deno.env.get("ANTHROPIC_ENABLED"),
  geminiKey: Deno.env.get("GEMINI_API_KEY"),
  geminiModel: Deno.env.get("GEMINI_MODEL"),
});

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
    "Cache-Control": "no-store",
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
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
      throw new AnalysisServiceError("server_not_configured", 503);
    }
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

    // Bind the authenticated account's environment (and deletion lock) before
    // parsing text, consuming quota, replaying cached output, or calling a model.
    await bindAccountEnvironment(() => supabase.rpc("get_adult_eligibility"));

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    let rawBody: unknown;
    try {
      rawBody = await readBoundedJSON(req, 16 * 1024);
    } catch (error) {
      throw new AnalysisServiceError(
        error instanceof Error && error.message === "body_too_large"
          ? "request_body_too_large"
          : "invalid_request_body",
        error instanceof Error && error.message === "body_too_large"
          ? 413
          : 400,
      );
    }
    if (!isRecord(rawBody)) {
      throw new AnalysisServiceError("invalid_request_body", 400);
    }
    const input: AnalysisInput = {
      aiConsentVersion: typeof rawBody.aiConsentVersion === "string"
        ? rawBody.aiConsentVersion
        : undefined,
      requestId: typeof rawBody.requestId === "string" ? rawBody.requestId : "",
      text: typeof rawBody.text === "string" ? rawBody.text : "",
      currentTime: typeof rawBody.currentTime === "string"
        ? rawBody.currentTime
        : undefined,
      language: typeof rawBody.language === "string"
        ? rawBody.language
        : undefined,
    };
    logicalRequestId = /^[0-9a-f-]{36}$/i.test(input.requestId)
      ? input.requestId
      : undefined;
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
      const { error } = await admin.rpc("mora_record_operational_event_v2", {
        p_user_id: user.id,
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

    let provider = "cache";
    const result = await executeAnalysis(input, {
      reserve: async (requestId, inputHash): Promise<QuotaReservation> => {
        const { data, error } = await admin.rpc("mora_reserve_ai_analysis_v2", {
          p_user_id: user.id,
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
            ["quota_exhausted", "rate_limited"].includes(
                reservation.reason ?? "",
              )
              ? 429
              : 409,
            null,
            reservation.reason ?? "quota_denied",
          );
        }
        return reservation;
      },
      analyze: () =>
        analyzeWithFallback(finalPrompt, text, (attempt) => {
          console.log("analysis_provider", {
            traceId,
            requestId: input.requestId,
            provider: attempt.provider,
            model: attempt.model,
            outcome: attempt.outcome,
            status: attempt.status,
            durationMs: attempt.durationMs,
            failure: attempt.failure,
          });
          if (attempt.outcome === "succeeded") provider = attempt.provider;
        }),
      finalize: async (requestId, calls) => {
        const { data, error } = await admin.rpc(
          "mora_finalize_ai_analysis_v2",
          {
            p_user_id: user.id,
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
        const { error } = await admin.rpc("mora_fail_ai_analysis_v2", {
          p_user_id: user.id,
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
    return new Response(JSON.stringify(result), {
      headers: { ...headers, "X-Mora-AI-Provider": provider },
      status: 200,
    });
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
