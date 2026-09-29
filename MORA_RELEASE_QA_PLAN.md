# MORA 출시 전 최종 QA 실행 계획

상태 갱신: **2026-09-29 통합 수정·서버 배포·실제 Gemini smoke 완료. 전체 출시는 BLOCKED.**

최신 결과·사람에게 필요한 조치는 [출시 준비 보고서](MORA_RELEASE_READINESS.md)를 우선한다. 아래 §7은 변경 전 main `49add4d`의 야간 검사 이력이며 당시의 읽기 전용/배포 금지 범위는 보존 기록이다. 이후 사용자의 구현·출시 준비 위임에 따라 §8을 실행했다. §4~5의 전체 출시 gate는 유지한다.

- 기준 main: `49add4d065f40cb1a0be186987e9ff89cdb45c05`. 통합 브랜치: `codex/release-readiness-20260929`.
- 팀원 PR #57은 Draft·충돌 상태로 보존. `f175ca8` 페이월/`dc0029c` Gemini에서 필요한 변경을 main의 서버 quota·구매·계정 보호와 통합했다. Pro 알람·위젯 혜택은 유지한다.
- 원래 checkout의 Luna 하네스·프롬프트 미커밋 변경은 보존했다. 별도 관리 worktree에서 작업했다.
- 배포: analyze-task v22, delete-account v3, storekit-sync v1, app-store-notifications v1. 네 함수의 실제 다운로드 소스/상대 import hash와 gateway 설정 일치. 3개 migration 적용.
- 실제 Gemini 분석 3회, 동일 요청 replay 무차감, 네 번째 무료 요청 서버 차단 확인. 이는 서버 합성 smoke이며 앱 Apple 로그인 E2E나 LLM 평가 점수는 아니다.
- 자동 회귀: Swift 95, Deno 53, 격리 HTTP 12, StoreKit/보존 DB 36 통과. 기존 SHA의 결과는 이월하지 않는다.
- APPLE_CLIENT_SECRET, 실제 Apple 삭제/구매/복원/알람, 대상 연령·Google 요금제, 정책 게시·ASC·TestFlight 완료는 남아 있다.

| Gate | 현재 상태 | 근거 / 남은 범위 |
|---|---|---|
| 0 연결·준비 | 부분 완료 / BLOCKED | 서버 소스·migration·Gemini 연결 확인. Apple 삭제 secret·ASC 설정 필요 |
| 1 자동 검증·빌드 | 자동 테스트 PASS | Swift95/Deno53/HTTP12/DB36. 최신 archive 결과는 보고서 참조 |
| 2 핵심 앱 흐름 | 부분 실행 | 서버 실제 quota/replay PASS. Apple 로그인 뒤 앱 E2E 필요 |
| 3 일정·알람·위젯 | 실기기 BLOCKED | 날짜/계정 회귀는 통과, 실제 수신·위젯 전환 필요 |
| 4 결제·삭제·운영 | 부분 완료 / BLOCKED | 서버 4함수·보존 cron 설치. 실제 Apple 거래/삭제·cron 실행 관측 필요 |
| 5 UI·접근성·성능 | 표본 PASS / 부분 실행 | 명시 AI 동의·권한 거부 복구·가격·큰 글자 수정 확인. 전체 12조합/성능/실기기 미완료 |
| 6 TestFlight 48시간 | NOT_RUN | 선행 필수 gate 완료 뒤 시작 |

과거 결과: [변경 전 야간 QA](outputs/release-qa/20260929-49add4d/release-decision.md). 새 증거: `outputs/release-readiness/20260929-integration/`.

## 1. 역할과 범위

- Luna: 재사용 가능한 LLM 평가 하네스 구현. 해당 파일·프롬프트를 이 QA 작업에서 동시에 수정하지 않는다.
- Codex: 통합 출시 QA, 환경 확인, 자동 테스트, 결함 기록, 원인 조사, 수정 후 영향 범위 재검증.
- 사용자: 물리 기기에서 필요한 권한·Apple 인증·Sandbox 결제 및 알람 관찰. 사람이 필요한 단계에서 짧은 절차만 전달한다.
- 출시 모델: `gemini-3.5-flash-lite`. 하네스 점수는 AI 품질 근거이며 전체 앱 출시 승인을 대체하지 않는다.
- 이번 계획은 자동 테스트 → internal TestFlight 48시간 → App Store 순서를 따른다. 기존 D19에 따라 XCUITest 신규 구축은 범위 밖이며 UI는 수동 검증한다.

## 2. 현재 확인한 선행 위험

| 항목 | 현재 근거 | 다음 확인 |
|---|---|---|
| 모델/앱 계약 | 수정 배포 v22에서 envelope·quota·실제 Gemini 성공 | 통합 PR merge 전 구 main 재배포 금지 |
| Apple 계정 삭제 | 새 함수 배포·대부분 secret 준비, APPLE_CLIENT_SECRET 없음 | 소유자 signing key로 secret 설정 후 지정 폐기 계정 E2E |
| 결제/복원 | JWS/서버 함수 배포, StoreKit 상품 조회·동적 가격 확인 | ASC 서버 알림 연결, Sandbox 구매/복원/환불 |
| AI 대상 연령/요금제 | Google API 약관상 미성년 대상 제한, 기존 공개 정책은 13세 미만만 제외 | 18세 이상 서비스 결정 또는 제공 경로 재설계, Google billing 확인 |
| 정책/심사 제출 | 앱 내 AI 전송 동의·권한 설명·구독 고지 보완 | 수정된 공개 정책 게시, ASC 개인정보/상품/심사정보 정합성 확인 |

서버 배포·단위 테스트·합성 smoke·실기기 통과는 별도 상태로 기록한다. Pro 플래그 조작이나 demo를 실제 거래 검증으로 세지 않는다.

## 3. RC와 증거 관리

RC마다 Git SHA, dirty diff 여부, 앱 버전/build, Xcode, OS·기기, 배포 함수/DB 버전, 모델·프롬프트 hash, 실행 날짜를 고정한다. Luna 변경이 합쳐지면 새 RC로 취급한다. 자동 테스트 결과와 실기기 결과가 다른 SHA면 별도 기록한다.

산출물은 `outputs/release-qa/<rc-id>/`에 보관한다:

- manifest 및 환경 확인표
- 자동 테스트 로그와 xcresult
- case-results.csv: ID, 사전조건, 단계, 기대값, 실제값, 상태, 환경, 증거 경로
- defects.md: 심각도, 재현 절차, 영향, 수정 SHA, 재검증 결과
- release-decision.md: PASS/FAIL/BLOCKED, 남은 위험, 승인 범위

상태는 NOT_RUN / PASS / FAIL / BLOCKED / N/A로 구분한다. 건너뛴 테스트를 PASS 처리하지 않는다. 로그·스크린샷은 합성 일정만 사용하고 토큰·사용자 식별정보는 제거한다.

## 4. 실행 순서

### Gate 0 — 출시 경로가 실제 연결되어 있는지

1. 로컬 변경과 Luna 작업 범위 확인. 동시에 변경되는 checkout에서 파괴적 Git 명령을 실행하지 않는다.
2. 앱 Bundle ID, App Group, 최소 iOS(현재 26.2), signing, widget extension, scheme·Release 설정 확인.
3. 연결된 Supabase 환경의 migration/RPC/function 버전을 읽기 전용으로 대조. 키는 값 대신 존재와 연결 성공 여부만 기록.
4. Gemini 목표 모델 호출 가능 여부, quota·rate limit·오류 로그 경로 확인. live 호출 예산은 하네스 실행과 일관되게 통제.
5. Apple 로그인·계정 삭제·구독 검증 및 Server Notification 경로 준비 여부 확인.
6. 테스트 계정 A/B와 2개 Sandbox Apple 계정, iOS 실기기 2대 사용 가능 여부 확인. 계정 삭제용 사용자는 별도로 지정한다.

공유 프로젝트의 stage/prod는 Auth를 공유할 수 있으므로 stage라는 이름만 믿고 삭제하지 않는다. 원격 쓰기·구매·계정 삭제는 지정한 QA 자원과 승인된 범위에서만 수행한다.

완료 조건: 각 필수 경로가 테스트 가능한 상태. 미구현·자격증명·기기 부족은 BLOCKED로 구분한다. 독립적인 로컬 테스트는 계속 진행한다.

### Gate 1 — 자동 검증과 빌드

- 현재 Deno validator, analysis-service, delete-account 계약 테스트 실행.
- Xcode ADHDTests 전체 실행: decoding, 계정 저장소, entitlement, 날짜 발생·일일 reset, 시간 정렬, 삭제 범위, urgency.
- 실제 테스트가 발견되어 실행됐는지 개수와 결과 확인. 0 tests인 성공을 인정하지 않는다.
- Debug 및 Release 앱·위젯 빌드, signed archive validation. 무서명 generic 빌드는 보조 증거다.
- 사용자 자원 제한에 따라 build/Swift jobs 1, 낮은 우선순위, 병렬 테스트·index store 비활성으로 실행하고 simulator는 한 대만 켠다. 무거운 작업을 겹치지 않는다. 환경 오류와 제품 결함을 구분한다.
- 보안 DB 검증은 격리된 임시 DB에서 migration 재적용, 권한, quota 경합, 삭제 상태 머신, cleanup을 검증한다. 운영 DB에 fixture를 주입하지 않는다.
- Luna 하네스의 offline 테스트 및 smoke 통합 결과를 인수한다. 기존 테스트와 새 결과를 혼동하지 않는다.

완료 조건: 필수 테스트 실패 0, Release 앱·위젯 archive 검증 성공. 경고는 영향과 수용 이유를 기록한다.

### Gate 2 — 데이터·인증·AI 핵심 흐름

| ID | 시나리오 | 통과 조건 |
|---|---|---|
| AUTH-01 | 신규 설치 → Apple 로그인 → 온보딩 완료/스킵 | 올바른 화면 진입, 가이드 자동 중복 노출 없음 |
| AUTH-02 | A 일정·초안·Undo·알림 생성 → 로그아웃 → B 로그인 → A 재로그인 | B에 A 데이터 노출 없음, A 일정 보존, 오래된 알림/위젯 액션 차단 |
| AUTH-03 | 앱 재시작, 세션 만료/취소, 비행기 모드 | 유효 세션만 로컬 접근 허용, 무효 세션 잠금, 데이터 자동 삭제 없음 |
| VOICE-01 | 마이크/음성 인식 각각 허용·거부·설정 변경 | 동작 가능한 복구 안내, crash/무한 대기 없음 |
| VOICE-02 | 녹음 → 종료 → 초안 수정 → 명시적 분석 | 분석 전 API/차감 없음, 수정된 문장 제출, 중복 탭 중복 실행 없음 |
| VOICE-03 | 녹음 중 background/화면 잠금/오디오 인터럽트 | 마이크·오디오 세션 정리, 초안·UI 상태 일관, 타 앱 소리 정상 복구 |
| AI-01 | 목표 모델로 한·영·일 추가/수정/완료/삭제 | 카드와 저장 결과 일치, 기존 decoder·validator 호환 |
| AI-02 | timeout·429·5xx·잘못된 JSON | 실패 표시, 초안 보존, quota 미차감, 재시도 중복 저장 없음 |
| AI-03 | 무료 성공 3회 → 4회, KST 자정, 같은 ID 재시도·동시 요청 | 서버 원장 기준 한도, 실패 미차감, 성공 중복 차감 없음 |
| AI-04 | 분석 중 로그아웃/계정 변경 | 이전 응답이 새 계정에 반영되지 않음 |
| SAFE-01 | 확인 설정 OFF 상태 삭제·전체 삭제·대량 변경 | 파괴적 작업은 여전히 대상·날짜·종류·개수 확인 필수 |
| SAFE-02 | 확인 카드 이후 대상 변경·삭제, 동일 이름 여러 항목 | 대상 snapshot 변경 탐지 및 재확인, 범위 확대 없음 |
| SAFE-03 | 묶음 실행 일부 실패 → 재시도 → Undo | 성공 항목 중복 실행 없음, 실패만 재시도, 저장·알림 상태 일관 |
| DATA-01 | 수동 추가/편집/삭제/완료/정렬/검색 → 앱 재시작 | 상태 보존, AI 한도 소진·오프라인에서도 수동 기능 사용 가능 |
| DATA-02 | 저장 실패 주입 | 성공으로 표시하지 않음, 자동 DB 초기화 없이 복구 안내 |

오류·시각 경계는 우선 테스트 의존성 주입/격리 환경으로 재현한다. 운영 기기 시계를 임의로 바꾸어 서버 quota를 검증하지 않는다.

### Gate 3 — 일정·알람·위젯 실기기

| ID | 시나리오 | 통과 조건 |
|---|---|---|
| DATE-01 | 자정/주 경계, 격주 14일, 31일 월간, 2월29일 연간 | 최초 기준일 유지, 월말 정책 일치, 완료 시점으로 반복 기준 이동 없음 |
| DATE-02 | 시간대 변경·DST, 이미 지난 시각 | 명세의 wall-clock 정책 일치, 다음 실제 발생 날짜·알람 일치 |
| ALARM-01 | Free/Pro × weak/strong × foreground/background/앱 종료 | 기대 경로로 알림·AlarmKit 표시. 약한 알림이 Pro 풀스크린으로 오발동하지 않음 |
| ALARM-02 | 권한 거부·철회, 집중 모드·무음·잠금 | OS가 허용하는 동작과 앱 안내 일치. 권한/OS 제한을 무시한 전달 보장을 하지 않음 |
| ALARM-03 | 완료·삭제·시간 수정·Undo·로그아웃 | 이전 알람 취소, 새 알람 중복 없음, 고아 알림 미노출 |
| ALARM-04 | Done·5분 Snooze·팔로업, 반복 다음 회차 | 완료 relay 1회 적용, 후속 알람 정리/재예약 정확 |
| WIDGET-01 | 6종 위젯, Free 잠금 → paywall, Pro 데이터·토글 | 요금제와 계정 범위 일치, 올바른 딥링크 |
| WIDGET-02 | A→B 전환, 구독 만료, 오래된 widget timeline/action | 이전 계정 내용/권한 잔존 없음. OS 갱신 지연과 데이터 노출을 구분 |
| UPGRADE-01 | 데이터 있는 이전 QA build → RC 업데이트 | 일정·반복·계정 상태 보존. 초기 테스트 DB cutover는 명세대로 1회만 |

AlarmKit은 simulator만으로 PASS 처리하지 않는다. 실제 잠금·앱 종료 상태와 지정 시간의 수신을 관찰하고 예약 목록·관찰 시각을 함께 기록한다.

### Gate 4 — 결제·복원·계정 삭제·운영

| ID | 시나리오 | 통과 조건 |
|---|---|---|
| PAY-01 | Sandbox 구매 성공·취소·pending·실패 | 검증 전 Pro 부여 없음, 중복 거래 없음, 상태별 안내 정확 |
| PAY-02 | 같은 Mora 계정 다른 기기 복원, 다른 Mora 계정 복원 | 동일 계정 복구, 다른 계정에 구독 자동 공유 없음 |
| PAY-03 | 만료·grace·환불·revocation·알림 중복/역순 | 서버 권한과 앱·위젯·알람이 일치, 오래된 이벤트로 권한 부활 없음 |
| PAY-04 | offline accessUntil 경계, 계정 삭제 후 허용된 rebind | 기한 이후 Pro 과다 허용 없음, 확정 정책대로 명시적 재귀속 |
| DELETE-01 | 재인증 → 삭제 요청 → 완료 | 즉시 노출 잠금, 서버 완료 후 로컬 물리 store 삭제, 재로그인 정책 준수 |
| DELETE-02 | 단계별 네트워크 실패·앱 강제 종료·재실행 | request ID로 재개, 거짓 완료 없음, 중복 삭제 안전 |
| DELETE-03 | 구독 보유 계정 삭제 | 구독 때문에 삭제 차단 없음, 별도 해지 안내·관리 링크 정상 |
| OPS-01 | 합성 민감 문구로 분석·저장·삭제 후 로그 확인 | 전사문·일정명·LLM 원문·키가 운영 로그에 남지 않음 |
| OPS-02 | cleanup 실행·보존기간·장애 관측 | 만료 자료 정리와 운영 지표 확인, 필요한 데이터 조기 삭제 없음 |

로컬 StoreKit configuration 테스트는 Sandbox/TestFlight 거래 검증의 대체가 아니다. 실패 주입과 destructive 검증은 지정 QA 계정/격리 환경에서만 수행한다.

### Gate 5 — UI·접근성·성능

기기: 최소 지원 iOS 26.2의 실기기 1대 + 출시 시 지원하는 최신 iOS 실기기 1대. 작은 화면을 포함한다. 최신 OS 버전은 실행 시 확인한다.

언어 3 × light/dark 2 × Free/Pro 2의 12조합은 주요 화면 smoke를 수행한다. 전체 심층 시나리오는 위험 중심으로 조합을 배분하고 모두 12회 반복하지 않는다. 권한·오프라인·계정 전환 핵심은 별도로 반복한다.

- Home, Routine, Planner, 설정, 온보딩, 확인 카드, paywall, 삭제 화면의 잘림·빈 상태·로딩·오류 상태.
- Dynamic Type 최대, VoiceOver 흐름·라벨/힌트, 44pt 터치 영역, Reduce Motion.
- 음성 인식 locale와 UI 언어 일치, 설정 즉시 반영, 위젯 문자열 반영.
- 기존 D19 목표: 녹음 종료→확인 카드 p90 ≤4초, 마이크 탭→리스닝 ≤0.3초, cold start→Home ≤2초.
- 현재 명시적 분석 UX에서는 사용자의 초안 편집/대기 시간을 시스템 지연에서 제외한다. STT 종료→초안 표시와 분석 탭→카드 표시를 따로 기록하고 합산 기술 지연을 보고한다. 이전 목표와 측정 구간 차이를 명시한다.
- 기기·네트워크별 AI 분석 30회, cold start 10회, mic warm/cold 각각 10회 측정. 표본 수·p50/p90/p95·실패율을 기록하고 소표본 p95를 정밀 추정으로 해석하지 않는다.
- 긴 일정 목록·복수 명령·연속 녹음에서 메모리 증가, 오디오 세션 잔류, UI 멈춤을 확인한다.

### Gate 6 — 동일 RC internal TestFlight 48시간

앞선 핵심 gate를 통과한 동일 build로 시작한다. 실제 하루 전환·알람·오프라인/재연결·재시작·구독 상태 갱신을 관찰한다. 반복 일정 장기 경계는 48시간 관찰만으로 검증할 수 없으므로 Gate 1/3의 날짜 테스트로 보완한다.

crash, 일정 유실, 잘못된 삭제, 계정 간 노출, 결제 권한 오류, 알람 중복/누락을 기록한다. blocker 수정이나 모델/프롬프트 등 핵심 경로 변경 시 새 RC로 영향 테스트와 48시간 관찰을 다시 시작한다.

App Store 제출 준비는 별도 체크: 실제 build의 권한 설명·개인정보 고지·AI 처리 제공자·구독 가격/복원/약관·계정 삭제 경로·심사 접근 방법이 서비스와 일치하는지 확인한다. 정책 적합성은 제출 시점 공식 지침으로 재확인한다.

## 5. 결함 우선순위 및 출시 결정

- P0: 계정 간 노출, 일정 유실/의도하지 않은 대량 삭제, 잘못된 결제 귀속 등. 즉시 해당 경로 테스트 중단, 증거 보존 및 수정.
- P1: 핵심 입력·저장·알림·로그인·복원·삭제가 정상 조건에서 실패, 거짓 성공, 반복 일정 오류. 출시 차단.
- P2: 비핵심 UI/접근성/성능 문제. 영향과 우회 가능성을 기록하고 핵심 사용을 막으면 P1로 승격.

최종 GO 조건: P0/P1 미해결 0, 필수 case PASS 및 환경별 증거, 목표 모델의 하네스 출시 평가 통과, 실제 결제/삭제/알람 검증, 동일 RC 48시간 관찰 완료. 필수 환경 미확보 또는 원격 검증 미실시는 BLOCKED다. P2는 사용자가 구체적인 잔여 위험을 확인한 경우에만 수용 목록에 남긴다.

## 6. 다음 실행 기준

통합 PR 검토·merge → 미완료 Apple/Google/ASC 설정·정책 게시 → 지정 계정·실기기 E2E → 별도 Luna LLM 평가 → 동일 RC TestFlight 48시간 → App Store 제출 순서다. 서버는 통합 backend `9423851`에서 이미 배포했다. main은 merge 전 구 모델을 포함하므로 그대로 재배포하지 않는다.

## 7. 2026-09-29 야간 자율 QA 실행안

### N0 — 격리와 대상 고정

준비된 QA checkout: `/Users/gimgihong/.codex/worktrees/mora-night-qa/adhd`. SHA `49add4d065f40cb1a0be186987e9ff89cdb45c05`, 이번 확인 시 미커밋 변경 없음. 이 경로를 재사용하며 기존 Luna checkout에는 pull하지 않는다.

1. GitHub main과 PR #57 상태를 실행 직전에 재조회한다. 새 커밋이 있으면 변경 범위를 읽고 새 RC로 기록한다. 현재 계획 기준은 49add4d다.
2. 이 작업에 연결된 기존 worktree를 확인하고 적절한 checkout을 재사용한다. 없으면 명시적 main SHA로 QA 전용 worktree를 만든다. 현재 미커밋 Luna 작업은 stash/reset/checkout으로 이동하지 않는다.
3. 새 증거 폴더 `outputs/release-qa/<date>-<sha>/`에 manifest, 명령/종료 코드, 로그, xcresult, case-results.csv, defects.md, release-decision.md를 보관한다. 과거 결과는 덮지 않는다.
4. 앱/서버 각각 SHA·함수 버전·hash·모델 설정 유무를 기록한다. secret 값, 계정 토큰, 사용자 데이터는 출력하지 않는다.
5. Moing의 checkout·프로세스·시뮬레이터·Docker·공용 CoreSimulator 서비스를 건드리지 않는다. 사용자의 추가 지시에 따라 켜진 simulator는 MORA 전용 1개로 제한한다. 8GB Mac에서 무거운 작업은 하나씩, xcodebuild jobs=1, Swift compiler -j1/배치 비활성화, index store 비활성화, nice=19로 실행한다. 다른 빌드를 겹쳐 실행하지 않는다.

### N1 — 원격 준비 상태와 실제 계약 확인

- 관리 API로 프로젝트 상태, 함수 4개 배포 여부/version/verify_jwt, 필수 secret **이름**, DNS를 확인한다.
- 배포 analyze-task/delete-account 소스를 별도 폴더로 내려받아 main과 대조한다. 모델 ID 설정·요청/응답·quota·로그·오류 형식을 항목별로 기록한다.
- `release-preflight.sh`는 보조 도구로만 사용한다. 현재 구현은 배포 시각이 커밋보다 새로우면 통과할 수 있으므로, 그것만으로 코드 일치를 인정하지 않는다. 실제 내려받은 소스/hash/동작 계약이 근거다.
- migration 적용 이력은 기존 인증으로 가능한 읽기 전용 경로에서만 조회한다. 접근 불가면 BLOCKED이며 DB 미적용으로 단정하지 않는다. 사용자 테이블 내용은 읽지 않는다.
- 배포 코드의 배열 응답을 합성 fixture로 만들어 최신 앱 decoder가 수용하는지 검증한다. Gemini API는 호출하지 않는다.
- 원격 POST, DB 변경, secret 변경, 함수 배포는 하지 않는다. 알려진 불일치가 남으면 live AI/결제 E2E를 PASS로 처리하지 않는다.

### N2 — 최신 main의 서버 자동 검증

- 실행 전에 import·환경변수·fetch/외부 실행을 점검하고 테스트 대상을 명시한다. 기존 `test/run_test.*` 유료 호출 러너는 제외한다.
- Deno: analysis-service/validator/delete contract + apple-jws/storekit-facts + storekit-sync/app-store-notifications service + log_policy 테스트. Deno 타입 검사도 실행한다.
- JWS 위조·다른 루트·만료·alg 변조, 잘못된 환경/상품/계정, 중복·역순 알림, 거래 등록/복원 오류 매핑을 확인한다. 테스트 PKI 통과는 실제 Apple 거래 성공이 아니다.
- 테스트 의존성 다운로드와 실제 서비스 호출은 구분한다. 실행 권한은 코드가 필요한 최소 범위로 주며 preflight의 `deno test -A`를 검토 없이 그대로 실행하지 않는다.
- `supabase/tests/db/storekit_db_check.py`는 읽어본 뒤 자체 임시 PostgreSQL/Unix socket에서 수행한다. 기존 공유 DB를 사용하지 않는다. 원장 경합·소유권·삭제/재귀속·환경 분리·알림·migration 재적용 결과를 기록한다.
- 테스트 스크립트가 임시 DB를 지우므로 실패 진단이 필요하면 QA 전용 사본에서 로그 보존만 보완한다. 운영 코드 변경과 섞지 않는다.

### N3 — iOS 회귀와 Release artifact

- Debug 앱·위젯 및 ADHDTests를 동일 SHA로 빌드/실행한다. 실제 발견·통과·실패 테스트 수를 xcresult에서 확인한다. 과거 90개를 예상 통과 수로 고정하지 않는다.
- 우선 회귀: 요청 payload 시간/언어 고정(QA-006), 저장 실패 시 입력 유지와 성공 효과 억제(QA-008), 계정 store 격리, 날짜·반복 경계, 파괴적 확인, 구독 오류 매핑.
- 기존 테스트가 실제 보장을 못 하는 부분만 좁은 QA 회귀를 추가한다. `ModelContext` 실패 대역이 실제 앱 UI까지 보장하는 것으로 확대 해석하지 않는다.
- Release archive 생성 후 앱·위젯 서명 무결성, PrivacyInfo.xcprivacy 포함/필수 사유, bundle ID/App Group/버전 일치, 경고를 확인한다. 개발 서명 성공을 ASC 배포 검증 성공으로 보고하지 않는다.
- simulator는 QA 소유 UDID만 사용한다. 부팅/설치/테스트 프로세스를 구분해 관찰하고 일정 시간 진전이 없으면 진단 수집 후 해당 실행만 중단한다. 관찰 timeout만으로 중복 실행을 시작하지 않는다. 제한된 원인 기반 재시도 뒤 같은 환경 문제가 반복되면 BLOCKED로 기록하고 다음 독립 작업으로 간다. 공용 서비스 재시작 금지.

### N4 — 가능한 UI smoke와 제한

- simulator 준비 시 기본 로그인 화면의 한국어/영어/일본어, light/dark, 큰 글자에서 잘림·오류 상태를 관찰한다. 입력 자동화가 필요하면 QA 전용 기기에만 작동하는 도구를 사용한다. 사용자 데스크톱/다른 작업을 방해하면 해당 부분은 보류한다.
- 기존 DEBUG presentation demo가 필요하면 합성 데이터의 시각 검증에만 사용하고 보고서에 DEMO라고 명시한다. 로그인·구독·운영 AI·실제 저장소 격리 통과로 세지 않는다.
- 기존 로그인 세션을 임의 재사용하거나 인증/Pro 플래그를 바꿔 테스트를 통과시키지 않는다.
- 로그인 뒤 전체 UI, 마이크 권한/Apple 인증, 실기기 잠금/알람, Sandbox 구매/복원/환불, 실제 계정 삭제, TestFlight 48시간은 지정 자원/사람 참여 전 BLOCKED/NOT_RUN이다.

### N5 — LLM 평가와 분리

- Luna 하네스는 현재 미커밋 별도 산출물이므로 main 결과와 별도 candidate manifest/hash로 취급한다. main에 없는 eval 파일을 복사하고 main 검증이라고 기록하지 않는다.
- 밤에는 offline 데이터/채점/예산/보고서 검사와 평가 실행안 준비까지만 가능하다. 검수 상태를 확인하되 agent 검토를 human 승인으로 바꾸지 않는다.
- Jev/다른 LLM의 실제 API 호출, Gemini smoke/release는 승인 예산과 검수 데이터가 있어야 시작한다. 기존 $18.48 제안은 승인으로 간주하지 않는다. nightly 앱 QA를 이 승인 대기로 멈추지 않는다.

### N6 — 아침 인계 보고와 정리

- 완료/실패/차단/미실행을 나누고 최신 main의 수정 건은 검증 증거에 따라 재검증 완료 또는 미완료로 갱신한다.
- 알려진 배포 불일치를 반복 발견한 것을 새 결함 수로 부풀리지 않는다. 새 결함에는 SHA·재현·영향·근거·수정 담당을 붙인다.
- 팀원 미인수 변경과 겹치는 모델/페이월/정책 수정은 임의로 덮지 않는다. QA 보조 코드와 재현을 우선 남기고 필요한 제품 patch는 별도 검토 가능한 diff로 분리한다. 자동 머지·운영 배포는 하지 않는다.
- 내가 생성한 빌드·DB·시뮬레이터만 종료하고 종료 상태를 확인한다. Moing 자원은 유지한다.
- 최종 보고는 자동 검증 수, Release 결과, 배포 차이, 새 결함, 사람에게 필요한 최소 행동, 다음 실행 순서를 포함한다. 미완료 필수 gate가 있으면 NO-GO/BLOCKED이며 야간 QA 완료와 출시 승인 완료를 구분한다.

### 밤중 진행의 완료 조건

야간 실행에서 가능한 N0~N3 자동/읽기 전용 검증을 수행하고 N4/N5의 가능·불가 범위를 증거로 기록하며 N6 보고서를 남긴다. 서버 연결/계정/기기 부족으로 미실행된 항목은 그대로 보존한다. 전체 출시 완료 조건은 §5를 따른다.

### 실행 우선순위와 시간 배분

시간은 예상 작업 구간이며 통과 기준이나 강제 종료 시각이 아니다. 시작 시각을 기준으로 기록한다.

| 순서 | 예상 구간 | 결과물 / 다음 단계 조건 |
|---|---|---|
| 1. RC 고정·배포 대조 | 0~30분 | SHA와 함수별 계약 차이. 원격 차단이 있어도 로컬 검증 계속 |
| 2. Deno·격리 DB 회귀 | 30~90분 | 실제 테스트 수·종료 코드·실패 재현. 운영 DB 사용 금지 |
| 3. Swift 회귀·Release archive | 90~210분 | xcresult·서명·manifest 검증. simulator 정체 시 진단하고 archive 등 독립 검증 진행 |
| 4. 가능한 UI 관찰 | 210~300분 | 언어·테마·큰 글자별 증거. 데모 결과와 실제 서비스 결과 구분 |
| 5. 영향 범위 재검증·인계 | 이후 | case-results, defects, release-decision 및 사람에게 필요한 행동 목록 |

밤중 필수 우선순위는 **앱↔서버 계약 불일치 재현 → #62~64 회귀 → Release 빌드 → UI 관찰**이다. LLM/Jev 비용·품질 비교는 별도 평가 트랙으로 유지하며 이 순서를 늦추지 않는다. 실행 시간이 부족하면 범위를 조용히 축소하지 않고 미실행 케이스와 이유를 보고한다.

## 8. 팀원 인수 후 구현·검증 실행 기록

사용자 위임에 따라 모델·페이월·현지화 충돌을 해결하고 서버 계약을 통합했다. AI 동의는 계정별이며 전송 직전에도 세션/철회 여부를 검증한다. 마이크 권한은 사용자 동작 시점에 요청하고 거부 복구·재탭 안내를 제공한다. 미출시 백업 광고를 제거하고 StoreKit 실제 가격·통화로 할인율을 표시한다.

보존 migration은 postgres 소유 cron을 설치하고 bounded cleanup 시 aggregate 감소를 막는다. 배포 도구의 timestamp 판정은 실제 소스 hash 검사로 교체했다. 배포 일부 실패 후 버전만 바뀌는 상황을 발견했으므로 네 함수 모두 다운로드 대조했다.

새 증거와 최종 미완료 목록은 [출시 준비 보고서](MORA_RELEASE_READINESS.md)에 있다. 33개 전체 case·LLM 의미 정확도·실기기 거래·48시간 관찰은 이 통합 smoke만으로 PASS가 되지 않는다.
