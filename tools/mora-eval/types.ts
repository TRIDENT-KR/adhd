import type { AnalysisFunctionName } from "../../supabase/functions/analyze-task/validator.ts";

export type Value = string | null | { one_of: string[] } | { nonempty: true };
export interface ExpectedCall {
  function_name: AnalysisFunctionName;
  parameters: Record<string, Value>;
}
export interface Case {
  id: string;
  family: string; // Translations/paraphrases of one scenario share a family.
  language: "ko" | "en" | "ja";
  text: string;
  current_time: string;
  timezone: string; // Metadata only: production receives local wall time, not zone.
  kind: "command" | "clarify" | "off_topic";
  risk: "critical" | "standard";
  tags: string[];
  rationale: string;
  expected: ExpectedCall[]; // Ordered, complete calls, including explicit nulls.
}
export interface Dataset {
  schema_version: 1;
  name: string;
  version: string;
  purpose: "development" | "held_out";
  provenance: string;
  review: {
    status: "draft" | "human_reviewed";
    reviewer: string | null;
    date: string | null;
  };
  cases: Case[];
}
export interface Prediction {
  case_id: string;
  trial: number;
  request_hash: string;
  status: "ok" | "error";
  response_text?: string;
  error_code?: string; // Never raw HTTP bodies, credentials or exception messages.
  latency_ms: number | null;
  input_tokens?: number;
  output_tokens?: number;
  cost_usd?: number; // Missing means unknown, never zero.
}
export interface Run {
  schema_version: 1;
  dataset_hash: string;
  contract_hash: string;
  harness_hash: string;
  source_revision: string;
  system: string;
  model: string;
  configuration: Record<string, unknown>;
  evidence_kind: "live" | "imported" | "fixture";
  created_at: string;
  repetitions: number;
  predictions: Prediction[];
}
export interface Grade {
  case_id: string;
  family: string;
  language: string;
  kind: Case["kind"];
  risk: Case["risk"];
  tags: string[];
  trial: number;
  observed: boolean;
  json_valid: boolean;
  schema_valid: boolean;
  contract_match: boolean;
  expected_route: string;
  predicted_route: string;
  fields: { field: string; correct: boolean }[];
  unexpected_mutation: boolean;
  destructive_mismatch: boolean;
  unnecessary_clarification: boolean;
  issues: string[];
}
