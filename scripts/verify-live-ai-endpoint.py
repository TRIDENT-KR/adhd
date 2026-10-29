#!/usr/bin/env python3
"""Live production endpoint smoke using one disposable staging-bound Auth user.

Creates no calendar tasks and sends no email. Exercises auth, adult/consent gates,
Claude success, cached replay, conflict, quota and denied direct ledger writes.
Deletes only its own generated test user in finally. Credentials stay in memory.
"""
import argparse
import json
from pathlib import Path
import re
import secrets
import subprocess
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_ref")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]{20}", args.project_ref):
        parser.error("Invalid project ref")
    run = subprocess.run(["supabase", "projects", "api-keys", "--project-ref",
                          args.project_ref, "-o", "json"], capture_output=True, text=True, timeout=45)
    if run.returncode:
        raise SystemExit("Project key lookup failed")
    keys = json.loads(run.stdout)
    public_key = next(x["api_key"] for x in keys if x["name"] == "anon")
    admin_keys = [x["api_key"] for x in keys if x.get("type") == "secret"]
    admin_keys += [x["api_key"] for x in keys if x["name"] == "service_role"]
    base = f"https://{args.project_ref}.supabase.co"
    report = {"project_ref": args.project_ref, "environment": "staging", "checks": []}
    user_id = None
    admin_key = None
    all_passed = False

    def http(path, body=None, token=None, api_key=public_key, method="POST"):
        headers = {"apikey": api_key, "Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=45)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            try:
                value = json.loads(raw) if raw else {}
            except ValueError:
                value = {}
            return response.status, value, response.headers.get("X-Mora-AI-Provider")

    def check(name, ok, **evidence):
        item = {"name": name, "passed": bool(ok), **evidence}
        report["checks"].append(item)
        print(json.dumps(item, ensure_ascii=False), flush=True)
        if not ok:
            raise RuntimeError(name + " failed")

    endpoint = "/functions/v1/analyze-task"
    payload = {"requestId": str(uuid.uuid4()), "aiConsentVersion": "2",
               "text": "내일 오후 3시 치과 예약 추가해줘", "currentTime": "2026-10-26 10:00", "language": "ko"}
    email = f"mora-deploy-{uuid.uuid4().hex}@example.invalid"
    password = secrets.token_urlsafe(40)
    try:
        status, value, _ = http(endpoint, payload)
        check("unauthenticated_rejected", status == 401, status=status)
        for candidate in admin_keys:
            status, user, _ = http("/auth/v1/admin/users", {
                "email": email, "password": password, "email_confirm": True,
                "app_metadata": {"mora_environment": "staging", "mora_test": "deploy-smoke-20261026"},
            }, token=candidate, api_key=candidate)
            if status in (200, 201):
                user_id = user.get("id") or user.get("user", {}).get("id")
                admin_key = candidate
                break
            if status not in (401, 403):
                break
        check("disposable_user_created", user_id is not None, status=status)
        status, session, _ = http("/auth/v1/token?grant_type=password", {"email": email, "password": password})
        token = session.get("access_token")
        check("test_user_authenticated", status == 200 and bool(token), status=status)
        check("staging_claim", session.get("user", {}).get("app_metadata", {}).get("mora_environment") == "staging")

        status, value, _ = http(endpoint, payload, token)
        check("adult_gate", status == 403 and value.get("error", {}).get("code") == "adult_eligibility_required", status=status)
        status, value, _ = http("/rest/v1/rpc/accept_adult_eligibility", {"p_policy_version": "adult-v1"}, token)
        check("synthetic_adult_attestation", status == 200 and value.get("eligible") is True, status=status)
        no_consent = {k: v for k, v in payload.items() if k != "aiConsentVersion"}
        status, value, _ = http(endpoint, no_consent, token)
        check("consent_v2_gate", status == 403 and value.get("error", {}).get("code") == "ai_consent_required", status=status)

        for rpc, body in [
            ("mora_reserve_ai_analysis", {"p_request_id": str(uuid.uuid4()), "p_input_hash": "0" * 64}),
            ("mora_reserve_ai_analysis_v2", {"p_user_id": user_id, "p_request_id": str(uuid.uuid4()), "p_input_hash": "0" * 64}),
        ]:
            status, value, _ = http("/rest/v1/rpc/" + rpc, body, token)
            check("client_cannot_call_" + rpc, status in (401, 403) and value.get("code") == "42501", status=status)

        first_result = None
        for index, (language, text) in enumerate([
            ("ko", payload["text"]),
            ("en", "Add a dentist appointment tomorrow at 3 PM."),
            ("ja", "明日の午後3時に歯医者の予定を追加して。"),
        ]):
            current = {**payload, "language": language, "text": text}
            if index:
                current["requestId"] = str(uuid.uuid4())
            status, value, provider = http(endpoint, current, token)
            calls = value.get("calls", [])
            params = calls[0].get("parameters", {}) if len(calls) == 1 else {}
            quota = value.get("quota", {})
            valid = (status == 200 and provider == "claude" and len(calls) == 1
                     and calls[0].get("function_name") == "add_single_task"
                     and params.get("category") == "Appointment" and params.get("date") == "2026-10-27"
                     and params.get("time") == "03:00 PM" and quota.get("used") == index + 1
                     and quota.get("reserved") == 0 and quota.get("remaining") == 2 - index)
            check("claude_" + language, valid, status=status, provider=provider,
                  quota=quota, calls=calls, error_code=value.get("error", {}).get("code"))
            if index == 0:
                first_result = value
                status, replay, source = http(endpoint, payload, token)
                check("cached_replay_no_second_charge", status == 200 and source == "cache" and replay == first_result,
                      status=status, provider=source, quota=replay.get("quota"))
                status, value, _ = http(endpoint, {**payload, "text": "내일 오후 4시 치과 예약 추가해줘"}, token)
                check("same_id_different_input_rejected", status == 409 and value.get("error", {}).get("code") == "request_conflict", status=status)
        status, value, provider = http(endpoint, {**payload, "requestId": str(uuid.uuid4())}, token)
        check("fourth_free_analysis_rejected", status == 429 and value.get("error", {}).get("code") == "quota_exhausted" and provider is None, status=status)
        all_passed = True
    except Exception as error:
        report["failure_type"] = type(error).__name__
    finally:
        if user_id and admin_key:
            status, _, _ = http("/auth/v1/admin/users/" + user_id, token=admin_key, api_key=admin_key, method="DELETE")
            report["test_user_deleted"] = status in (200, 204)
            status, _, _ = http("/auth/v1/admin/users/" + user_id, token=admin_key, api_key=admin_key, method="GET")
            report["test_user_absent"] = status == 404
            all_passed = all_passed and report["test_user_deleted"] and report["test_user_absent"]
        report["passed"] = all_passed
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
