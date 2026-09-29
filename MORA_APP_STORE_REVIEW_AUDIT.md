# MORA App Store 심사 재감사 — 2026-09-29

**판정: 제출 보류. 필요한 내용이 전부 구현된 상태가 아니다.** 기존의 “구현·배포 수정 완료”는 이전 수정 범위의 완료였으며, 전체 심사 준비 완료를 뜻하지 않는다. 이번 재감사에서 삭제 복구·구독 상태 처리 결함과 위젯 구매 유도 등 추가 문제가 확인됐다.

## 1. 감사 기준과 증거 수준

- 검사한 앱 저장소: `codex/release-readiness-20260929`, HEAD `d6a0d04a745c098dded1298a9e8688a553f8ee16`, 제품 코드 `26a7ac6`. 앱/위젯 1.0 (3).
- [앱 PR #65](https://github.com/TRIDENT-KR/adhd/pull/65)는 감사 시점 미병합. 기준 main은 `49add4d`다. [정책 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1)도 Draft·미병합이며 공개 정책을 바꾸지 않았다.
- 세 독립 검토에서 인증/삭제/개인정보, 결제/구독/위젯, archive/권한/SDK를 나누어 실제 코드·서명된 archive와 공식 문서를 대조했다. 검토 후 주요 경로를 교차 확인했다.
- 이번에는 제품 수정·배포·구매·계정 삭제를 하지 않았다. 시뮬레이터를 부팅하거나 무거운 빌드를 추가하지 않았다. 구독 상태 변환 함수만 합성 입력으로 실행했다.
- **확정 코드 경로**는 코드에서 도달 가능함을 확인했다는 뜻이다. 실제 Apple 거래·실기기 재현과 동일하지 않다. **정책 판단 위험**은 심사자의 해석 영역이며 확정 리젝이라고 쓰지 않는다. **미검증**은 구현 유무와 별개다.
- 이전 Swift 95 / Deno 53 / 격리 HTTP 12 / DB 36 통과와 archive 성공은 유효한 제한적 증거다. 아래 새 실패 순서까지 검사한 결과는 아니다.
- 로컬 증거: `outputs/release-readiness/20260929-app-store-audit/`. 이전 archive/테스트: `outputs/release-readiness/20260929-voice-followup/` 및 `20260929-integration/`.

## 2. 제출 전에 고칠 코드와 내용

우선순위 P1은 제출 전 차단 해소, P2는 제출 전 보완·검증 대상으로 사용한다. Apple이 부여한 등급이 아니다.

### AR-01 · P1 · 삭제 재인증 복구가 막힘 — 확정 코드 경로

`ADHD/AuthManager.swift:415`의 상태 조회 오류 처리에서 `apple_reauth_required`를 오류 문자열로만 기록한다. `applyDeletionServerError`를 호출하지 않아 저장된 `needsAppleReauthentication`이 false로 남는다. 최초 Apple 토큰 교환의 네트워크 실패 → retry_wait → 상태 조회의 재인증 요구 순서에서 `ADHD/MyApp.swift:356`의 재인증 버튼이 나타나지 않는다. 재실행해도 같은 저장 상태를 읽는다.

**조치:** 최초 삭제 요청과 같은 구조화 오류 처리·영구 저장을 적용하고 재인증이 필요하면 polling을 중단한다. **재검증:** 토큰 교환 실패→상태 조회409→Apple 재인증→삭제 완료, 중간 재실행 및 request ID 불일치 거부. Apple은 불필요하게 어려운 삭제 흐름을 허용하지 않으며 Apple 로그인 토큰 해제를 안내한다. [계정 삭제 지침](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

### AR-02 · P2 · 로컬 삭제 실패 후 재실행 복구 정보 소실 — 확정 코드 경로

`ADHD/AuthManager.swift:427`에서 삭제 상태 Keychain을 먼저 지운다. 실제 로컬 파일 제거는 `ADHD/MyApp.swift:274`의 비동기 후속 작업이다. `ADHD/AccountStoreController.swift:192`에서 파일 삭제 실패를 잡지만, 재시도 계정 ID는 `MyApp.swift:28`의 메모리 상태뿐이다. 파일 제거 실패·강제 종료 뒤 다음 실행에서 정리할 계정을 알 수 없다.

**조치:** 로컬 정리 대기 표식을 영구 저장하고 파일·설정·캐시 제거 성공 후 해제한다. 완료 안내도 로컬 정리 결과와 일치시킨다. **재검증:** 파일 제거 오류 주입, 작업 중 종료, 재실행, 다른 계정 로그인 시 데이터 비노출. 서버 삭제 성공을 기기 데이터 정리 성공으로 간주하지 않는다.

현재 삭제 완료는 로그인 화면 복귀로만 표현된다. 명시적인 완료 안내, 지연 시 처리 단계·필요한 행동·예상 처리 안내도 추가한다. 근거 없는 처리 시간을 약속하지 않는다.

### AR-03 · P1 · 앱 새로고침이 결제 유예를 만료로 덮어씀 — 확정 코드 경로 + 함수 실행

`ADHD/SubscriptionManager.swift:640`은 현재 거래를 서버에 다시 등록한다. `supabase/functions/storekit-sync/service.ts:92`는 갱신 정보 없이 거래만 해석한다. `supabase/functions/_shared/storekit-facts.ts:69`는 원래 만료일이 과거이면 expired로 도출한다. `supabase/migrations/202609240001_mora_storekit_sync.sql:201`은 같은 거래 ID면 상태를 무조건 덮어쓴다.

서버 grace → 앱 실행/복원 → 같은 거래 등록 → expired로 바뀌는 경로다. 실제 함수에 같은 거래와 갱신 정보 유무를 달리 주어 grace/expired를 확인했다. Apple의 currentEntitlements에는 결제 유예 중인 거래도 포함된다. **조치:** 거래 단독 증거가 갱신 정보로 확인된 유예를 지우지 않게 상태 갱신 규칙을 고친다. **재검증:** 원래 expiresDate는 과거이고 gracePeriodExpiresDate는 미래인 거래로 알림→앱 갱신→복원 순서를 검사한다. [currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)

### AR-04 · P1 · 옛 거래/알림이 환불 등 최신 상태를 되돌림 — 확정 코드 경로 + 함수 실행

위 SQL의 동일 거래 허용 조건과 `supabase/functions/app-store-notifications/service.ts:15`의 전달 정보에는 최신 서명 시각 비교가 없다. 환불 처리 후 환불 전 유효한 거래 JWS나 다른 UUID의 오래된 알림을 받으면 active로 되돌릴 수 있다. 이것은 Apple 서명 위조 문제가 아니라 유효한 옛 증거의 순서 문제다.

**조치:** 거래/알림의 서명 시각 및 정보 원천을 저장하고 상태 후퇴를 막는다. 새로운 갱신과 정상 환불 철회는 구별한다. **재검증:** 환불→옛 JWS, 새 알림→옛 알림, 같은 UUID 중복, 정상 환불 철회 및 새 거래 갱신. Apple은 같은 거래 알림의 최신 signedDate를 기준으로 처리하도록 설명한다. [signedDate](https://developer.apple.com/documentation/appstoreservernotifications/signeddate)

기존 DB 시험은 단독 상태와 UUID 중복을 주로 검사했고 유예 표본의 만료일도 미래였다. AR-03/04의 순서 조합이 빠져 있었다. 실제 DB 전이·Sandbox 전체 재현은 아직 하지 않았다.

### AR-05 · P1 · 위젯의 직접 구매 유도 — 확정 구현 / 높은 심사 위험

`ADHD/ADHDWidget/WidgetLockedView.swift:12`가 위젯 전체를 `mora://paywall`에 연결하며 `WidgetDesignSystem.swift:202`는 “탭해서 업그레이드”를 표시한다. 확장 프로그램 내 마케팅을 제한하는 4.4와 직접 충돌할 위험이 있다. **조치:** 위젯은 중립적 상태 안내·일반 앱 열기로 바꾸고 업셀은 본앱으로 옮긴다. 잠금 화면 및 모든 위젯 크기에서 확인한다. [4.4 Extensions](https://developer.apple.com/app-store/review/guidelines/#extensions)

### AR-06 · P2 · 구독 인식 실패 시 해지 안내도 숨겨짐 — 확정 UI 누락

`ADHD/SettingsView.swift:129,537`은 앱의 `isPremium`이 참일 때만 구독 관리 링크와 계정 삭제 후 구독 유지 경고를 보여 준다. 서버 연결 실패·귀속 불일치·결제 재시도 중에는 Apple 구독이 남아도 앱이 false일 수 있다. **조치:** 구독 관리 링크와 일반적인 삭제 전 구독 안내를 항상 제공한다. **재검증:** 서버 장애, 다른 Mora 계정, 만료/유예 상태에서 링크 접근 및 삭제 진행. [삭제와 자동 갱신 구독](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

### AR-07 · P2 · 알림 권한 설정 누락 — archive에서도 확인

`ADHD/NotificationManager.swift:325`는 strong 알림과 AlarmKit 폴백에 `.timeSensitive`를 쓰지만 앱 entitlements와 실제 archive에 `com.apple.developer.usernotifications.time-sensitive`가 없다. **조치:** Time Sensitive capability와 배포 프로파일을 일치시킨다. **재검증:** 실기기에서 Focus·Time Sensitive 허용/거부, 무료 strong 및 AlarmKit 폴백. AlarmKit 자체가 모두 실패한다는 뜻은 아니다. [Apple 설정 안내](https://developer.apple.com/videos/play/wwdc2021/10091/)

### AR-08 · P2 · 실패 안내·현지화·라이선스 마무리

- `ADHD/AuthManager.swift:707`의 Apple 로그인 서버 실패는 콘솔에만 남고 `LoginView.swift`에 실패·재시도 설명이 없다. 사용자 취소와 서버/네트워크 실패를 나누어 세 언어로 안내한다.
- `ADHD/SubscriptionManager.swift:863`의 구매/복원 오류가 한국어로 고정돼 있다. 영어·일본어 실패 경로도 번역한다.
- `ADHD/Info.plist:5`의 AlarmKit 권한 설명은 영어만 있고 “never miss”라는 보장 표현이 있다. KO/EN/JA로 실제 목적과 권한 의존성을 일치시킨다. `LoginView.swift:25`의 접근성 설명도 현지화 대상이다.
- 위젯의 실제 표시 이름은 `ADHDWidget`이고 설정·온보딩·일부 AppIntent 안내에는 영어 리터럴이 남았다. Mora 이름과 지원 언어를 시스템 노출까지 맞춘다.
- 결제 성공 후 페이월의 기존 시작 버튼이 남는 흐름은 활성화 완료 표시/닫기로 정리한다. 실제 중복 청구가 확인된 것은 아니다.
- archive에 연결된 MIT/Apache 계열 SDK의 LICENSE/NOTICE 고지가 없다. 실제 포함 라이브러리 기준 오픈소스 고지를 묶어 배포한다. 미링크 RevenueCat까지 실제 수집 SDK로 신고하지 않는다.
- `AuthManager.swift:680,727`은 사용하지 않는 이름 scope를 요청한다. 불필요한 요청을 제거한다. 서버에 이름을 저장한다는 근거는 확인하지 못했다.

## 3. 제품·개인정보 판단을 확정할 것

### AR-09 · 로그인 강제와 OS 기능 과금 — 판단 위험

로그아웃 시 `ADHD/MyApp.swift:136`은 로그인 화면만 표시한다. 수동 일정은 로컬 저장인데 게스트 경로가 없다. AI·구독에 계정 기능이 있어 자동 위반이라 단정할 수는 없지만 5.1.1(v) 판단 위험을 줄이려면 **기본 수동 일정·로컬 알림은 로그인 없이, AI·계정 구독 연결은 로그인 후**로 분리하는 것을 권고한다. 게스트 데이터의 로그인 시 이전·로그아웃·삭제·계정 격리를 함께 설계해야 한다. 단순 버튼 추가로 끝내지 않는다. [5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)

무료 일반 알림은 이미 있다. 다만 Pro 전체 화면 알람·모든 위젯을 OS 기능 이용권처럼 설명하는 부분은 4.10 판단 위험이다. **유료 위젯이 모두 금지라고 단정하지 않는다.** 기본 알림 제공 여부와 앱 고유의 유료 기능·지속적인 AI 서비스 가치를 명확히 설명한다. 기본 기능의 무료 범위 확대가 필요한지 검토한다. [4.10](https://developer.apple.com/app-store/review/guidelines/#monetizing-built-in-capabilities)

### AR-10 · Gemini 대상 연령·요금제·판매 지역 — 결정 및 설정 미확인

현재 Gemini API 조건은 18세 미만을 대상으로 하거나 이용 가능성이 있는 API Client를 제한한다. 공개 정책과 수정 초안은 아직 13세 미만만 제외한다. **대상 연령 결정은 여전히 필요하다.** 18세 이상 서비스로 운영하려면 앱 진입·AI 이용 조건, 약관, 마케팅, 지역별 스토어 등급을 함께 맞춰야 한다. 등급 숫자만 바꿔 적합성을 보장하지 않는다. 청소년을 포함하려면 제공 경로를 다시 검토한다.

Google 프로젝트의 활성 billing, 무료/유료 데이터 이용 조건, 지원 지역도 미확인이다. EEA·영국·스위스 제공에는 Paid Services 조건이 있고, 무료 조건은 입력/응답 개선 이용·인적 검토 가능성이 있어 개인정보가 들어가는 일정 서비스에 그대로 적용하면 안 된다. [Gemini API 조건](https://ai.google.dev/gemini-api/terms)

ASC의 연령 질문에는 실제 기능을 답하고, 약관 최소 연령이 계산 등급보다 높으면 상향 규칙을 적용한다. 한국 등 지역별 표시 등급은 별도 확인한다. [Apple 연령 설정](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating)

### AR-11 · 공개 정책 불일치와 보관/신고 공백

오늘 실제 URL을 조회했다. `/privacy/`와 `/terms/`는 HTTP 200이지만 다음의 오래된 내용을 제공한다.

| 현재 공개 내용 | 실제 코드/운영과의 차이 |
|---|---|
| AI 제공자 OpenAI / Anthropic | 현재 Supabase → Google Gemini |
| 원본 오디오 기기 내 처리만 | Apple 음성 인식은 서버 처리가 가능 |
| 태스크 저장/동기화, 클라우드 백업 | 이번 버전은 로컬 일정, 클라우드 백업 없음 |
| 계정 삭제 시 즉시 전체 삭제 | 단계별 삭제, 일부 운영/거래 기록 보관, 현재 삭제 secret 부족 |
| 오류 로그 최대 30일 | 코드의 기록별 보존 기간과 다름 |
| 고정 달러 가격·월 환산액 | 지역별 실제 StoreKit 가격 사용 |

정책 PR #1도 연령뿐 아니라 이번에 발견한 보관 차이를 반영한 후 게시해야 한다. `202608040001_mora_security_contracts.sql:1307`은 삭제된 사용자의 거래 원장에서 계정 ID·토큰만 비운다. 거래 ID·상품·날짜는 남으며 이 테이블에는 만료 정리가 없다. 재연결 표식의 최대400일과 별개다. **최소 보관 필드·기간·목적을 확정하고 코드와 정책을 맞춘다.** 계정 연결 해제를 완전 익명화로 단정하지 않는다.

앱 manifest에는 이메일·User ID·사용자 콘텐츠·구매·진단이 선언돼 있다. 서버의 계정별 분석 횟수와 분석 이벤트는 Usage Data 분류를 추가 대조한다. Apple 음성 인식의 Audio Data 처리, 입력에 포함될 건강/민감 정보, 운영 로그의 실제 항목도 함께 확인한다. 실제 ASC 답변을 읽지 못했으므로 “스토어 신고 누락 확정”으로 표시하지 않는다. 앱 manifest가 ASC Privacy 답변을 대신하지 않는다. [App Privacy 데이터 정의](https://developer.apple.com/app-store/app-privacy-details/)

루트 `https://trident-kr.github.io/waitwhat-site/`는 **404**다. 현재 ASC Support URL이 이 주소인지 모르므로 그 설정이 잘못됐다고 단정하지 않는다. 정상 지원 페이지와 문의 연락처를 마련해 실제 등록 URL을 확인한다. 공개 정책의 헤더도 루트로 연결되어 있다.

## 4. 외부 설정·실제 거래 검증 — 현재 확인할 수 없는 항목

App Store Connect 앱 목록에 직접 접근했으나 Apple 로그인 화면이 표시됐다. 계정 정보 입력·계약 수락·설정 변경을 하지 않았다. 아래 항목을 “완료”라고 쓸 근거가 없다.

| 항목 | 상태 / 완료 증거 |
|---|---|
| Apple 토큰 revoke secret | **누락 재확인.** secret 이름만 조회한 결과 APPLE_CLIENT_SECRET 없음. 나머지 client ID/bundle ID/deletion secret/model/key 이름 존재. 값을 노출하지 않음 |
| 배포 서명 | 이전 App Store export가 앱·위젯 프로파일 부족으로 실패. 개발 서명 archive와 구별. 배포 인증서/프로파일·App Group/Apple 로그인/Time Sensitive 포함 확인 |
| 유료 앱 계약·세금·은행 | ASC 미확인. Account Holder의 계약/지급 정보 완료 필요 |
| 두 구독 상품 | 월간·연간 ID, 판매 지역·가격, 같은 혜택이면 같은 그룹/수준, 설명·심사용 screenshot·가족 공유 꺼짐 확인. 로컬 StoreKit 파일만으로 ASC 상태 판정 불가 |
| 최초 구독 심사 | 최초 자동 갱신 구독 및 구독 그룹을 앱 버전과 같은 제출에 포함했는지 확인. [Apple 제출 절차](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/) |
| 서버 알림 V2 | Production/Sandbox URL과 실제 Apple 테스트 알림 수신 확인. 함수 배포/잘못된 서명 차단은 연결 성공의 증거가 아님 |
| 상품 구매·복원 | 지정 Sandbox 계정으로 두 기간, 사용자 취소/pending, 재설치/다른 기기, 계정 귀속 충돌, 유예·만료·환불·환불 철회·삭제 후 재연결 검증 |
| Apple 로그인·삭제 | 신규/재로그인/오프라인 오류, 재인증→revoke→서버/기기 삭제→완료, 실패 후 재개, 다른 기기 잔존 데이터 처리 확인 |
| 개인정보·연령·판매 지역 | App Privacy 답변/정책 URL/새 연령 질문/Google 조건 일치. EU 배포 시 DSA 지위·필수 검증도 확인. [DSA 안내](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements) |
| 수출 암호화 | 실제 포함 SDK까지 검토해 ASC 질문에 답변. plist 키 없음 자체가 확정 리젝은 아님. [암호화 안내](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) |
| 메타데이터 | 앱 이름/카테고리/저작권/실제 연락처/지원URL/프라이버시URL/설명·검색어·스크린샷·구독의 유료 표시. 의료 진단·치료 효과나 알람 전달 보장·백업 등 미구현 주장 금지 |
| 심사자 접근 | 깨끗한 설치에서 Apple 로그인·동의 거절 수동 입력·AI 생성·구매/복원·삭제·권한 거부를 접근할 실제 경로 제공. DEBUG 데모는 Release에 없어 심사 접근 대체 불가. 하루 무료3회 제한도 설명 |
| TestFlight·빌드 선택 | 배포용 export→업로드→처리/검증 오류 없음→검증한 정확한 build를 버전에 선택. 아직 미실시 |

## 5. 확인된 구현과 남은 검증 범위

| 범위 | 확인한 것 | 남은 것 / 판정 |
|---|---|---|
| AI 외부 전송 | 별도 opt-in, 제공자·전송 필드 고지, 계정별 동의·철회·전송 직전 검사 | 공개 정책·Google 프로젝트·실제 앱 E2E 필요 |
| 음성 권한 | 마이크 행동에서 요청, 거부 시 텍스트 대안, 초안 검토 뒤 분석 | 실제 한국어/영어/일본어 음성·끝부분 날짜 보존, Hold VoiceOver, 백그라운드·통화 중단 |
| 서버 AI | 목표 모델 성공, 서버 무료quota3회·재전송 무차감, 사용자 인증 | Luna의 검수된 의미 평가 및 실제 앱 저장까지는 별도 |
| 가격/약관 | 실제 통화 가격, 연간 총액 우선, 할인 계산, 기간·자동 갱신·복원·링크 | 오류 번역/성공 UX, 공개 정책, ASC 상품, 실거래 |
| 앱/SDK privacy | 앱·위젯 및 swift-crypto manifest 포함, UserDefaults 사유, tracking=false | 수집 분류/실제 ASC 응답·공급자 조건 대조 |
| 빌드 요구사항 | archive SDK26.5·최소 iOS26.2, 앱/위젯1.0(3), 서명 검증 | 배포 서명 및 서버/코드 수정 뒤 새 RC. [현재 SDK 요구사항](https://developer.apple.com/news/upcoming-requirements/) |
| 백그라운드/공개 API | 불필요한 background mode/임의 ATS 예외/숨은 Release demo는 확인되지 않음 | 실제 잠금·종료 상태 알람과 자원 사용 |
| 기기/네트워크 | iPhone용 빌드·시뮬레이터 표본 | 최소OS/최신OS, iPad iPhone 호환 모드, IPv6-only, 느린망·오프라인·재시도·시간대/DST |
| 일정/루틴 | 날짜·삭제 범위 등 자동 회귀 | 처음 설치/빈 데이터/중복/편집/완료/반복/실행 취소와 계정 전환 전체 흐름 |
| 접근성/화면 | 큰 글자·JP 화면 일부, Hold 접근성 동작 구현 | 실제 VoiceOver·최대 글자·밝음/어두움·작은 화면·키보드·모든 모달. 지원하지 않은 기능을 ASC accessibility claim으로 제출하지 않음 |
| 보존/운영 | 정리 cron 설치와 소유자/주기 검증 | 실제 성공 실행 이력·기한 지난 데이터 제거, 거래 원장 보존 차이 해소 |
| UGC/의료/광고 | 공개 게시·사용자 채팅·HealthKit·광고/추적 SDK 흐름 없음 | 일반 SNS의 신고/차단 기능을 무조건 요구하지 않음. 개인 AI의 안전성·오류 안내는 별도 평가. 진단/치료 앱으로 홍보하지 않음 |

**48시간 internal TestFlight 관찰과 두 물리 기기는 팀의 출시 품질 기준이다. Apple이 모든 앱에 일률적으로 요구하는 심사 조건이라고 설명하지 않는다.** iPhone-only 선언만으로 iPad 호환 동작 확인을 생략하지 않는다. 100% 심사 승인을 보장하지 않으며, 실제 미검증을 정적 코드 확인으로 대체하지 않는다.

## 6. 다음 작업 순서와 종료 조건

1. **코드/서버 결함부터:** AR-01~04 삭제·구독 전이 수정 및 실패 순서 회귀. 원장 변경은 추가 migration으로 작성하고 운영 데이터 보존·역호환을 확인한다.
2. **심사 노출 정리:** AR-05~08 위젯 업셀 제거, 항상 접근 가능한 구독 관리, 알림 capability, 실패 현지화·완료 안내·OSS 고지. 게스트/유료 기능 범위를 확정한다.
3. **개인정보 계약 일치:** 대상 연령·Google 요금제/지역 확인, AR-11 보관 정책·manifest·ASC 답변·공개 문서를 같은 사실로 맞춘다. Pro는 일일횟수 무제한이지만 서버30회/분 보호 제한이 있으므로 “모든 제한 제거” 표현도 정밀하게 고친다.
4. **외부 연결과 거래:** APPLE_CLIENT_SECRET·서명·ASC 상품/서버 알림을 준비하고 지정 계정의 실제 Apple E2E를 완료한다. secret/key를 채팅이나 Git에 넣지 않는다.
5. **새 RC 검증:** 수정한 코드/서버 SHA를 고정하고 자동 회귀, 한 대씩 시뮬레이터 UI, 실제 음성·알람·위젯·결제·삭제, LLM 평가, 동일 RC TestFlight 관찰을 수행한다.
6. **제출 패키지:** 정확한 build·구독/그룹·공개 정책·심사 메모·지원 연락처를 함께 확인하고 미해결 P1이 없는 상태에서 제출한다. 저장소 규칙에 따라 main merge는 담당자가 한다.

사람의 입력이 필요한 것은 대상 연령 결정, Apple/Google 소유자 계정 설정·계약·인증, 실제 기기 관찰이다. 코드 수정·회귀·문서 정합성·제출 체크리스트 관리는 Codex 작업 범위로 남긴다. 이번 감사에서는 이 항목들을 완료한 것으로 표시하지 않았다.
