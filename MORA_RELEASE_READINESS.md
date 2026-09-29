# MORA 출시 준비 결과 — 2026-09-29

**판정: 구현·배포 수정 완료, App Store 제출은 BLOCKED.** 테스트하지 않은 실제 Apple 거래·삭제·실기기 알람을 통과로 간주하지 않는다. Apple 심사 승인을 보장하는 문서가 아니다.

## 통합 범위

- main `49add4d` 기반 `codex/release-readiness-20260929`. backend `9423851`, iOS `4959a7b` + 동의 검사 액터 보완 `ff833b4`, 배포 검증 도구 `93308e8`.
- 팀원 PR [#57](https://github.com/TRIDENT-KR/adhd/pull/57)은 Draft 인수 스냅샷으로 보존한다. f175ca8/dc0029c를 검토해 필요한 동작을 main과 통합했다. 구 브랜치의 Pro 알람·위젯 삭제와 Kimi 도입은 포함하지 않았다.
- Gemini 3.5 Flash-Lite 기본값·환경변수를 적용하면서 main의 JWT/서버 quota/응답 envelope/개인정보 로그 보호를 유지했다. API 키는 URL 대신 헤더로 전달한다.
- 앱에 계정별 AI 전송 동의·철회와 전송 직전 세션 일치 검증을 추가했다. 동의 없이 수동 입력 가능. 음성 권한은 마이크를 누를 때 요청하며 거부 시 설정/텍스트 대체 경로와 최초 허용 후 재탭 안내를 제공한다.
- 실제 StoreKit 가격·통화로 연간 절약률 계산, 월간/연간 구분, 미출시 백업 광고 제거. Pro 알람·위젯 유지. 영어/한국어/일본어 권한 설명, 일본어 잔여 오역, 큰 글자 로그인/탭/루틴/플래너를 보완했다.
- 보존 cron을 postgres 역할로 설치하고 여러 번 나누어 정리할 때 일별 합계가 감소하던 오류를 수정했다.
- 공개 정책 수정은 [웹 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1)에 있다. 대상 연령 결정 전 Draft이며 아직 공개 사이트에 반영되지 않았다.

## 실제 서버 상태

대상 Supabase 프로젝트 `nmjtswtqwwxxwiolgsnk`. backend `9423851`에서 아래를 적용했다.

| 경로 | 상태 | 검증 |
|---|---|---|
| analyze-task | v22 ACTIVE | 실제 Gemini 분석·quota·replay + 다운로드 소스 일치 |
| delete-account | v3 ACTIVE | 다운로드 소스 일치, 실제 Apple 삭제는 secret 부족으로 미검증 |
| storekit-sync | v1 ACTIVE | 다운로드 소스 일치, 무인증 차단, 실제 Sandbox 거래 미검증 |
| app-store-notifications | v1 ACTIVE | 다운로드 소스 일치, 잘못된 서명 거부, 실제 Apple 알림 미검증 |

네 함수는 gateway verify_jwt=false이며 각 handler가 사용자 인증 또는 Apple JWS 서명을 검증한다. gateway 설정만으로 공개 무인증 접근을 허용한 것이 아니다.

적용 migration: `202608040001_mora_security_contracts`, `202609240001_mora_storekit_sync`, `202609290001_mora_security_maintenance`. 마지막 migration은 5분 간격 bounded 정리를 설치하고 job 소유자/DB/명령/주기를 검증한다. 실제 cron 실행 이력까지 관측한 것은 아니다.

GEMINI_MODEL=gemini-3.5-flash-lite, APPLE_CLIENT_ID/APPLE_BUNDLE_ID, DELETION_STATUS_SECRET 준비. **APPLE_CLIENT_SECRET는 미설정.** 키 값·토큰·실사용자 데이터를 산출물에 기록하지 않았다.

배포 도중 Supabase 일부 요청이 500으로 실패했고, 함수 버전만 바뀌고 구 소스가 남는 상황을 확인했다. 개별 재배포 후 네 함수의 모든 상대 import 소스를 다운로드해 SHA-256이 일치함을 확인했다. 이제 `scripts/release-preflight.sh`도 날짜가 아닌 소스·gateway·migration 이력을 검사한다. 최종 실패 1건은 APPLE_CLIENT_SECRET 누락이다.

## 검증 결과와 한계

| 검사 | 결과 | 범위 |
|---|---|---|
| Swift XCTest/Swift Testing | 95 passed, 0 failed, 0 skipped | 14 suites. 가격·계정 동의 회귀 포함 |
| Deno 단위/계약 | 53 passed | 현재 운영 코드, Luna eval/레거시 유료 러너 제외 |
| 실제 handler 격리 HTTP | 12 passed | fake 외부 의존성; 운영 진입점은 별도 type-check 통과 |
| 격리 PostgreSQL | 36 passed | StoreKit/원장/삭제·bounded 집계 회귀. 운영 DB fixture 아님 |
| 최종 Debug UI 빌드 | PASS | Swift 회귀 뒤 추가된 Planner 배치/장식 아이콘 수정도 컴파일·UI 확인 |
| Release archive | PASS | 1.0 (3), 앱·위젯 서명/manifest/3언어 권한 리소스 확인. 개발 서명 |
| App Store export | BLOCKED | 앱·위젯 배포 프로파일 없음, 배포 인증서 0개. 실제 export 실패 확인 |
| 실제 Gemini 서버 smoke | PASS | 지정한 임시 staging Auth 계정·합성 문장만 사용 |
| 전체 출시 33개 case | 미완료 | 부분 근거가 전체 시나리오 통과를 의미하지 않음 |

최신 UI 배치와 동의 검사 액터 보완까지 포함한 최종 회귀를 실행한다. 결과 확정 전 이전 95건을 최종 SHA 결과로 이월하지 않는다.

Release는 개발 서명으로 생성됐으며 App Store export를 실제 시도했으나 앱·위젯 배포 프로파일이 없어 실패했다. 기존 Apple Distribution 인증서도 없다. Apple 계정 소유자가 배포 인증서/두 App Store provisioning profile을 준비하거나 Xcode Organizer에서 권한 있는 계정으로 자동 서명을 설정해야 한다. 인증서 생성·약관 수락·업로드를 대신하지 않았다.

Release에 기존 경고 8개(Swift 6 전환 관련 actor 7, UIScreen deprecated 1)가 남아 있다. 현재 Swift 5 언어 모드에서 빌드 성공했다. 이번 AI 동의 코드에서 발생한 actor 경고는 해결했다. CPU 병렬도를 더 줄이려 시도한 두 컴파일 설정은 Xcode 출력/driver 계약과 맞지 않아 실패했고, 해당 임시 옵션은 제품 설정에 반영하지 않았다. 정상 Xcode 경로/jobs 1/낮은 우선순위로 최종 archive를 검증했다.

실제 서버 smoke: 분석 성공 3회(4.417/1.832/2.003초), 같은 request ID replay 0.909초·추가 차감 없음, 네 번째 무료 요청 429. 최종 smoke의 임시 사용자는 삭제했다. 초기 구 배포본 확인에서 발생한 별도 호출/실패도 로그로 보존했다. 이 소표본으로 모델 의미 정확도나 p95 성능을 산출하지 않는다. Luna 모델 평가·Jev 비교는 별도다.

시뮬레이터 한 대에서 AI 동의 화면/취소 시 초안 보존, 권한 거부와 설정 이동, 실제 StoreKit 상품 표시, 일본어 로그인·개인정보 링크, 최대 글자 루틴/플래너·탭 접근성 표본을 확인했다. DEMO는 합성 화면 점검일 뿐 Apple 로그인·AI 일정 저장 E2E가 아니다. 실제 상품 조회는 구매·복원 성공을 뜻하지 않는다. 설정 링크는 simulator에서 Settings 진입까지만 확인했으며 실제 기기의 앱별 설정 복귀는 남아 있다.

## 출시 전에 반드시 끝낼 것

1. **대상 연령 결정 및 Google 프로젝트 설정.** Gemini API 약관은 18세 미만을 대상으로 하거나 이용 가능성이 있는 API Client를 제한한다. 기존 정책은 13세 미만만 제외하고 있어 정합성이 없다. 18세 이상 서비스로 운영할지, 청소년을 포함하려면 다른 제공 경로를 검토할지 사용자 답변 대기. 연령 분류만 바꾸면 약관 문제가 자동 해결되는 것은 아니다. Google billing/유료 서비스·데이터 처리 조건과 지역 요건도 실제 프로젝트에서 확인한다. [Gemini 약관](https://ai.google.dev/gemini-api/terms)
2. **Apple 계정 설정.** 소유자의 Apple signing key로 유효한 APPLE_CLIENT_SECRET를 준비·서버에 설정하고 갱신 일정을 관리한다. ASC 유료 앱 계약/세금/은행, 구독 상품/지역별 가격·설명, 개인정보 응답·심사 접근 정보를 확인한다. 서버 알림 V2의 Production/Sandbox URL 모두 `https://nmjtswtqwwxxwiolgsnk.supabase.co/functions/v1/app-store-notifications`로 연결하고 Apple 테스트 알림 수신을 확인한다. private key를 채팅에 붙이지 않는다.
3. **지정 계정·실기기 QA.** Apple 로그인→동의→실제 AI 일정 저장, 두 계정 격리/오프라인/재시도, Sandbox 구매·복원·만료/환불·재귀속, 폐기 전용 Apple 계정 삭제·실패 재개, iOS 26.2 및 최신 지원 OS의 알람·위젯을 검증한다. 상세는 [전체 QA 계획](MORA_RELEASE_QA_PLAN.md)의 33개 case를 따른다.
4. **정책 게시·배포 서명·동일 RC 관찰.** 웹 PR을 대상 연령/Google 데이터 조건과 함께 확정해 게시하고 앱·ASC·정책을 일치시킨다. App Store 배포용 서명/export·TestFlight 업로드 후 LLM 평가 통과 및 48시간 관찰을 완료한다. 업로드/심사 제출은 이번에 하지 않았다.

현재 완료할 수 없는 위 단계는 환경 또는 제품 의사결정이 필요하다. 구체적 클릭 절차와 심사 정보 초안은 [App Store 인계서](MORA_APP_STORE_HANDOFF.md)에 있다.

## Apple 지침 대조

| 지침 | 이번 반영 | 남은 근거 |
|---|---|---|
| 2.1 완성도 | 서버 계약 통합, 모델 실제 성공, 자동 회귀·UI 표본 | 실제 기기 전체 흐름·심사 접근·TestFlight |
| 2.3 정확한 설명 | 미출시 백업 제거, 실제 가격 절약률, 알람 전달 제한 고지 | ASC 상품/스크린샷/정책 게시 확인 |
| 3.1.2 구독 | StoreKit 표시 가격·기간·복원·서버 서명 검증 경로 | 실제 Sandbox 구매/복원/서버 알림 |
| 5.1.1 개인정보/계정 삭제 | 로그인 개인정보 링크, 권한 설명 3언어, 삭제 상태 머신 배포 | Apple revoke secret·실제 삭제·ASC privacy 응답 |
| 5.1.2(i) 외부 AI 전송 | 명시 선택 동의, 수신자·전송 범위 고지, 계정별 철회 | 공개 정책 정합성·Google 대상 연령/요금제 |

공식 근거: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [Account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/), [Subscriptions](https://developer.apple.com/app-store/subscriptions/). 2026-09-29 조회 기준이며 심사 결과 자체를 예측하거나 보장하지 않는다.

## 재현·배포 및 복구

- 기본 read-only 점검: `bash scripts/release-preflight.sh`. 원격 소스만 비교: `python3 scripts/verify-deployed-functions.py nmjtswtqwwxxwiolgsnk`.
- 저장소 지침에 따라 main 자동 merge는 하지 않는다. 통합 PR merge 전 main 분석 함수를 재배포하면 2.0 기본값으로 회귀한다. 모델 env가 있더라도 구 main은 env를 읽지 않으므로 안전하지 않다.
- 후속 배포는 이 통합 코드의 migration 적용 상태를 확인한 뒤 함수를 각각 `supabase functions deploy <name> --no-verify-jwt --use-api --project-ref nmjtswtqwwxxwiolgsnk`로 수행하고 다운로드 검증한다.
- 장애 시 알려진 정상 backend `9423851`의 함수 소스로 복구하고 소스 검증/합성 smoke를 수행한다. v20이나 구 main/2.0으로 되돌리지 않는다. migration을 역방향 삭제하거나 원장을 지우지 않는다. 모델을 바꿀 경우 실제 존재·호환·하네스 평가를 먼저 확인한다.

로컬 증거 폴더: `outputs/release-readiness/20260929-integration/` (원래 checkout). 주요 파일은 `deployed-source-verification.json`, `live-staging-smoke.json`, `swift-test-summary.json`, `release-tests.xcresult`, `deno-tests.log`, `http-tests.log`, `db-tests-final.log`, `release-preflight.log`, 최종 UI PNG, archive/export 기록이다. 기존 main 야간 로그는 `outputs/release-qa/20260929-49add4d/`에 별도 보존했다.
