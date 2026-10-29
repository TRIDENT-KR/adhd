# MORA 출시 전 구현·품질·보안 통합 보고서

작성일: 2026-10-13 KST · 대상: iOS 앱 및 Supabase 백엔드
작업 브랜치: `fix/claude-fallback-release-audit`
보안 검토 기준 커밋: `51c4f464403434608cfc8ab8be18d05e62f402b3`, 수정 결과는 현재 작업 트리 기준

## 1. 판단과 완료 범위

**Claude 우선 → Gemini Flash-Lite 대체 경로를 구현했고, 보안 문제 2건과 앱 오류를 수정했다. 현재 상태는 운영 출시 보류다.** 로컬 검증은 통과했지만 운영 Claude 키·Apple 삭제용 시크릿이 없고, DB 변경과 함수 배포가 남아 있다.

| 요청 | 실행 결과 |
|---|---|
| 받은 Claude API 먼저 사용 | 서버에서 Claude를 먼저 시도하도록 구현. 앱에 API 키를 넣지 않음 |
| 나머지는 Gemini Flash-Lite | Claude 잔액 부족·오류·시간 초과·잘못된 출력 시 자동 대체. Claude 비활성화도 지원 |
| 버그 및 UI/UX 점검 | 루틴 날짜·계정 전환·저장 실패 복구, 과도한 결제 유도, 입력 시트, AI 제공자 동의 수정 |
| 시스템 보안 점검 | AI 원장 권한과 삭제 잠금 순서 문제 수정. 인증·구독·모델 출력·로컬 계정 격리 검토 |
| 오픈소스 Jev 도입 | 후보 저장소를 조사한 뒤 이번 출시에는 추가하지 않기로 판단 |
| 운영 상태 확인 | 연결된 Supabase를 읽기 전용으로 확인. secret은 이름만 조회 |

코드와 문서는 로컬에 반영했다. 운영 DB·함수·secret·결제 설정을 변경하거나 앱을 배포하지 않았다. 커밋·원격 push도 수행하지 않았다. 아래 내용이 이전 문서의 Gemini 단독 구조 설명보다 우선한다.

## 2. AI 호출 구조

```text
iOS: 계정별 AI 동의 v2 + 성인 확인 + 고정 requestId
  → Supabase: JWT 검증 → 성인 확인 → 동의 버전/입력 검증
  → service_role 전용 RPC: 계정별 요청 제한 + 사용량 예약
  → Claude: 최대 8초, 출력 상한 4,096토큰
       ├─ 유효한 결과 → 완료·1회 차감
       └─ 실패/잔액 부족/비정상 출력 → Gemini Flash-Lite
                                          ├─ 유효한 결과 → 완료·1회 차감
                                          └─ 실패 → 예약 해제·재시도 가능한 오류
```

Claude가 성공하면 Gemini를 호출하지 않는다. 두 제공자를 거치더라도 앱의 무료 이용 횟수는 최종 성공에 한 번만 차감한다. 같은 요청 ID와 입력의 재전송은 저장된 결과를 재사용하며, ID에 다른 입력을 끼워 넣으면 거절한다. 이 횟수 정책과 **공급자가 청구하는 API 비용은 다르다.** 시간 초과나 출력 검증 실패도 공급자 비용이 발생할 수 있다.

| 서버 설정 | 기본 동작 |
|---|---|
| `ANTHROPIC_API_KEY` | Claude 사용 키. 미설정이면 Gemini만 사용 |
| `ANTHROPIC_MODEL` | 기본 `claude-haiku-5-5` |
| `ANTHROPIC_ENABLED` | 기본 활성. 문자열 `false`이면 Gemini만 사용 |
| `GEMINI_API_KEY` | 대체 경로를 위한 기존 키 |
| `GEMINI_MODEL` | 기본 `gemini-3.5-flash-lite` |
| `SUPABASE_SERVICE_ROLE_KEY` | 서버 전용 원장 호출에 필요. 클라이언트 포함 금지 |

Haiku는 짧은 일정 명령의 분류·추출·라우팅 용도에 맞춰 선택했다. Gemini는 기존 Flash-Lite 기본값을 유지했다. 확인일의 공식 문서에서 두 모델 ID를 확인했으며, 최신 API에서 폐기된 sampling 인자를 보내지 않도록 했다. 실제 계정의 모델 접근 권한은 아직 검증하지 못했다. [Claude 모델 문서](https://platform.claude.com/docs/en/models/overview), [Haiku 전환 지침](https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide), [Gemini Flash-Lite 문서](https://ai.google.dev/gemini-api/docs/generate-content/whats-new-gemini-3.6)

**받은 크레딧만 쓰고 추가 결제를 피하려면 계정 설정도 필요하다.** 구현은 잔액 조회가 아니라 API 실패에 반응한다. Anthropic 자동 충전이 켜져 있거나 구매 크레딧·후불 결제가 연결되어 있으면 Claude가 계속 성공할 수 있다. 해당 크레딧이 연결된 조직/키인지, 만료일·자동 충전·지출 한도를 운영자가 확인해야 한다. 크레딧 종류와 잔액은 이번 작업에서 확인하지 않았다. 소진 후 확실하게 Gemini 전용으로 전환하려면 `ANTHROPIC_ENABLED=false`를 사용한다. [Anthropic 결제·자동 충전 설명](https://support.claude.com/en/articles/8977456-how-do-i-pay-for-my-claude-api-usage)

입력 본문은 16 KiB, 일정 텍스트는 기존 1,000자, 제공자 응답은 128 KiB로 제한했다. 함수 이름·필드·날짜·시간·값을 기존 허용 목록으로 검증한다. URL은 고정 호스트만 쓰고 리디렉션을 거절하며, 키는 헤더에만 넣는다. 원문 입력·제공자 오류 본문을 로그에 남기지 않는다. Claude 오류 시 짧은 대기 기간은 인스턴스 내부 최적화이며 전역 비용 차단 장치가 아니다.

주요 구현: `supabase/functions/analyze-task/model-router.ts`, `model-config.ts`, `analysis-service.ts`, `index.ts`, `supabase/migrations/202610130001_mora_ai_broker.sql`.

## 3. 수정한 보안 문제

### SEC-01 · 높음 · 클라이언트가 AI 예약·차감 상태를 직접 변경

**기존 문제:** 로그인한 사용자가 자기 요청 UUID로 원장 RPC를 직접 호출할 수 있었다. 모델 요청이 실행되는 동안 예약을 실패 처리하면 예약 횟수를 돌려받아 새로운 유료 모델 요청을 반복할 수 있었다. 성공 결과를 못 받더라도 공급자 비용은 발생할 수 있다. 완료 RPC로 결과 캐시를 임의로 기록할 수 있는 권한도 있었다.

**수정:** 기존 reserve/finalize/fail/event RPC의 클라이언트 권한을 회수했다. 새 `_v2` RPC는 `service_role`만 실행할 수 있고 함수 내부에서도 역할을 검사한다. Edge가 JWT로 확인한 사용자 ID만 전달한다. DB의 원자적 계정별 1분 구간 30회 제한을 추가하여 여러 Edge 인스턴스, 실패 요청, 재시도, Pro 사용자에게도 적용한다.

**검증:** 클라이언트·익명 접근과 사용자 ID 위조 거절, 서버 성공 경로, 예약 중 환불 공격 거절, 중복 완료·캐시 재사용, 무료 4번째 요청 거절, 35개 병렬 요청의 제한 동작을 로컬 PostgreSQL에서 확인했다.

**잔여 범위:** 무료 일일 한도는 성공 횟수 기준이며 정상적인 제공자 실패는 환불된다. 분당 제한은 절대적인 일일 비용 상한이 아니다. 별도의 공급자 지출 한도가 필요하다. 다른 사람의 계정을 직접 조작하는 취약점으로 확인된 것은 아니다.

근거: 기존 `202608040001_mora_security_contracts.sql`의 원장 변경 함수와 authenticated grant. 수정은 새 migration 및 Edge의 관리자 전용 호출 경로에 있다. **로컬 수정 완료, 운영 미반영.**

### SEC-02 · 중간 · Apple 재인증 전 영구적인 계정 잠금 생성

**기존 문제:** 최근 발급된 피해자 Supabase 토큰을 가진 공격자가 잘못된 Apple 코드를 보내도 삭제 작업·계정 잠금이 먼저 생성됐다. 이후 Apple 검증이 실패해도 잠금이 남아 서버 기능을 계속 거부했다. 인증 없는 삭제나 Apple 검증을 우회한 실제 데이터 삭제로 확인된 문제는 아니다.

**수정:** Apple authorization code 교환, ID token 서명·대상·만료·사용자 일치 검증을 먼저 완료한다. 이후에만 삭제 작업을 만들고 잠근다. 토큰 해제와 데이터 삭제는 기록된 작업 안에서 재시도하도록 유지한다. 네트워크 시간 초과와 리디렉션도 제한했다.

**검증:** 잘못된 코드·다른 사용자·다른 audience·만료·잘못된 서명·Apple 네트워크 실패에는 작업 생성·잠금·삭제가 일어나지 않음을 실제 handler의 모의 네트워크 테스트로 확인했다. 정상 순서와 토큰 해제 실패 후 재시도도 검증했다.

**잔여 범위:** 기존 코드로 이미 만들어진 비정상 잠금은 이 변경만으로 없어지지 않는다. 운영 삭제 작업 중 오래된 미완료 건을 권한 있는 운영자가 확인해야 한다. 정상 삭제가 진행 중일 수 있으므로 잠금을 일괄 해제하지 않았다.

근거: `supabase/functions/delete-account/index.ts`, 기존 migration의 삭제 begin/lock/retry 단계. **로컬 수정 완료, 운영 미반영.**

### 추가 확인 및 한계

- `verify_jwt=false` 함수도 각 handler 내부에서 인증하거나 Apple 서명된 알림을 검증하는 구조를 확인했다.
- StoreKit 소유권, Apple 인증서 신뢰점·서명·bundle/environment, 권한 있는 DB writer, 보존 작업 접근을 검토했다.
- 모델 출력은 실행 가능한 코드로 취급하지 않으며 고정된 일정 명령만 허용한다. 대량·삭제 작업의 확인과 대상 스냅샷 검사가 존재한다.
- 로컬 저장소·설정·위젯 데이터의 계정 분리와 로그아웃 시 정리를 검토했다. 클라이언트 Supabase anon 키를 관리자 secret으로 오인하지 않았다.
- 비동기 AlarmKit 등록이 계정 전환 뒤 완료될 가능성에 대비해 세대·계정 검사를 추가하고 늦게 등록된 알람을 취소한다. 실제 경합 재현은 아직 하지 않았다.
- 위젯이 OS에 이미 전달한 화면을 계정 전환 직후 잠시 유지하는지, 늦게 도착한 알림/스누즈 콜백이 있는지는 실기기 검증 항목이다. 확정된 원격 취약점으로 집계하지 않았다.
- 소스·로컬 DB·모의 handler 검증이다. 운영 침투 테스트, 전체 의존성 취약점 DB 대조, 모든 문서/바이너리의 전수 감사는 수행하지 않았다.

## 4. 앱 버그와 UI/UX 수정

| 문제 | 수정 |
|---|---|
| 요청 속도 제한을 무료 횟수 소진처럼 처리해 결제 화면 표시 | `rateLimited`를 분리. 잠시 후 재시도 안내 및 입력 유지, 실제 `quota_exhausted`만 결제 경로 |
| Claude가 추가됐는데 이전 Gemini 전용 동의가 계속 유효 | 계정별 동의 v2로 갱신. 한국어·영어·일본어에 두 제공자와 전송 범위 안내, Anthropic 정책 링크 추가 |
| 작은 수동 입력 시트에서 키보드·큰 글씨에 내용이 가려질 위험 | 고정 높이를 medium/large 시트와 스크롤로 변경. 시간·긴급도 버튼의 최소 터치 높이 44pt |
| 계정을 바꾸면 다른 계정의 루틴 초기화 날짜 때문에 초기화 생략 | 마지막 초기화 날짜를 계정별 설정으로 분리 |
| 주간 완료 표시가 하루씩 밀림 | Foundation의 일요일=1 값을 월요일 시작 인덱스로 정확히 변환 |
| 루틴 저장 실패에도 초기화 날짜가 진행되거나 완료 기록이 소실 | 저장 성공 뒤 날짜 확정. 실패 시 변경 전 완료·주간 기록 복원 후 재시도 가능 |
| 지역 캘린더 설정이 AI에 보내는 날짜 문자열에 영향 | Gregorian + `en_US_POSIX` 형식 고정 |
| 제공자 대체 중 앱 타임아웃이 먼저 발생할 수 있음 | 클라이언트 요청 예산 30초, 논리 요청 ID 유지, 최대 전송 시도 3회 |
| 로그아웃 중 대기하던 시스템 알람이 나중에 등록될 가능성 | 계정·세대 확인 후 등록 허용, 늦은 등록 취소 |

AI 전송 동의는 앱의 선택 기능이다. 동의하지 않아도 수동 입력을 사용할 수 있다. 공개 개인정보처리방침의 Anthropic/Supabase/Google 설명은 실제 게시 문서에서 별도 확인해야 한다.

스토어 설명 초안의 한국어·영어·일본어, 심사 메모, 계정 설정 인계 문서도 새 제공자 구조로 갱신했다. ASC나 공개 웹에 게시한 것은 아니다. 공개 개인정보 페이지는 이번 웹 도구에서 접근 실패했으므로 게시 내용의 일치를 확인하지 못했다.

## 5. 검증 결과

| 검증 | 결과와 의미 |
|---|---|
| Deno 전체 서버 테스트 | **81 passed, 18 steps, 0 failed**. 제공자 전환·오류·입력/출력 검증·동의·인증·삭제 순서 포함 |
| PostgreSQL 16 로컬 DB harness | **97 passed, 0 failed**. migration 재적용, 권한, 구독, quota, 동시성, 계정 삭제 cascade 포함 |
| iOS Simulator Swift 테스트 | **125 tests / 21 suites 통과, TEST SUCCEEDED**. 최종 변경 반영, iPhone 17 / iOS 26.5 |
| Edge TypeScript 검사 | 변경한 analyze-task/delete-account `deno check` 통과 |
| 패치·스크립트 검사 | `git diff --check`, `bash -n scripts/release-preflight.sh` 통과 |
| 운영 release preflight | **실패 4개 범주**: Claude 키, Apple client secret, 함수 소스/설정 불일치, 미적용 migration |

서버 테스트는 실제 유료 모델 호출 없이 응답을 모의한다. 테스트 통과는 한국어/일본어 자연어 해석 정확도나 실제 계정의 크레딧 소진 전환을 검증했다는 뜻이 아니다. 실제 Apple 구매·복원·삭제와 AlarmKit 잠금화면 동작도 실기기에서 확인해야 한다.

시뮬레이터 화면 도구는 검은 로딩 화면 이후 접근성 조회가 시간 초과되어, 이번 변경 화면의 시각·터치 검사를 완료하지 못했다. Swift 컴파일·단위 테스트와 UI 소스 검토를 화면 조작 완료로 집계하지 않았다.

재현 명령:

```bash
deno test --config supabase/deno.json --allow-read --allow-env=APPLE_BUNDLE_ID \
  supabase/functions/*/*_test.ts supabase/tests/*_test.ts
PG_BIN=/opt/homebrew/opt/postgresql@16/bin python3 supabase/tests/db/storekit_db_check.py
xcodebuild -project ADHD/ADHD.xcodeproj -scheme ADHD \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath /tmp/mora-release-20261013/DerivedData \
  -parallel-testing-enabled NO test
bash scripts/release-preflight.sh
```

로컬 실행 로그: `/tmp/mora-release-20261013/`의 `deno.log`, `db.log`, `typecheck.log`, `preflight.log`, `xcode-release-final.log`. Xcode 결과 묶음은 `DerivedData/Logs/Test/Test-ADHD-2026.10.13_14-01-38-+0900.xcresult`다. 임시 디렉터리이므로 장기 보존 자료는 아니다.

## 6. 운영 확인 결과와 배포 순서

연결된 프로젝트 `nmjtswtqwwxxwiolgsnk`는 조회 시 `ACTIVE_HEALTHY`이고 DNS도 정상이다. Secret 값은 출력하거나 보고서에 저장하지 않았다.

| 항목 | 읽기 전용 확인 결과 |
|---|---|
| `ANTHROPIC_API_KEY` | **없음**. 이번 세션 환경 변수에도 없음 |
| `GEMINI_API_KEY`, `GEMINI_MODEL` | 이름 존재. 실제 값·모델 접근·잔액은 미검증 |
| `APPLE_CLIENT_ID`, `DELETION_STATUS_SECRET` | 이름 존재 |
| `APPLE_CLIENT_SECRET` | **없음**. 실제 Apple 재인증·계정 삭제 완료에 필요 |
| `analyze-task` v22, `delete-account` v3 | 현재 로컬 소스 및 기대 gateway 검사 불일치 |
| `storekit-sync` v2, `app-store-notifications` v2 | 배포 소스 및 gateway 검사 일치 |
| migration `202609300002` | 성인 확인 변경 미적용 |
| migration `202610130001` | 이번 AI broker 변경 미적용 |

출시 전 순서는 다음과 같다.

1. 받은 Claude 크레딧의 조직에 속한 API 키를 Supabase Secrets에 등록한다. 모델 접근, 크레딧 만료·자동 충전·지출 한도를 확인한다. 비밀 값은 저장소나 대화에 붙여 넣지 않는다. Apple client secret도 유효한 값으로 등록한다.
2. 성인 확인 및 AI 동의 v2 화면이 포함된 현재 앱 빌드를 준비한다. 이전 앱은 새 gate에서 AI가 거절될 수 있다. 테스트용 Apple 계정과 staging 환경으로 먼저 검증한다.
3. 미적용 migration 내용을 검토하고 적용한다. `202610130001`은 이전 Edge의 원장 실행 권한을 회수하므로 **migration 적용과 새 analyze-task 배포 사이 AI 분석이 중단될 수 있다.** 출시 전 또는 짧은 점검 구간에 연속 적용한다.
4. 새 `analyze-task`, `delete-account`를 각각 배포한다. 기존 설정대로 `--no-verify-jwt`를 쓰되 handler 내부 JWT/서명 검증을 유지한다. service-role secret은 Edge에서만 사용한다.
5. `scripts/release-preflight.sh`를 다시 실행해 secret 이름, migration 이력, 실제 함수 소스와 gateway를 확인한다. 존재만 확인한 secret의 유효성은 실제 성공 경로로 별도 확인한다.
6. 테스트 계정으로 Claude 정상 성공, Claude 비활성 시 Gemini 성공, 같은 requestId 재전송, 무료 한도, 동의 재요청, Apple 삭제 완료를 확인한다. 한국어·영어·일본어의 시간/날짜·수정·삭제 명령도 확인한다.
7. 실기기에서 구매·복원·로그아웃/계정 전환 중 알람·위젯, 큰 글씨와 키보드 입력 시트를 확인한 뒤 출시한다. 공개 개인정보처리방침도 새 제공자 구성을 반영한다.

문제가 Claude에 국한되면 `ANTHROPIC_ENABLED=false`로 Gemini 경로를 사용한다. **이전 원장 grant를 다시 열거나 이전 analyze-task만 단독 복원하면 안 된다.** broker migration 이후에는 v2 RPC를 사용하는 함수 버전으로 복구해야 한다. 삭제 작업·사용량 테이블을 롤백 목적으로 지우지 않는다.

## 7. Jev 도입 판단

정확한 저장소 링크가 주어지지 않아 **`feder-cr/jev`(현재 이름 jevos)**를 후보로 검토했다. 이 판단은 해당 프로젝트에 한정한다. 저장소는 CPU에서 yes/no·선택·점수 확률을 반환하는 분류 모델이며, 일정의 날짜·시간·수정 대상을 만드는 생성형 라우터의 직접 대체품은 아니다. README 기준 C++ 실행 파일, 약 1 GB 메모리(캐시 포함 약 1.4 GB), 자체 HTTP API를 사용한다. 코드 라이선스는 MIT이며 모델·의존성 고지는 별도 검토 대상이다. 공개 지연시간 수치는 개발자의 Intel 노트북 측정으로 MORA/iPhone 측정값이 아니다. [프로젝트 원문](https://github.com/feder-cr/jev)

**이번 출시에는 도입하지 않는다.** 현재 SwiftUI + Supabase Edge 구조에 그대로 넣기 어렵고, 별도 서비스 운영·인증·배포·모니터링을 추가해야 한다는 판단이다. 한국어/일본어의 모호한 일정 입력을 잘못 차단하면 절감하는 비용보다 입력 실패가 더 큰 문제가 된다. 코드 의존성이나 외부 전송 경로를 추가하지 않았다.

출시 후 검토한다면 사용자 요청을 막지 않는 관찰 모드에서 “일정 명령/잡담” 분류부터 평가하는 것이 적절하다. 실제 입력을 무단 수집하지 말고 합성·동의된 예제로 오탐률과 종단 지연시간을 측정해야 한다. 결제·성인 확인·삭제 허가 같은 권한 판단에는 사용하지 않는다. 불확실한 결과는 기존 Claude/Gemini 경로로 보낸다.

## 8. 인수 조건

- 코드 수준의 요청 구조 변경과 확인된 결함 수정은 완료했다.
- 운영 적용과 실제 Claude 품질·잔액 소진 테스트는 키 등록 이후 남는다.
- Apple 삭제 시크릿·호환 앱·DB/함수 배포·실기기 시나리오가 충족되기 전에는 출시 완료로 표시하지 않는다.
- 보안 감사는 이번 소스 범위의 증거 기반 검토이며, 시스템 전체의 무결점을 보증하지 않는다.

## 부록 · 보안 점검 기록

Codex Security의 정규 보안 점검은 완료되었고 결과 파일이 생성됐다. 이 통합 보고서에 핵심 결과를 모두 옮겼으며, 상세 코드 근거는 [자동 생성된 보안 보고서](/Users/gimgihong/.codex/state/plugins/codex-security/scans/adhd/51c4f464403434608cfc8ab8be18d05e62f402b3_20261013T043626Z_3mg9euoa/report.md)에 있다.

- Scan ID: `88573357-9943-46f8-896f-4a4f127f0d24`
- 결과: 기존 코드에서 높은 위험 1건·중간 위험 1건. 두 건 모두 로컬 수정·회귀 검증 완료, 배포 필요.
- 점검 도중 코드를 고쳤으므로 정규 보고서의 발견 위치는 원래 기준 커밋에 묶여 있다. 수정 후 코드를 여전히 취약하다고 단정하는 의미가 아니다.
- 도구가 반환한 사용량 집계: `coverage=complete`, 참여 스레드 4개, 총 25,844,229토큰, 입력 25,739,837토큰, 캐시 입력 24,202,112토큰, 출력 104,392토큰. 반복 컨텍스트를 포함하는 작업 도구 집계이며 **MORA의 Claude/Gemini API 사용량이나 결제액이 아니다.** 금액으로 환산하지 않았다.
