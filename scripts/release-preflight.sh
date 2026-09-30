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
if python3 scripts/verify-deployed-functions.py "$REF"; then
  pass "4개 함수의 실제 배포 소스와 gateway 설정 일치"
else
  fail "배포 소스 또는 gateway 불일치" "각 함수를 개별 배포한 뒤 실제 소스를 다시 확인하세요. 버전/날짜만으로 완료 판정하지 않습니다.
       analyze-task만 다르다면 성인 확인 gate가 아직 안 올라간 상태일 수 있습니다. supabase/ADULT_ELIGIBILITY.md 순서(migration → 호환 앱 → gate)를 먼저 확인하세요."
fi

echo
echo "[4] Migration 적용 이력"
LINKED_REF=$(cat supabase/.temp/project-ref 2>/dev/null || true)
if [[ "$LINKED_REF" != "$REF" ]]; then
  fail "DB 연결 프로젝트와 점검 대상이 다름" "supabase link --project-ref $REF 실행 후 다시 점검하세요."
elif supabase migration list --linked >"$LOG_DIR/migrations.log" 2>&1; then
  if python3 - "$LOG_DIR/migrations.log" <<'PY_MIGRATIONS'
import pathlib, sys
rows = [line.split('|') for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if '|' in line]
remote = {row[1].strip() for row in rows if len(row) >= 2}
missing = [p.name.split('_')[0] for p in pathlib.Path('supabase/migrations').glob('*.sql') if p.name.split('_')[0] not in remote]
if missing:
    print('미적용 migration: ' + ', '.join(missing))
    sys.exit(1)
PY_MIGRATIONS
  then
    pass "모든 migration 원격 적용 이력 확인"
  else
    fail "미적용 migration 존재" "supabase db push 실행 후 다시 확인하세요."
  fi
else
  fail "migration 이력 조회 실패" "DB 연결을 확인하세요. 로그: $LOG_DIR/migrations.log"
fi

echo
echo "[5] 로컬 테스트"
# rg가 없는 맥에서도 같은 목록이 나오도록 find를 쓴다.
DENO_TESTS=$(find supabase/functions supabase/tests -name '*_test.ts' -not -path '*/test/*' -not -path '*/eval/*' | sort)
# shellcheck disable=SC2086
if deno test --config supabase/deno.json --allow-read --allow-env=APPLE_BUNDLE_ID --quiet $DENO_TESTS >"$LOG_DIR/deno.log" 2>&1; then
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
실패 ${FAILS}건. 아래 순서로 직접 실행한 뒤 이 스크립트를 다시 돌리세요.
  1. supabase link --project-ref $REF
  2. supabase db push                  # 보안·구독·보존 작업 migration 적용 (DB 비밀번호 필요)
  3. supabase secrets set APPLE_CLIENT_ID=... APPLE_CLIENT_SECRET=... DELETION_STATUS_SECRET=... --project-ref $REF
  4. 각 함수를 개별 배포: supabase functions deploy <함수명> --no-verify-jwt --use-api --project-ref $REF
     ⚠️ analyze-task는 성인 확인 migration 적용과 호환 앱 빌드 확인이 끝난 뒤에만 배포합니다.
        먼저 올리면 확인 화면이 없는 이전 빌드의 AI가 막힙니다. (supabase/ADULT_ELIGIBILITY.md)
  5. App Store Connect → 앱 → App 정보 → App Store 서버 알림 (버전 2)
     Production·Sandbox URL: https://$REF.supabase.co/functions/v1/app-store-notifications
EOF
exit 1
