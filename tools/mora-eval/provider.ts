import { assert, hash, requestFor } from "./core.ts";
import type { Case, Prediction } from "./types.ts";

export interface GeminiConfig {
  model: string;
  max_output_tokens: number;
  timeout_ms: number;
}
export function geminiPayload(c: Case, cfg: GeminiConfig) {
  const request = requestFor(c);
  return {
    system_instruction: { parts: [{ text: request.system }] },
    contents: [{ role: "user", parts: [{ text: request.text }] }],
    generationConfig: {
      response_mime_type: "application/json",
      temperature: 0.1,
      maxOutputTokens: cfg.max_output_tokens,
    },
  };
}
export async function callGemini(
  c: Case,
  trial: number,
  cfg: GeminiConfig,
  key: string,
  fetcher: typeof fetch = fetch,
): Promise<Prediction> {
  assert(
    /^gemini-[a-z0-9._-]+$/.test(cfg.model),
    "Invalid Gemini model identifier",
  );
  assert(
    Number.isInteger(cfg.max_output_tokens) && cfg.max_output_tokens >= 1 &&
      cfg.max_output_tokens <= 8192,
    "Invalid token cap",
  );
  assert(
    Number.isInteger(cfg.timeout_ms) && cfg.timeout_ms >= 1 &&
      cfg.timeout_ms <= 120000,
    "Invalid timeout",
  );
  const p: Prediction = {
    case_id: c.id,
    trial,
    request_hash: await hash(requestFor(c)),
    status: "error",
    latency_ms: null,
  };
  const started = performance.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.timeout_ms);
  try {
    const response = await fetcher(
      `https://generativelanguage.googleapis.com/v1beta/models/${cfg.model}:generateContent`,
      {
        method: "POST",
        redirect: "error",
        signal: controller.signal,
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body: JSON.stringify(geminiPayload(c, cfg)),
      },
    );
    if (!response.ok) {
      await response.body?.cancel();
      p.error_code = `http_${response.status}`;
      return p;
    }
    // Limit payload size as well as generation tokens. No raw error bodies persisted.
    const reader = response.body?.getReader();
    assert(reader, "empty body");
    let size = 0;
    const chunks: Uint8Array[] = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        assert(size <= 256 * 1024, "body too large");
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
      offset += chunk.length;
    }
    const data = JSON.parse(new TextDecoder().decode(bytes));
    const candidate = data.candidates?.[0];
    if (candidate?.finishReason !== "STOP") {
      p.error_code = "incomplete_or_blocked";
      return p;
    }
    const parts = candidate?.content?.parts;
    if (
      !Array.isArray(parts) ||
      !parts.some((x) => typeof x.text === "string" && x.thought !== true)
    ) {
      p.error_code = "empty_response";
      return p;
    }
    p.response_text = parts.filter((x) =>
      typeof x.text === "string" && x.thought !== true
    ).map((x) => x.text).join("");
    p.status = "ok";
    for (
      const [source, target] of [["promptTokenCount", "input_tokens"], [
        "candidatesTokenCount",
        "output_tokens",
      ]] as const
    ) {
      const n = data.usageMetadata?.[source];
      if (Number.isInteger(n) && n >= 0) p[target] = n;
    }
    return p;
  } catch {
    p.error_code = controller.signal.aborted
      ? "timeout"
      : "network_or_provider_response";
    return p;
  } finally {
    clearTimeout(timer);
    p.latency_ms = Math.round(performance.now() - started);
  }
}
