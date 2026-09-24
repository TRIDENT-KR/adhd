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
             grace="null", revoked="null", role="service_role"):
    return sql(
        "SELECT public.mora_storekit_apply_transaction("
        f"{q(user)}, {q(mode)}, {q(env)}, {q(original)}, {q(transaction)}, {q(token)}, "
        f"'com.TRIDENT.ADHD.monthly', {q(state)}, {purchased}, {expires}, {grace}, {revoked});",
        role=role)


def apply_notification(notification_uuid, kind, original, transaction, token, *, state="active",
                       env="Production", subtype=None, purchased="now() - interval '1 hour'",
                       expires="now() + interval '30 days'", grace="null", revoked="null"):
    return json.loads(sql(
        "SELECT public.mora_storekit_apply_notification("
        f"{q(notification_uuid)}, {q(kind)}, {q(subtype)}, {q(env)}, {q(original)}, {q(transaction)}, "
        f"{q(token)}, {'null' if original is None else chr(39) + 'com.TRIDENT.ADHD.monthly' + chr(39)}, "
        f"{'null' if original is None else q(state)}, {purchased}, {expires}, {grace}, {revoked});",
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


def run():
    for script in [BOOTSTRAP, *MIGRATIONS]:
        p = cluster.psql(script.read_text())
        if p.returncode:
            raise RuntimeError(f"{script.name}: {p.stderr.strip()}")

    # 1. 권한 경계
    a, a_token = new_account()
    denied = sql_error("SELECT public.mora_storekit_apply_transaction("
                       f"'{a}', 'register', 'Production', '1', '1', '{a_token}', "
                       "'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null);",
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
              f"SELECT 1 FROM (SELECT public.mora_storekit_apply_transaction('{b}', 'register', 'Production', "
              f"'1001', '1002', '{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), "
              f"now() + interval '30 days', null, null)) x;", role="service_role"))
    owned = sql_error(f"SELECT public.mora_storekit_apply_transaction('{b}', 'register', 'Production', '1001', "
                      f"'1003', '{b_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), "
                      f"now() + interval '30 days', null, null);", role="service_role")
    check("활성 구독은 다른 계정이 등록할 수 없다", "subscription_owned_by_another_account" in owned)
    check("원 소유자가 살아 있으면 Restore 재귀속도 거부",
          "subscription_owned_by_another_account" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction('{b}', 'rebind', 'Production', '1001', '1001', "
              f"'{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '30 days', null, null);",
              role="service_role"))
    check("B 계정에는 Pro가 자동 공유되지 않는다", entitlement(b)["isPro"] is False)

    # 4. 환경 규칙
    s, s_token = new_account("staging")
    check("스테이징 계정은 Production 거래를 받지 않는다",
          "apple_environment_not_allowed" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction('{s}', 'register', 'Production', '2001', '2001', "
              f"'{s_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null);",
              role="service_role"))
    check("스테이징 계정은 Sandbox 거래를 받는다",
          result(apply_tx(s, "register", "2001", "2001", s_token, env="Sandbox")) == "bound"
          and entitlement(s, "staging")["isPro"])
    r, r_token = new_account()
    check("운영 계정은 App Review용 Sandbox 거래도 받는다",
          result(apply_tx(r, "register", "3001", "3001", r_token, env="Sandbox")) == "bound")
    check("존재하지 않는 상품 ID는 거부",
          "unknown_product" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction('{r}', 'register', 'Production', '3002', '3002', "
              f"'{r_token}', 'com.TRIDENT.ADHD.lifetime', 'active', now(), now() + interval '1 day', null, null);",
              role="service_role"))

    # 5. 오래된 거래는 상태를 되돌리지 못한다
    apply_tx(a, "register", "1001", "1005", a_token, expires="now() + interval '60 days'")
    apply_tx(a, "register", "1001", "1004", a_token, state="expired", expires="now() - interval '1 day'")
    ent = entitlement(a)
    check("늦게 도착한 옛 거래가 최신 상태를 덮지 않는다", ent["isPro"] and ent["status"] == "active")

    # 6. 계정 삭제 → 재귀속 표식 → 명시적 Restore 1회
    delete_account(a)
    marker = sql("SELECT count(*) FROM mora_prod_private.storekit_rebind_markers "
                 "WHERE original_transaction_id = '1001' AND consumed_at IS NULL;")
    check("삭제된 계정의 활성 구독에 재귀속 표식이 남는다", marker == "1")
    check("삭제 뒤 새 계정의 register(토큰 불일치)는 재귀속이 아니다",
          "app_account_token_mismatch" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction('{b}', 'register', 'Production', '1001', '1005', "
              f"'{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '60 days', null, null);",
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
              f"SELECT public.mora_storekit_apply_transaction('{c}', 'rebind', 'Production', '1001', '1005', "
              f"'{a_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '60 days', null, null);",
              role="service_role"))
    check("모르는 거래의 Restore 재귀속은 거부",
          "rebind_not_eligible" in sql_error(
              f"SELECT public.mora_storekit_apply_transaction('{c}', 'rebind', 'Production', '9999', '9999', "
              f"null, 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null);",
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
    renewed = apply_notification(n1, "DID_RENEW", "1001", "1006", None, expires="now() + interval '90 days'")
    check("갱신 알림은 소유 계정 상태를 갱신한다", renewed["result"] == "updated")
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
              f"SELECT public.mora_storekit_apply_transaction('{h}', 'register', 'Production', '8001', '8001', "
              f"'{h_token}', 'com.TRIDENT.ADHD.monthly', 'active', now(), now() + interval '1 day', null, null);",
              role="service_role"))


if __name__ == "__main__":
    try:
        cluster.start()
        run()
    finally:
        cluster.stop()
    failed = [c for c in checks if not c["passed"]]
    print(f"\n{len(checks) - len(failed)} passed / {len(failed)} failed")
    sys.exit(1 if failed else 0)
