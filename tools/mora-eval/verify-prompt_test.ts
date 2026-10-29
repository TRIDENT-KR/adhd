import { buildAnalysisPrompt } from "../../supabase/functions/analyze-task/prompt.ts";
import { assert, hash } from "./core.ts";
// Frozen from saved local production commit 2e1a123 before integration.
// The intentional constraints update is recorded in evidence/prompt-integration.json.
const snapshots = [
  {
    "now": "2026-10-29 10:00",
    "language": "ko",
    "sha256":
      "3c93be85d7fe6c74105d8ec867bf5019a4e7a37cb15e854a91bb78a28230ff95",
  },
  {
    "now": "2026-10-29 10:00",
    "language": "en",
    "sha256":
      "dc243d2537a51c8759e7509c6eed20b18adaae4d47871fa5d09aa60d4edc3e38",
  },
  {
    "now": "2026-10-29 10:00",
    "language": "ja",
    "sha256":
      "6df73725291b7391788c30e9a1f8c4dc9ac8c1aa92216dada218952cf59c34c5",
  },
  {
    "now": "2028-02-28 23:50",
    "language": "ko",
    "sha256":
      "ed254ae76f541291ab4748f2ee7551ed55766bdad0fc92df9b4e1aadde9321de",
  },
  {
    "now": "2028-02-28 23:50",
    "language": "en",
    "sha256":
      "2d70bf541a5b0ca92b48b86e10d8bbe7e55c5e482935015504be3b88323994d0",
  },
  {
    "now": "2028-02-28 23:50",
    "language": "ja",
    "sha256":
      "73504a6fb8d621089a62a1330fd31132a10f05423fff743f13984631b20c5571",
  },
];
Deno.test("shared prompt preserves integrated production bytes for each language and clock", async () => {
  for (const s of snapshots) {
    assert(
      await hash(buildAnalysisPrompt(s.now, s.language)) === s.sha256,
      "production prompt changed",
    );
  }
});
