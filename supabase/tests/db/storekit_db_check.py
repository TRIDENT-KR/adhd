"""StoreKit 서버 원장 통합 검사 (QA-003).

일회용 PostgreSQL 클러스터를 임시 폴더에 만들고, Auth 최소 stub 위에 전체
migration을 적용한 뒤 구매·복원·알림 규칙을 검사한다. 원격 서버에는 닿지 않는다.

    python3 supabase/tests/db/storekit_db_check.py

PG_BIN 환경 변수로 initdb/pg_ctl/psql 위치를 지정할 수 있다 (기본: PATH).
"""
import concurrent.futures
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = sorted((ROOT / "migrations").glob("*.sql"))
BOOTSTRAP = pathlib.Path(__file__).with_name("auth_stub.sql")
PG_BIN = os.environ.get("PG_BIN", "")
# macOS에서 LC_ALL이 없으면 postmaster가 시작 중 멀티스레드 오류로 멈춘다.
PG_ENV = {**os.environ, "LC_ALL": "C", "LANG": "C"}


def pg(tool):
    return os.path.join(PG_BIN, tool) if PG_BIN else tool


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Cluster:
    def __init__(self):
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix="mora-storekit-db-"))
        self.data = self.dir / "data"
        self.sock = self.dir / "sock"
        self.sock.mkdir()
        self.port = free_port()

    def start(self):
        subprocess.run([pg("initdb"), "-U", "postgres", "--auth=trust", "--locale=C", "--encoding=UTF8",
                        "-D", str(self.data)], check=True, capture_output=True, env=PG_ENV)
        subprocess.run([pg("pg_ctl"), "-D", str(self.data), "-l", str(self.dir / "pg.log"), "-w", "start",
                        "-o", f"-k {self.sock} -p {self.port} -c listen_addresses=''"],
                       check=True, capture_output=True, env=PG_ENV)

    def stop(self):
        subprocess.run([pg("pg_ctl"), "-D", str(self.data), "-m", "fast", "stop"], capture_output=True, env=PG_ENV)
        shutil.rmtree(self.dir, ignore_errors=True)

    def psql(self, script):
        return subprocess.run(
            [pg("psql"), "-X", "-qAt", "-h", str(self.sock), "-p", str(self.port), "-U", "postgres",
             "-d", "postgres", "-v", "ON_ERROR_STOP=1"],
            input=script, text=True, capture_output=True)


cluster = Cluster()
checks = []


def sql(query, user=None, role=None, environment="production"):
    prefix = ""
    if role or user:
        claims = {"role": role or "authenticated", "app_metadata": {"mora_environment": environment}}
        if user:
            claims["sub"] = user
        prefix = f"SET ROLE {role or 'authenticated'}; SET request.jwt.claims = '{json.dumps(claims)}';"
    p = cluster.psql(prefix + query)
    if p.returncode:
        raise RuntimeError(p.stderr.strip())
    return p.stdout.strip()


def sql_error(query, **kwargs):
    try:
        sql(query, **kwargs)
    except RuntimeError as error:
        return str(error)
    return ""


def check(name, condition):
    checks.append({"name": name, "passed": bool(condition)})
    print(("PASS " if condition else "FAIL ") + name, flush=True)


def new_account(environment="production"):
    user = str(uuid.uuid4())
    sql(f"INSERT INTO auth.users VALUES ('{user}', '{{\"mora_environment\":\"{environment}\"}}');")
    token = sql("SELECT public.mora_get_app_account_token();", user=user, environment=environment)
    return user, token


def entitlement(user, environment="production"):
    return json.loads(sql("SELECT public.mora_get_entitlement();", user=user, environment=environment))


def q(value):
    return "null" if value is None else f"'{value}'"


def apply_tx(user, mode, original, transaction, token, *, state="active", env="Production",
             purchased="now() - interval '1 hour'", expires="now() + interval '30 days'",
             grace="null", revoked="null", signed="clock_timestamp()", role="service_role"):
    return sql(
        "SELECT public.mora_storekit_apply_transaction_v2("
        f"{q(user)}, {q(mode)}, {q(env)}, {q(original)}, {q(transaction)}, {q(token)}, "
        f"'com.TRIDENT.ADHD.monthly', {q(state)}, {purchased}, {expires}, {grace}, {revoked}, {signed});",
        role=role)


def apply_notification(notification_uuid, kind, original, transaction, token, *, state="active",
                       env="Production", subtype=None, purchased="now() - interval '1 hour'",
                       expires="now() + interval '30 days'", grace="null", revoked="null", signed="clock_timestamp()"):
    return json.loads(sql(
        "SELECT public.mora_storekit_apply_notification_v2("
        f"{q(notification_uuid)}, {q(kind)}, {q(subtype)}, {q(env)}, {q(original)}, {q(transaction)}, "
        f"{q(token)}, {'null' if original is None else chr(39) + 'com.TRIDENT.ADHD.monthly' + chr(39)}, "
        f"{'null' if original is None else q(state)}, {purchased}, {expires}, {grace}, {revoked}, {signed});",
        role="service_role"))


def result(raw):
    return json.loads(raw)["result"]


def delete_account(user):
    request_id, token_hash = str(uuid.uuid4()), uuid.uuid4().hex * 2
    args = f"'{request_id}', '{token_hash}'"
    sql(f"SELECT mora_begin_account_deletion('{user}', {args});", role="service_role")
    sql(f"SELECT mora_claim_account_deletion({args});", role="service_role")
    sql(f"SELECT mora_mark_account_deletion_apple_revoked({args});", role="service_role")
    sql(f"SELECT mora_purge_account_deletion_data({args});", role="service_role")
    sql(f"DELETE FROM auth.users WHERE id = '{user}';")
    sql(f"SELECT mora_complete_account_deletion({args});", role="service_role")


def capture_error(action):
    try:
        action()
    except RuntimeError as error:
        return str(error)
    return ""


def binding(original):
    return json.loads(sql("SELECT row_to_json(b) FROM mora_prod_private.storekit_transaction_bindings b "
                          f"WHERE apple_environment = 'Production' AND original_transaction_id = '{original}';"))


def adult_eligibility_checks():
    accepted = {"eligible": True, "policyVersion": "adult-v1"}
    absent = {"eligible": False, "policyVersion": "adult-v1"}
    accept = "SELECT public.accept_adult_eligibility('adult-v1');"
    get = "SELECT public.get_adult_eligibility();"
    user, token = new_account()
    other, _ = new_account()
    count = f"SELECT count(*) FROM mora_internal.adult_eligibility WHERE user_id='{user}';"
    check("성인 확인: 신규 계정은 현재 정책 버전과 eligible=false를 받는다",
          json.loads(sql(get, user=user)) == absent and sql(count) == "0")
    check("성인 확인: anon과 service role은 자기확인 RPC에 접근할 수 없다",
          all("permission denied" in sql_error(query, role=role)
              for role in ["anon", "service_role"] for query in [accept, get]))
    check("성인 확인: authenticated 역할도 인증 UID가 없으면 거부한다",
          all("unauthorized" in sql_error(query, role="authenticated") for query in [accept, get]))
    check("성인 확인: 거절 값·빈 값·알 수 없는 버전은 기록되지 않는다",
          all("unsupported_adult_policy_version" in sql_error(
              f"SELECT public.accept_adult_eligibility({value});", user=user)
              for value in ["null", "''", "'false'", "'declined'", "'adult-v0'", "'adult-v2'", "' adult-v1 '"])
          and sql(count) == "0")
    check("성인 확인: 호출자가 다른 사용자 ID를 전달할 수 없다",
          "does not exist" in sql_error(
              f"SELECT public.accept_adult_eligibility(p_policy_version => 'adult-v1', p_user_id => '{other}');",
              user=user))
    check("성인 확인: 명시적인 현재 정책 자기확인만 본인 계정에 저장한다",
          json.loads(sql(accept, user=user)) == accepted
          and json.loads(sql(get, user=user)) == accepted
          and json.loads(sql(get, user=other)) == absent)
    timestamp = sql(f"SELECT accepted_at FROM mora_internal.adult_eligibility WHERE user_id='{user}';")
    sql(accept, user=user)
    check("성인 확인: 재시도는 최초 확인 시각을 변경하지 않는다",
          timestamp == sql(f"SELECT accepted_at FROM mora_internal.adult_eligibility WHERE user_id='{user}';"))
    check("성인 확인: 스키마는 UID·정책 버전·확인 시각 3개만 보관한다",
          sql("SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns "
              "WHERE table_schema='mora_internal' AND table_name='adult_eligibility';")
          == "user_id,policy_version,accepted_at")
    check("성인 확인: RLS 활성화, 앱·anon·service의 직접 읽기/쓰기는 금지한다",
          sql("SELECT relrowsecurity FROM pg_class WHERE oid='mora_internal.adult_eligibility'::regclass;") == "t"
          and all("permission denied" in sql_error(query, user=user, role=role)
                  for role in ["authenticated", "anon", "service_role"]
                  for query in ["SELECT * FROM mora_internal.adult_eligibility;",
                                f"INSERT INTO mora_internal.adult_eligibility(user_id,policy_version) VALUES ('{other}','adult-v1');"]))
    sql(f"UPDATE mora_internal.adult_eligibility SET policy_version='adult-v0', accepted_at='2000-01-01' WHERE user_id='{user}';")
    check("성인 확인: 저장된 구버전은 승인되지 않으며 재확인이 필요하다",
          json.loads(sql(get, user=user)) == absent
          and json.loads(sql(accept, user=user)) == accepted
          and sql(f"SELECT (accepted_at > '2000-01-02')::text FROM mora_internal.adult_eligibility WHERE user_id='{user}';") == "true")
    check("성인 확인: RPC 조회·수락은 AI 사용량이나 분석 요청을 생성하지 않는다",
          sql(f"SELECT (SELECT count(*) FROM mora_prod_private.ai_daily_quota WHERE user_id='{user}') + "
              f"(SELECT count(*) FROM mora_prod_private.ai_analysis_requests WHERE user_id='{user}');") == "0")
    check("성인 확인: 환경 claim 변경으로 기존 계정 경계를 바꿀 수 없다",
          all("environment_binding_mismatch" in sql_error(query, user=user, environment="staging")
              for query in [get, accept]))

    request_id, token_hash = str(uuid.uuid4()), uuid.uuid4().hex * 2
    args = f"'{request_id}', '{token_hash}'"
    sql(f"SELECT mora_begin_account_deletion('{user}', {args});", role="service_role")
    check("성인 확인: 삭제 진행 중 조회·재수락은 거부한다",
          all("account_deletion_pending" in sql_error(query, user=user) for query in [get, accept]))
    sql(f"SELECT mora_claim_account_deletion({args});", role="service_role")
    sql(f"SELECT mora_mark_account_deletion_apple_revoked({args});", role="service_role")
    sql(f"SELECT mora_purge_account_deletion_data({args});", role="service_role")
    check("성인 확인: Auth 삭제를 기다리는 데이터 purge 단계에서 이미 기록이 삭제된다",
          sql(count) == "0" and sql(f"SELECT count(*) FROM auth.users WHERE id='{user}';") == "1")
    sql(f"DELETE FROM auth.users WHERE id='{user}';")
    sql(f"SELECT mora_complete_account_deletion({args});", role="service_role")
    direct, _ = new_account()
    sql(accept, user=direct)
    sql(f"DELETE FROM auth.users WHERE id='{direct}';")
    check("성인 확인: 직접 Auth 삭제도 cascade로 별도 보관 없이 기록을 지운다",
          sql(f"SELECT count(*) FROM mora_internal.adult_eligibility WHERE user_id='{direct}';") == "0")

    # Restore/management is deliberately available without adult self-attestation.
    # Registration syncs a transaction already charged by Apple; it is not a new
    # purchase API. The compatible app gates a new purchase before StoreKit.
    owner, owner_token = new_account()
    apply_tx(owner, "register", "990100", "990101", owner_token)
    check("성인 미확인 계정도 기존 거래 동기화와 구독 권한 조회는 가능하다",
          json.loads(sql(get, user=owner)) == absent and entitlement(owner)["isPro"])
    delete_account(owner)
    restore_user, _ = new_account()
    check("성인 미확인 계정도 명시적 구독 복원을 할 수 있다",
          result(apply_tx(restore_user, "rebind", "990100", "990101", owner_token)) == "rebound"
          and entitlement(restore_user)["isPro"]
          and json.loads(sql(get, user=restore_user)) == absent)
    delete_account(restore_user)
    check("성인 미확인 계정도 계정 탈퇴를 완료할 수 있다",
          sql(f"SELECT count(*) FROM auth.users WHERE id='{restore_user}';") == "0")


def evidence_and_retention_checks():
    # Stable timestamps let us test actual ordering rather than the test runner's speed.
    times = json.loads(sql("SELECT json_build_object("
                           "'purchase', now() - interval '2 days', 'old', now() - interval '3 hours', "
                           "'grace', now() - interval '2 hours', 'refund', now() - interval '1 hour', "
                           "'after', now() - interval '30 minutes', 'later', now() - interval '10 minutes', "
                           "'expiry', now() + interval '30 days');"))
    t = {key: q(value) for key, value in times.items()}
    user, token = new_account()
    def tx(original, transaction, **kwargs):
        defaults = dict(purchased=t['purchase'], expires=t['expiry'], signed=t['after'])
        defaults.update(kwargs)
        return apply_tx(user, 'register', original, transaction, token, **defaults)
    def event(kind, original, transaction, **kwargs):
        defaults = dict(purchased=t['purchase'], expires=t['expiry'], signed=t['refund'])
        defaults.update(kwargs)
        return apply_notification(str(uuid.uuid4()), kind, original, transaction, token, **defaults)

    # AR-03: real grace has an expired original transaction, not a future expiry.
    tx('9100', '9101', signed=t['old'], expires="now() - interval '4 hours'")
    event('DID_FAIL_TO_RENEW', '9100', '9101', state='grace', subtype='GRACE_PERIOD',
          signed=t['grace'], expires="now() - interval '4 hours'", grace="now() + interval '3 days'")
    grace_deadline = binding('9100')['grace_expires_at']
    tx('9100', '9101', state='expired', expires="now() - interval '4 hours'")
    check('AR-03: 앱 currentEntitlements 재등록이 실제 유예를 만료시키지 않는다',
          binding('9100')['state'] == 'grace' and binding('9100')['grace_expires_at'] == grace_deadline)
    event('DID_CHANGE_RENEWAL_STATUS', '9100', '9101', state='expired', signed=t['after'])
    check('갱신 정보 없는 일반 알림은 유예 종료 증거가 아니다', binding('9100')['state'] == 'grace')
    event('GRACE_PERIOD_EXPIRED', '9100', '9101', state='expired', signed=t['later'])
    check('더 최신 유예 종료 알림은 권한을 끝낸다', binding('9100')['state'] == 'expired')

    # AR-04: same transaction, different evidence channels and timestamps.
    tx('9200', '9201', signed=t['old'])
    event('REFUND', '9200', '9201', state='refunded', revoked=t['refund'])
    tx('9200', '9201', signed=t['old'])
    check('AR-04: 환불 전 JWS 재전송은 환불을 되돌리지 않는다', binding('9200')['state'] == 'refunded')
    tx('9200', '9201', signed=t['after'])
    check('더 새로 서명된 거래-only JWS도 환불 철회를 증명하지 않는다', binding('9200')['state'] == 'refunded')
    event('DID_RENEW', '9200', '9201', signed=t['old'])
    check('다른 UUID의 지연 알림도 signedDate가 오래되면 무시', binding('9200')['state'] == 'refunded')
    event('REFUND_REVERSED', '9200', '9201', signed=t['refund'])
    check('같은 signedDate 환불 철회는 환불을 뒤집지 않는다', binding('9200')['state'] == 'refunded')
    event('DID_CHANGE_RENEWAL_STATUS', '9200', '9201', signed=t['after'])
    check('단순 갱신 설정 변경은 환불 철회가 아니다', binding('9200')['state'] == 'refunded')
    event('REFUND_REVERSED', '9200', '9201', signed=t['after'])
    check('더 최신 REFUND_REVERSED는 유효한 구독을 복원한다',
          binding('9200')['state'] == 'active' and binding('9200')['revoked_at'] is None)
    event('REFUND', '9200', '9201', state='refunded', signed=t['after'], revoked=t['after'])
    check('동일 시각 충돌은 보수적으로 환불 상태를 택한다', binding('9200')['state'] == 'refunded')
    # A genuine newer transaction can restore the service. A later-signed refund
    # for the previous renewal cannot cancel this new purchase.
    tx('9200', '9202', purchased="now() - interval '45 minutes'", signed="now() - interval '40 minutes'")
    check('환불 뒤 새 구매는 이전 환불 알림보다 서명이 일러도 새 purchaseDate로 인정',
          binding('9200')['latest_transaction_id'] == '9202' and binding('9200')['state'] == 'active')
    event('REFUND', '9200', '9201', state='refunded', signed=t['later'], revoked=t['later'])
    check('옛 거래 환불 알림이 더 늦게 서명돼도 새 갱신을 취소하지 않는다',
          binding('9200')['latest_transaction_id'] == '9202' and binding('9200')['state'] == 'active')
    current = binding('9200')
    tx('9200', '9299', state='expired', purchased=q(current['purchased_at']), signed=t['later'])
    check('다른 거래 ID에 같은 purchaseDate면 순서를 추측하지 않는다', binding('9200')['latest_transaction_id'] == '9202')
    tx('9200', '9203', purchased="now() - interval '5 minutes'", signed='clock_timestamp()')
    check('다음 정상 구매는 계속 반영된다', binding('9200')['latest_transaction_id'] == '9203')

    # Upgrade compatibility: legacy rows have no invented signed timestamp.
    tx('9300', '9301', signed=t['old'])
    sql("UPDATE mora_prod_private.storekit_transaction_bindings SET state='grace', "
        "grace_expires_at=now()+interval '1 day', evidence_source='legacy', evidence_signed_at=null "
        "WHERE original_transaction_id='9300';")
    tx('9300', '9301', state='expired')
    check('기존 배포의 시각 없는 grace 원장도 앱 요청으로 훼손되지 않는다', binding('9300')['state'] == 'grace')
    sql("UPDATE mora_prod_private.storekit_transaction_bindings SET state='refunded' WHERE original_transaction_id='9300';")
    tx('9300', '9301')
    check('기존 배포의 환불 원장도 앱 요청으로 부활하지 않는다', binding('9300')['state'] == 'refunded')
    event('REFUND_REVERSED', '9300', '9301', signed=t['later'])
    check('기존 원장도 서명된 명시적 환불 철회는 수용한다', binding('9300')['state'] == 'active')

    for invalid in ['null', "'infinity'::timestamptz", "now() + interval '2 minutes'"]:
        check('DB도 signedDate 누락/무한/미래를 거부: ' + invalid,
              'invalid_signed_date' in capture_error(lambda: tx('9400', '9401', signed=invalid)))
    check('DB도 purchaseDate 없는 거래를 거부',
          'invalid_purchase_date' in capture_error(lambda: tx('9400', '9401', purchased='null')))
    legacy = sql_error("SELECT public.mora_storekit_apply_transaction("
                       f"'{user}', 'register', 'Production', '9400', '9401', '{token}', "
                       "'com.TRIDENT.ADHD.monthly', 'active', now(), now()+interval '1 day', null, null);",
                       role='service_role')
    check('이전 Edge RPC는 증거 없는 상태 쓰기를 fail-closed한다', 'storekit_evidence_required' in legacy)

    # A newer purchase under another Mora account must not be granted to the
    # old account merely because its Apple notification beats the app request.
    previous_owner, previous_token = new_account()
    next_owner, next_token = new_account()
    apply_tx(previous_owner, 'register', '9450', '9451', previous_token, state='expired',
             purchased="now()-interval '60 days'", expires="now()-interval '30 days'")
    early_notification = apply_notification(str(uuid.uuid4()), 'SUBSCRIBED', '9450', '9452', next_token)
    check('새 계정 재구매 알림이 먼저 와도 이전 계정에 Pro를 주지 않는다',
          not entitlement(previous_owner)['isPro'] and early_notification['result'] == 'awaiting_account_registration')
    moved = apply_tx(next_owner, 'register', '9450', '9452', next_token)
    check('이른 알림 뒤 명시적 앱 등록은 새 계정으로 정상 이전한다',
          result(moved) == 'transferred' and entitlement(next_owner)['isPro'] and not entitlement(previous_owner)['isPro'])

    # AR-11: original transaction IDs get deletion deadlines, not indefinite rows.
    old_user, old_token = new_account()
    apply_tx(old_user, 'register', '9500', '9501', old_token, expires="now() + interval '1000 days'")
    delete_account(old_user)
    orphan = binding('9500')
    marker = sql("SELECT retain_until::text FROM mora_prod_private.storekit_rebind_markers WHERE original_transaction_id='9500';")
    check('탈퇴 거래 원장은 재연결 표식과 같은 보존기한을 갖는다',
          sql("SELECT (b.retain_until=m.retain_until AND b.retain_until<=b.deleted_at+interval '400 days' "
              "AND b.user_id IS NULL AND b.app_account_token IS NULL)::text "
              "FROM mora_prod_private.storekit_transaction_bindings b JOIN mora_prod_private.storekit_rebind_markers m "
              "USING (apple_environment,original_transaction_id) WHERE b.original_transaction_id='9500';") == 'true')
    apply_notification(str(uuid.uuid4()), 'DID_RENEW', '9500', '9502', None,
                       purchased='now()', expires="now() + interval '1100 days'")
    check('탈퇴 뒤 Apple 갱신 알림은 보존기한을 연장하지 않는다',
          binding('9500')['retain_until'] == orphan['retain_until'])
    inactive_user, inactive_token = new_account()
    apply_tx(inactive_user, 'register', '9600', '9601', inactive_token, state='expired',
             purchased="now() - interval '60 days'", expires="now() - interval '30 days'")
    delete_account(inactive_user)
    check('재연결 대상 아닌 탈퇴 거래는 30일 보존',
          sql("SELECT (retain_until=deleted_at+interval '30 days')::text "
              "FROM mora_prod_private.storekit_transaction_bindings WHERE original_transaction_id='9600';") == 'true')
    rebind_user, _ = new_account()
    apply_tx(rebind_user, 'rebind', '9500', '9502', old_token, purchased='now()', expires="now()+interval '1100 days'")
    check('정상 재연결은 새 계정 원장의 삭제 보존기한을 해제한다',
          binding('9500')['retain_until'] is None and binding('9500')['deleted_at'] is None)

    # Test-only time aging. The production trigger deliberately prevents updates
    # from changing the original deadline; disable it ONLY inside this disposable DB.
    sql("ALTER TABLE mora_prod_private.storekit_transaction_bindings DISABLE TRIGGER storekit_binding_retention; "
        "UPDATE mora_prod_private.storekit_transaction_bindings SET retain_until=now()-interval '1 day' "
        "WHERE original_transaction_id='9600'; "
        "ALTER TABLE mora_prod_private.storekit_transaction_bindings ENABLE TRIGGER storekit_binding_retention;")
    cleanup = json.loads(sql('SELECT public.mora_cleanup_security_data(5000);'))
    check('보존 청소가 탈퇴 원거래 식별자 행을 물리 삭제한다',
          sql("SELECT count(*) FROM mora_prod_private.storekit_transaction_bindings WHERE original_transaction_id='9600';") == '0')
    check('보존 청소가 살아 있는 재연결 원장은 지우지 않는다', binding('9500')['user_id'] == rebind_user)


def run():
    for script in [BOOTSTRAP, *MIGRATIONS]:
        if script.name == '202609300001_mora_storekit_evidence_retention.sql':
            # Actual upgrade fixtures: these rows predate the retention columns
            # and trigger, as in an already deployed database.
            sql("INSERT INTO mora_prod_private.storekit_transaction_bindings "
                "(apple_environment,original_transaction_id,latest_transaction_id,product_id,state,"
                "purchased_at,expires_at,verified_at,updated_at) VALUES "
                "('Production','9800','9801','com.TRIDENT.ADHD.monthly','expired',"
                "now()-interval '90 days',now()-interval '60 days',now()-interval '45 days',now()-interval '45 days'),"
                "('Production','9810','9811','com.TRIDENT.ADHD.monthly','active',"
                "now()-interval '30 days',now()+interval '30 days',now()-interval '1 day',now()-interval '1 day');")
            sql("INSERT INTO mora_prod_private.storekit_rebind_markers "
                "(apple_environment,original_transaction_id,deleted_account_marker,deletion_job_id,eligible_at,retain_until) "
                "VALUES ('Production','9810','legacy-test-marker',gen_random_uuid(),"
                "now()-interval '20 days',now()+interval '60 days');")
        p = cluster.psql(script.read_text())
        if p.returncode:
            raise RuntimeError(f"{script.name}: {p.stderr.strip()}")
    rerun = [cluster.psql(script.read_text()) for script in MIGRATIONS]
    check("migration을 두 번 적용해도 오류가 없다", all(p.returncode == 0 for p in rerun))
    check('기존 재연결 없는 고아 원장은 마지막 기록+30일 기한으로 backfill된다',
          sql("SELECT (deleted_at=updated_at AND retain_until=updated_at+interval '30 days')::text "
              "FROM mora_prod_private.storekit_transaction_bindings WHERE original_transaction_id='9800';") == 'true')
    check('기존 고아 원장은 늦은 알림의 updated_at 대신 실제 삭제 표식 시각을 보존한다',
          sql("SELECT (b.deleted_at=m.eligible_at AND b.retain_until=m.retain_until)::text "
              "FROM mora_prod_private.storekit_transaction_bindings b JOIN mora_prod_private.storekit_rebind_markers m "
              "USING (apple_environment,original_transaction_id) WHERE b.original_transaction_id='9810';") == 'true')

    # 1. 권한 경계
    a, a_token = new_account()
    denied = sql_error("SELECT public.mora_storekit_apply_transaction_v2("
                       f"'{a}', 'register', 'Production', '1', '1', '{a_token}', "
                       "'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null, clock_timestamp());",
                       user=a)
    check("앱 사용자 권한으로는 원장 쓰기 RPC를 호출할 수 없다", "permission denied" in denied)

    # 2. 구매 등록 → Pro
    check("자기 토큰이 붙은 거래를 등록하면 bound", result(apply_tx(a, "register", "1001", "1001", a_token)) == "bound")
    ent = entitlement(a)
    check("등록 뒤 서버 entitlement가 Pro", ent["isPro"] and ent["status"] == "active")
    check("같은 거래 재등록은 멱등(updated)", result(apply_tx(a, "register", "1001", "1001", a_token)) == "updated")

    # 3. 단일 귀속
    b, b_token = new_account()
    check("다른 계정 토큰으로 등록하면 거부",
          "app_account_token_mismatch" in sql_error(
              f"SELECT 1 FROM (SELECT public.mora_storekit_apply_transaction_v2('{b}', 'register', 'Production', "
              f"'1001', '1002', '{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), "
              f"now() + interval '30 days', null, null, clock_timestamp())) x;", role="service_role"))
    owned = sql_error(f"SELECT public.mora_storekit_apply_transaction_v2('{b}', 'register', 'Production', '1001', "
                      f"'1003', '{b_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), "
                      f"now() + interval '30 days', null, null, clock_timestamp());", role="service_role")
    check("활성 구독은 다른 계정이 등록할 수 없다", "subscription_owned_by_another_account" in owned)
    check("원 소유자가 살아 있으면 Restore 재귀속도 거부",
          "subscription_owned_by_another_account" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{b}', 'rebind', 'Production', '1001', '1001', "
              f"'{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '30 days', null, null, clock_timestamp());",
              role="service_role"))
    check("B 계정에는 Pro가 자동 공유되지 않는다", entitlement(b)["isPro"] is False)

    # 4. 환경 규칙
    s, s_token = new_account("staging")
    check("스테이징 계정은 Production 거래를 받지 않는다",
          "apple_environment_not_allowed" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{s}', 'register', 'Production', '2001', '2001', "
              f"'{s_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null, clock_timestamp());",
              role="service_role"))
    check("스테이징 계정은 Sandbox 거래를 받는다",
          result(apply_tx(s, "register", "2001", "2001", s_token, env="Sandbox")) == "bound"
          and entitlement(s, "staging")["isPro"])
    r, r_token = new_account()
    check("운영 계정은 App Review용 Sandbox 거래도 받는다",
          result(apply_tx(r, "register", "3001", "3001", r_token, env="Sandbox")) == "bound")
    check("존재하지 않는 상품 ID는 거부",
          "unknown_product" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{r}', 'register', 'Production', '3002', '3002', "
              f"'{r_token}', 'com.TRIDENT.ADHD.lifetime', 'active', now(), now() + interval '1 day', null, null, clock_timestamp());",
              role="service_role"))

    # 5. 오래된 거래는 상태를 되돌리지 못한다
    apply_tx(a, "register", "1001", "1005", a_token, expires="now() + interval '60 days'")
    apply_tx(a, "register", "1001", "1004", a_token, state="expired", purchased="now() - interval '31 days'", expires="now() - interval '1 day'")
    ent = entitlement(a)
    check("늦게 도착한 옛 거래가 최신 상태를 덮지 않는다", ent["isPro"] and ent["status"] == "active")

    # 6. 계정 삭제 → 재귀속 표식 → 명시적 Restore 1회
    delete_account(a)
    marker = sql("SELECT count(*) FROM mora_prod_private.storekit_rebind_markers "
                 "WHERE original_transaction_id = '1001' AND consumed_at IS NULL;")
    check("삭제된 계정의 활성 구독에 재귀속 표식이 남는다", marker == "1")
    check("삭제 뒤 새 계정의 register(토큰 불일치)는 재귀속이 아니다",
          "app_account_token_mismatch" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{b}', 'register', 'Production', '1001', '1005', "
              f"'{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '60 days', null, null, clock_timestamp());",
              role="service_role"))
    check("명시적 Restore로 새 계정에 1회 재귀속(rebound)",
          result(apply_tx(b, "rebind", "1001", "1005", a_token, expires="now() + interval '60 days'")) == "rebound")
    check("재귀속된 계정은 Pro", entitlement(b)["isPro"])
    stored = sql("SELECT coalesce(app_account_token::text, 'null') FROM mora_prod_private.storekit_transaction_bindings "
                 "WHERE original_transaction_id = '1001';")
    check("삭제된 계정의 토큰을 다시 저장하지 않는다", stored == "null")
    c, _ = new_account()
    check("표식은 한 번만 쓸 수 있다(다른 계정 재시도 거부)",
          "subscription_owned_by_another_account" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{c}', 'rebind', 'Production', '1001', '1005', "
              f"'{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '60 days', null, null, clock_timestamp());",
              role="service_role"))
    check("모르는 거래의 Restore 재귀속은 거부",
          "rebind_not_eligible" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{c}', 'rebind', 'Production', '9999', '9999', "
              f"null, 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null, clock_timestamp());",
              role="service_role"))

    # 7. 만료된 구독을 같은 Apple ID가 다른 계정에서 재구독
    d, d_token = new_account()
    e, e_token = new_account()
    apply_tx(d, "register", "4001", "4001", d_token, purchased="now() - interval '60 days'",
             expires="now() - interval '30 days'", state="expired")
    moved = apply_tx(e, "register", "4001", "4002", e_token)
    check("만료된 구독을 다른 계정에서 새로 사면 그 계정으로 옮겨진다(transferred)",
          result(moved) == "transferred" and entitlement(e)["isPro"])
    check("이전 계정의 권한 기록은 정리된다", entitlement(d)["status"] == "none")

    # 8. 서버 알림
    n1 = str(uuid.uuid4())
    renewed = apply_notification(n1, "DID_RENEW", "1001", "1006", a_token, expires="now() + interval '90 days'")
    check("재연결 후 삭제된 계정의 옛 토큰으로 온 갱신 알림도 새 소유자에게 반영된다", renewed["result"] == "updated")
    check("같은 알림 재전송은 한 번만 반영(duplicate)",
          apply_notification(n1, "DID_RENEW", "1001", "1006", None)["result"] == "duplicate")
    grace = apply_notification(str(uuid.uuid4()), "DID_FAIL_TO_RENEW", "1001", "1007", None, subtype="GRACE_PERIOD",
                               state="grace", expires="now() + interval '91 days'",
                               grace="now() + interval '97 days'")
    ent = entitlement(b)
    check("유예 기간 알림 → grace, Pro 유지", grace["result"] == "updated" and ent["status"] == "grace" and ent["isPro"])
    apply_notification(str(uuid.uuid4()), "EXPIRED", "1001", "1008", None, state="expired",
                       expires="now() + interval '92 days'")
    check("만료 알림 → Pro 해제", entitlement(b)["isPro"] is False)
    apply_notification(str(uuid.uuid4()), "REFUND", "4001", "4002", e_token, state="refunded",
                       revoked="now()", purchased="now() - interval '1 hour'")
    check("환불 알림 → Pro 해제", entitlement(e)["status"] == "refunded" and not entitlement(e)["isPro"])
    f, f_token = new_account()
    bound = apply_notification(str(uuid.uuid4()), "SUBSCRIBED", "5001", "5001", f_token)
    check("앱이 등록 전에 죽어도 알림의 토큰으로 계정에 귀속", bound["result"] == "bound" and entitlement(f)["isPro"])
    unknown = apply_notification(str(uuid.uuid4()), "SUBSCRIBED", "6001", "6001", str(uuid.uuid4()))
    check("주인을 모르는 거래 알림은 무시하고 기록만", unknown["result"] == "ignored_unknown_transaction")
    check("TEST 알림은 기록만", apply_notification(str(uuid.uuid4()), "TEST", None, None, None)["result"] == "recorded")

    # 9. 동시성: 같은 거래를 동시에 등록해도 행은 하나
    g, g_token = new_account()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        outcomes = list(pool.map(lambda _: result(apply_tx(g, "register", "7001", "7001", g_token)), range(6)))
    rows = sql("SELECT count(*) FROM mora_prod_private.storekit_transaction_bindings WHERE original_transaction_id = '7001';")
    check("동시 등록 6회 → bound 1회, 행 1개", outcomes.count("bound") == 1 and rows == "1")

    # 10. 삭제 진행 중 계정은 쓰기 불가
    h, h_token = new_account()
    sql(f"SELECT mora_begin_account_deletion('{h}', '{uuid.uuid4()}', '{uuid.uuid4().hex * 2}');", role="service_role")
    check("삭제 진행 중인 계정은 구매를 등록할 수 없다",
          "account_deletion_pending" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction_v2('{h}', 'register', 'Production', '8001', '8001', "
              f"'{h_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null, clock_timestamp());",
              role="service_role"))


    evidence_and_retention_checks()
    adult_eligibility_checks()

    # 11. Bounded retention must not shrink the 90-day aggregate on repeated runs.
    for duration in [10, 20]:
        sql(f"INSERT INTO mora_prod_private.operational_events "
            "(request_id, event_name, status_code, duration_ms, occurred_at, expires_at) "
            f"VALUES ('{uuid.uuid4()}', 'analysis_succeeded', 200, {duration}, "
            "now() - interval '15 days', now() - interval '1 day');")
    aggregate_query = (
        "SELECT event_count || '|' || total_duration_ms || '|' || max_duration_ms "
        "FROM mora_prod_private.daily_operational_aggregates "
        "WHERE metric_date = ((now() - interval '15 days') AT TIME ZONE 'Asia/Seoul')::date "
        "AND event_name = 'analysis_succeeded' AND status_class = '2xx';"
    )
    sql("SELECT public.mora_cleanup_security_data(1);")
    check("보존 정리 첫 배치가 전체 집계를 만든다", sql(aggregate_query) == "2|30|20")
    sql("SELECT public.mora_cleanup_security_data(1);")
    check("두 번째 배치가 90일 집계를 줄이지 않는다", sql(aggregate_query) == "2|30|20")
    sql("SELECT public.mora_cleanup_security_data(1);")
    check("원본 삭제 완료 뒤에도 집계가 유지된다", sql(aggregate_query) == "2|30|20")


if __name__ == "__main__":
    try:
        cluster.start()
        run()
    finally:
        cluster.stop()
    failed = [c for c in checks if not c["passed"]]
    print(f"\n{len(checks) - len(failed)} passed / {len(failed)} failed")
    sys.exit(1 if failed else 0)
