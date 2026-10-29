#!/usr/bin/env python3
"""Explicit live smoke test: temporary admin-only Edge probe, real provider calls.

Copies the production router/validator/prompt; injects Claude HTTP failures only
inside this disposable function. A 384-bit per-run operator token is required;
only its SHA256 is embedded in the function. Never changes production settings.
Supabase credentials stay in memory; output contains only synthetic results and
allowlisted routing metadata. Deletes the probe in finally, including failures.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def cli(*args, cwd=ROOT):
    result = subprocess.run(["supabase", *args], cwd=cwd, capture_output=True,
                            text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"Supabase {args[0]} {args[1]} failed ({result.returncode})")
    return result.stdout


def request(url, key, body=None, probe_token=""):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {key}", "apikey": key,
        "Content-Type": "application/json", "X-Mora-Probe-Token": probe_token})
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            value = json.load(error)
        except (ValueError, OSError):
            value = {"error": "non_json_error"}
        return error.code, value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_ref")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--modes", nargs="+", choices=["normal", "claude_503", "claude_402"],
                        default=["normal", "claude_503", "claude_402"])
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]{20}", args.project_ref):
        parser.error("Invalid project ref")
    keys = json.loads(cli("projects", "api-keys", "--project-ref", args.project_ref, "-o", "json"))
    service_key = next(item["api_key"] for item in keys if item["name"] == "service_role")
    name = "mora-provider-probe-" + uuid.uuid4().hex[:8]
    probe_token = secrets.token_urlsafe(48)
    probe_hash = hashlib.sha256(probe_token.encode()).hexdigest()
    source = ROOT / "supabase/functions/analyze-task"
    index = (source / "index.ts").read_text()
    prompt = re.search(r"const finalPrompt\s*=\s*(`.*?`);", index, re.S).group(1)
    report = {"project_ref": args.project_ref, "probe": name,
              "production_settings_changed": False, "cases": []}
    deploy_attempted = False
    passed = False
    try:
        with tempfile.TemporaryDirectory(prefix="mora-live-provider-") as tmp:
            work = Path(tmp)
            target = work / "supabase/functions" / name
            target.mkdir(parents=True)
            for filename in ["model-router.ts", "model-config.ts", "analysis-service.ts", "validator.ts", "deno.json"]:
                shutil.copy2(source / filename, target / filename)
            (work / "supabase/config.toml").write_text(
                f'project_id = "mora-live-verification"\n[functions.{name}]\n'
                f'verify_jwt = false\nimport_map = "./functions/{name}/deno.json"\n')
            probe = '''import { createModelRouter, readBoundedJSON, type ModelAttempt } from "./model-router.ts";
Deno.serve(async (req: Request) => {
  const supplied = req.headers.get("X-Mora-Probe-Token") ?? "";
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(supplied));
  const digest = Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, "0")).join("");
  if (digest !== "__PROBE_HASH__") {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  if (req.method !== "POST") return Response.json({ error: "method_not_allowed" }, { status: 405 });
  const { mode } = await req.json();
  if (!["normal", "claude_503", "claude_402"].includes(mode)) return Response.json({error:"invalid_mode"}, {status:400});
  const events: ModelAttempt[] = [];
  const realRequests: string[] = [];
  const providerErrors: unknown[] = [];
  const route = createModelRouter({
    anthropicKey: Deno.env.get("ANTHROPIC_API_KEY"),
    anthropicModel: Deno.env.get("ANTHROPIC_MODEL"),
    anthropicEnabled: Deno.env.get("ANTHROPIC_ENABLED"),
    geminiKey: Deno.env.get("GEMINI_API_KEY"), geminiModel: Deno.env.get("GEMINI_MODEL"),
  }, { fetch: async (url, init) => {
    if (url === "https://api.anthropic.com/v1/messages" && mode !== "normal") {
      return Promise.resolve(Response.json({error:{type:"injected_test_failure"}}, {status: mode === "claude_402" ? 402 : 503}));
    }
    realRequests.push(url.includes("anthropic.com") ? "claude" : "gemini");
    const response = await fetch(url, init);
    if (!response.ok) {
      try {
        const body = await readBoundedJSON(response.clone(), 128 * 1024) as {error?:{code?:unknown;status?:unknown;message?:unknown}};
        const error = body.error ?? {};
        const message = typeof error.message === "string" ? error.message.toLowerCase() : "";
        providerErrors.push({httpStatus:response.status,
          code: typeof error.code === "number" ? error.code : null,
          status: typeof error.status === "string" && /^[A-Z_]{1,64}$/.test(error.status) ? error.status : null,
          category: /billing|payment|credit|balance/.test(message) ? "billing_or_credit"
            : /api.key|credential/.test(message) ? "credential"
            : /quota|rate.limit/.test(message) ? "quota" : /model/.test(message) ? "model" : "other"});
      } catch { /* no raw provider response is returned */ }
    }
    return response;
  }});
  const localTimeStr = "2026-10-26 10:00";
  const userLanguage = "ko";
  const finalPrompt = __PROMPT__;
  try {
    const calls = await route(finalPrompt, "내일 오후 3시 치과 예약 추가해줘", event => events.push(event));
    return Response.json({calls, events, realRequests, providerErrors});
  } catch {
    return Response.json({error:"probe_failed", events, realRequests, providerErrors}, {status:502});
  }
});
'''.replace("__PROMPT__", prompt).replace("__PROBE_HASH__", probe_hash)
            (target / "index.ts").write_text(probe)
            deploy_attempted = True
            cli("functions", "deploy", name, "--project-ref", args.project_ref,
                "--use-api", "--no-verify-jwt", cwd=work)
            endpoint = f"https://{args.project_ref}.supabase.co/functions/v1/{name}"
            # An unauthenticated request must never reach a provider.
            denied_status, _ = request(endpoint, service_key, {"mode": "normal"})
            report["unauthorized_status"] = denied_status
            for mode in args.modes:
                status, value = request(endpoint, service_key, {"mode": mode}, probe_token)
                events = value.get("events", [])
                calls = value.get("calls", [])
                expected_providers = ["claude"] if mode == "normal" else ["claude", "gemini"]
                expected_real = ["claude"] if mode == "normal" else ["gemini"]
                parameters = calls[0].get("parameters", {}) if len(calls) == 1 else {}
                ok = (status == 200 and [e.get("provider") for e in events] == expected_providers
                      and value.get("realRequests") == expected_real
                      and events[-1].get("outcome") == "succeeded"
                      and len(calls) == 1 and calls[0].get("function_name") == "add_single_task"
                      and "치과" in parameters.get("task_name", "")
                      and parameters.get("date") == "2026-10-27"
                      and parameters.get("time") == "03:00 PM"
                      and parameters.get("category") == "Appointment")
                item = {"mode": mode, "status": status, "passed": ok,
                        "events": events, "real_requests": value.get("realRequests"), "calls": calls,
                        "provider_errors": value.get("providerErrors", [])}
                if status != 200:
                    item["error_code"] = value.get("code")
                    item["error_kind"] = value.get("error") if value.get("error") in ["unauthorized", "probe_failed", "invalid_mode"] else "upstream_or_gateway"
                report["cases"].append(item)
                print(json.dumps(item, ensure_ascii=False), flush=True)
                if not ok:
                    break
            passed = denied_status == 401 and len(report["cases"]) == len(args.modes) and all(x["passed"] for x in report["cases"])
    finally:
        if deploy_attempted:
            try:
                cli("functions", "delete", name, "--project-ref", args.project_ref, "--yes")
                report["probe_deleted"] = True
            except RuntimeError:
                report["probe_deleted"] = False
                passed = False
        report["passed"] = passed
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
