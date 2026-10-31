import { AnalysisServiceError } from "./analysis-service.ts";

/**
 * Binds the account to its trusted environment (and honors a pending deletion
 * lock) before any quota or model work. The app no longer asks for an in-app
 * age answer: 18+ is enforced by the App Store age rating and the terms, so the
 * `eligible` flag in the RPC result is ignored. The RPC keeps its historical
 * name because it is the database function that performs the binding.
 */
export async function bindAccountEnvironment(
  bind: () => PromiseLike<{ data: unknown; error: unknown }>,
): Promise<void> {
  let result: { data: unknown; error: unknown };
  try {
    result = await bind();
  } catch {
    throw new AnalysisServiceError("account_environment_unavailable", 503);
  }
  if (result.error) {
    throw new AnalysisServiceError("account_environment_unavailable", 503);
  }
}
