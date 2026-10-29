import { buildAnalysisPrompt } from "../../supabase/functions/analyze-task/prompt.ts";
import { assert, hash } from "./core.ts";
// Frozen from base 84f95e6 index.ts BEFORE extraction; not self-generated expected values.
const snapshots = [
  {
    "now": "2026-10-29 10:00",
    "language": "ko",
    "sha256":
      "cc1c973fad68d10810310e2b5bda158c3adc5f16af1545aeb634bd7740820bb8",
  },
  {
    "now": "2026-10-29 10:00",
    "language": "en",
    "sha256":
      "16ea3ec2a1d9ef18624ddaad6917ae7c16a92925b1cac11a4ad685c2e081bf5e",
  },
  {
    "now": "2026-10-29 10:00",
    "language": "ja",
    "sha256":
      "275b12640a25508a26f82c26d6527d0a0bef4f47c605add1c5f600fa559ce35d",
  },
  {
    "now": "2028-02-28 23:50",
    "language": "ko",
    "sha256":
      "138db95c847a52cce9d7f9a31c0f3c41c49a958b037d0964d571b5c7af4891cd",
  },
  {
    "now": "2028-02-28 23:50",
    "language": "en",
    "sha256":
      "855030b6099af1b18309ce5a6f2a789ba6e0bf8df98a6b7fc71c70bc86e2a336",
  },
  {
    "now": "2028-02-28 23:50",
    "language": "ja",
    "sha256":
      "b587f75d0873823549c5ab75a3b33cc5a4e6b0eeafc4a79829fc76c9d99184ba",
  },
];
Deno.test("shared prompt preserves all original bytes for each language and clock", async () => {
  for (const s of snapshots) {
    assert(
      await hash(buildAnalysisPrompt(s.now, s.language)) === s.sha256,
      "production prompt changed",
    );
  }
});
