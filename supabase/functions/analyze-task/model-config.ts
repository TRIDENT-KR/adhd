export const DEFAULT_GEMINI_MODEL = "gemini-3.5-flash-lite";

/** Only a model identifier is accepted, never a URL, path or query string. */
export function geminiModel(configured: string | undefined): string | null {
  const model = configured?.trim() || DEFAULT_GEMINI_MODEL;
  return /^gemini-[a-z0-9][a-z0-9._-]*$/.test(model) ? model : null;
}
