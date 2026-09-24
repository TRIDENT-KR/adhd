#!/usr/bin/env bash
# 출시 전 서버 점검 — 읽기 전용. 아무것도 배포하거나 바꾸지 않는다.
# 릴리스 QA(2026-09-24)의 QA-001·002·003·004·005 서버 조건을 한 번에 확인한다.
#
#   scripts/release-preflight.sh              # Config.plist의 프로젝트
#   scripts/release-preflight.sh <project-ref>
#   scripts/release-preflight.sh --with-db    # 로컬 PostgreSQL 원장 검사까지
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

WITH_DB=0
REF=""
for arg in "$@"; do
  case "$arg" in
    --with-db) WITH_DB=1 ;;
    *) REF="$arg" ;;
  esac
done
if [[ -z "$REF" ]]; then
  URL=$(/usr/libexec/PlistBuddy -c 'Print :SUPABASE_URL' ADHD/Config.plist 2>/dev/null || true)
  REF=$(sed -E 's#^https://([^.]+)\.supabase\.co.*#\1#' <<<"$URL")
fi
if [[ -z "$REF" ]]; then
  echo "프로젝트 ref를 찾지 못했습니다. ADHD/Config.plist를 확인하거나 ref를 인자로 주세요." >&2
  exit 2
fi

FUNCTIONS=(analyze-task delete-account storekit-sync app-store-notifications)
REQUIRED_SECRETS=(GEMINI_API_KEY APPLE_CLIENT_ID APPLE_CLIENT_SECRET DELETION_STATUS_SECRET)
FAILS=0
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mora-preflight.XXXXXX")
pass() { printf '  ✅ %s\n' "$1"; }
fail() { printf '  ❌ %s\n     → %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }

echo "대상 프로젝트: $REF"

echo
echo "[1] 프로젝트 상태 (QA-001)"
STATUS=$(supabase projects list -o json 2>/dev/null |
  json "print(next((p.get('status','') for p in d if p.get('ref', p.get('id'))=='$REF'), 'NOT_FOUND'))")
if [[ "$STATUS" == "ACTIVE_HEALTHY" ]]; then
  pass "프로젝트 ACTIVE_HEALTHY"
else
  fail "프로젝트 상태: ${STATUS:-조회 실패}" "Supabase 대시보드에서 프로젝트를 Restore하거나 출시용 프로젝트로 Config.plist를 바꾸세요."
fi
if python3 -c "import socket; socket.gethostbyname('$REF.supabase.co')" 2>/dev/null; then
  pass "$REF.supabase.co DNS 조회"
else
  fail "$REF.supabase.co DNS 조회 실패" "프로젝트가 비활성이면 복구 후 몇 분 뒤 다시 확인하세요."
fi

echo
echo "[2] Secret 이름 (QA-004) — 값은 읽지 않음"
SECRETS=$(supabase secrets list --project-ref "$REF" -o json 2>/dev/null | json "print(' '.join(s.get('name','') for s in d))")
for name in "${REQUIRED_SECRETS[@]}"; do
  if [[ " $SECRETS " == *" $name "* ]]; then
    pass "$name"
  else
    fail "$name 없음" "supabase secrets set $name=... --project-ref $REF"
  fi
done

echo
echo "[3] 배포된 함수가 로컬 코드와 맞는지 (QA-002·003·004·005)"
DEPLOYED=$(supabase functions list --project-ref "$REF" -o json 2>/dev/null || echo "[]")
for fn in "${FUNCTIONS[@]}"; do
  info=$(json "f=next((x for x in d if x.get('slug')=='$fn'), None); print('' if f is None else f\"{f.get('version')} {int(f.get('updated_at',0))//1000} {str(f.get('verify_jwt')).lower()}\")" <<<"$DEPLOYED")
  if [[ -z "$info" ]]; then
    fail "$fn 미배포" "supabase functions deploy $fn --project-ref $REF"
    continue
  fi
  read -r version deployed_at verify_jwt <<<"$info"
  local_at=$(git log -1 --format=%ct -- "supabase/functions/$fn" supabase/functions/_shared 2>/dev/null || echo 0)
  expected_jwt=$(awk -v s="[functions.$fn]" '$0==s{f=1;next} /^\[/{f=0} f&&/^verify_jwt/{print $3}' supabase/config.toml)
  if (( deployed_at < ${local_at:-0} )); then
    fail "$fn v$version 배포본이 로컬 커밋보다 오래됨" "supabase functions deploy $fn --project-ref $REF"
  elif [[ -n "$expected_jwt" && "$verify_jwt" != "$expected_jwt" ]]; then
    fail "$fn verify_jwt=$verify_jwt (config.toml은 $expected_jwt)" "config.toml을 반영해 다시 배포하세요."
  else
    pass "$fn v$version (verify_jwt=$verify_jwt)"
  fi
done

echo
echo "[4] 로컬 테스트"
DENO_TESTS=$(find supabase/functions supabase/tests -name '*_test.ts' -not -path '*/test/*' -not -path '*/eval/*' | sort)
# shellcheck disable=SC2086
if deno test -A --quiet $DENO_TESTS >"$LOG_DIR/deno.log" 2>&1; then
  pass "Deno 테스트 $(grep -oE '[0-9]+ passed' "$LOG_DIR/deno.log" | tail -1)"
else
  fail "Deno 테스트 실패" "로그: $LOG_DIR/deno.log"
fi
if (( WITH_DB )); then
  if python3 supabase/tests/db/storekit_db_check.py >"$LOG_DIR/db.log" 2>&1; then
    pass "DB 원장 검사 $(tail -1 "$LOG_DIR/db.log")"
  else
    fail "DB 원장 검사 실패" "로그: $LOG_DIR/db.log"
  fi
fi

echo
if (( FAILS == 0 )); then
  echo "모든 점검 통과."
  exit 0
fi
cat <<EOF
실패 $FAILS건. 아래 순서로 직접 실행한 뒤 이 스크립트를 다시 돌리세요.
  1. supabase link --project-ref $REF
  2. supabase db push                  # migration 202608040001, 202609240001 적용 (DB 비밀번호 필요)
  3. supabase secrets set APPLE_CLIENT_ID=... APPLE_CLIENT_SECRET=... DELETION_STATUS_SECRET=... --project-ref $REF
  4. supabase functions deploy ${FUNCTIONS[*]} --project-ref $REF
  5. App Store Connect → 앱 → App 정보 → App Store 서버 알림 (버전 2)
     Production·Sandbox URL: https://$REF.supabase.co/functions/v1/app-store-notifications
EOF
exit 1
