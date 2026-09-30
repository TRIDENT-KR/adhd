import { AnalysisServiceError } from "./analysis-service.ts";

export const ADULT_POLICY_VERSION = "adult-v1";

/** Only a current affirmative account record permits sending text to the LLM. */
export async function requireAdultEligibility(
  lookup: () => PromiseLike<{ data: unknown; error: unknown }>,
): Promise<void> {
  let result: { data: unknown; error: unknown };
  try {
    result = await lookup();
  } catch {
    throw new AnalysisServiceError("adult_eligibility_unavailable", 503);
  }
  if (result.error) {
    throw new AnalysisServiceError("adult_eligibility_unavailable", 503);
  }
  const data = result.data;
  if (
    typeof data !== "object" || data === null || Array.isArray(data) ||
    !("eligible" in data) || typeof data.eligible !== "boolean" ||
    !("policyVersion" in data) || typeof data.policyVersion !== "string"
  ) {
    throw new AnalysisServiceError("adult_eligibility_unavailable", 503);
  }
  if (!data.eligible || data.policyVersion !== ADULT_POLICY_VERSION) {
    throw new AnalysisServiceError("adult_eligibility_required", 403);
  }
}
