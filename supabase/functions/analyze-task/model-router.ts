import { AnalysisServiceError } from "./analysis-service.ts";
import { claudeModel, geminiModel } from "./model-config.ts";
import { type AnalysisCall, validateAnalysisCalls } from "./validator.ts";

export interface ModelConfig {
  anthropicKey?: string;
  anthropicModel?: string;
  anthropicEnabled?: string;
  geminiKey?: string;
  geminiModel?: string;
}

type Provider = "claude" | "gemini";
export interface ModelAttempt {
  provider: Provider;
  model: string;
  outcome: "succeeded" | "failed";
  status: number | null;
  durationMs: number;
  failure: "http" | "timeout" | "invalid_response" | "network" | null;
}
type Fetch = (url: string, init: RequestInit) => Promise<Response>;
const MAX_OUTPUT_TOKENS = 4096;
const MAX_RESPONSE_BYTES = 128 * 1024;

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readBoundedJSON(
  response: Response | Request,
  limit: number,
): Promise<unknown> {
  if (Number(response.headers.get("Content-Length")) > limit) {
    await response.body?.cancel();
    throw new Error("body_too_large");
  }
  const reader = response.body?.getReader();
  if (!reader) throw new Error("empty_body");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new Error("body_too_large");
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}

function parseCalls(provider: Provider, value: unknown): AnalysisCall[] {
  if (!record(value)) throw new Error("invalid_model_response");
  let blocks: unknown;
  if (provider === "claude") {
    if (value.stop_reason !== "end_turn") {
      throw new Error("incomplete_response");
    }
    blocks = value.content;
  } else {
    const candidate = Array.isArray(value.candidates)
      ? value.candidates[0]
      : null;
    if (
      !record(candidate) || candidate.finishReason !== "STOP" ||
      !record(candidate.content)
    ) {
      throw new Error("incomplete_response");
    }
    blocks = candidate.content.parts;
  }
  if (!Array.isArray(blocks)) throw new Error("invalid_model_response");
  const text = blocks.filter((block) =>
    record(block) &&
    (provider === "claude" ? block.type === "text" : block.thought !== true) &&
    typeof block.text === "string"
  ).map((block) => block.text).join("").trim();
  const json = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  // Invalid JSON AND invalid actions trigger fallback, before quota finalization.
  return validateAnalysisCalls(JSON.parse(json));
}

/** One Claude attempt, then one Gemini attempt, within the same quota reservation.
 * The cooldown is an isolate-local latency optimization, not a spending limit.
 * Credit spending limits/auto-reload must be configured in the provider account.
 */
export function createModelRouter(
  config: ModelConfig,
  dependencies: { fetch?: Fetch; now?: () => number; timeoutMs?: number } = {},
) {
  const fetcher = dependencies.fetch ?? fetch;
  const now = dependencies.now ?? Date.now;
  const timeoutMs = dependencies.timeoutMs ?? 8000;
  let claudeUnavailableUntil = 0;
  return async (
    system: string,
    text: string,
    observe?: (attempt: ModelAttempt) => void,
  ): Promise<AnalysisCall[]> => {
    const claude = claudeModel(config.anthropicModel);
    const gemini = geminiModel(config.geminiModel);
    const providers: Provider[] = [];
    if (
      config.anthropicEnabled !== "false" && config.anthropicKey?.trim() &&
      claude && now() >= claudeUnavailableUntil
    ) {
      providers.push("claude");
    }
    if (config.geminiKey?.trim() && gemini) providers.push("gemini");
    if (!providers.length) {
      throw new AnalysisServiceError("server_not_configured", 503);
    }

    for (const provider of providers) {
      const startedAt = performance.now();
      let status: number | null = null;
      const report = (
        outcome: ModelAttempt["outcome"],
        failure: ModelAttempt["failure"],
      ) => {
        // Diagnostics must not change routing or include input, credentials or response bodies.
        try {
          observe?.({
            provider,
            model: (provider === "claude" ? claude : gemini)!,
            outcome,
            status,
            durationMs: Math.round(performance.now() - startedAt),
            failure,
          });
        } catch { /* telemetry is best effort */ }
      };
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetcher(
          provider === "claude"
            ? "https://api.anthropic.com/v1/messages"
            : `https://generativelanguage.googleapis.com/v1beta/models/${gemini}:generateContent`,
          {
            method: "POST",
            redirect: "error",
            signal: controller.signal,
            headers: provider === "claude"
              ? {
                "Content-Type": "application/json",
                "x-api-key": config.anthropicKey!,
                "anthropic-version": "2023-06-01",
              }
              : {
                "Content-Type": "application/json",
                "x-goog-api-key": config.geminiKey!,
              },
            body: JSON.stringify(
              provider === "claude"
                ? {
                  model: claude,
                  max_tokens: MAX_OUTPUT_TOKENS,
                  ...(claude === "claude-haiku-5-5"
                    ? { output_config: { effort: "low" } }
                    : {}),
                  system,
                  messages: [{ role: "user", content: text }],
                }
                : {
                  system_instruction: { parts: [{ text: system }] },
                  contents: [{ role: "user", parts: [{ text }] }],
                  generationConfig: {
                    response_mime_type: "application/json",
                    maxOutputTokens: MAX_OUTPUT_TOKENS,
                  },
                },
            ),
          },
        );
        status = response.status;
        if (!response.ok) {
          // Includes exhausted credit (400/402), invalid key, throttling, overload.
          // Never retain or log provider error bodies, which can contain input.
          if (provider === "claude") {
            const cooldown = [400, 401, 402, 403, 404].includes(response.status)
              ? 300_000
              : 30_000;
            claudeUnavailableUntil = now() + cooldown;
          }
          await response.body?.cancel();
          throw new Error("provider_unavailable");
        }
        const calls = parseCalls(
          provider,
          await readBoundedJSON(response, MAX_RESPONSE_BYTES),
        );
        report("succeeded", null);
        return calls;
      } catch {
        report(
          "failed",
          controller.signal.aborted
            ? "timeout"
            : status === null
            ? "network"
            : status >= 400
            ? "http"
            : "invalid_response",
        );
        if (provider === "claude" && controller.signal.aborted) {
          claudeUnavailableUntil = now() + 30_000;
        }
        // Provider output is untrusted. Continue to the next configured provider.
      } finally {
        clearTimeout(timer);
      }
    }
    throw new AnalysisServiceError("model_providers_unavailable", 502);
  };
}
