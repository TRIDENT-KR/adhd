# MORA App Store 제출 인계서

> 2026-10-29 명칭 정리: 평가 도구의 공식 이름은 [MORA Eval — MORA AI 평가 하네스](tools/mora-eval/README.md)입니다. 이전 작업자 이름을 도구 이름으로 사용하지 않습니다. 기존 로컬 앱·서버·연구 변경도 2026-10-29 통합 대상에 포함했습니다. 아래 미커밋·인수 상태는 작성 당시 이력이며, 현재 구현·검증 상태는 새 하네스 문서를 따릅니다.

> **2026-10-26 운영 갱신:** 성인 확인·AI 원장 migration, `analyze-task` v24 및 `delete-account` v5를 배포했다. Claude 우선 실제 분석은 3개 언어로 성공했다. Gemini 대체 성공은 HTTP 402로 [#68](https://github.com/TRIDENT-KR/adhd/issues/68)에 보류했다. 아래 과거 미배포 기록보다 [서버 배포 보고서](MORA_SERVER_DEPLOYMENT_20261026.md)가 우선한다. 앱 배포·Apple 계정 작업·실기기 검증 완료를 뜻하지 않는다.

> **2026-10-13 갱신:** Claude 우선 → Gemini Flash-Lite 전환과 AI 동의 v2를 구현했다. 최신 배포 순서·검증·미완료 항목은 [출시 전 통합 보고서](MORA_PRELAUNCH_REPORT_20261013.md)를 따른다. 아래 9월 기록의 Gemini 단독 구조와 배포 순서는 현재 기준이 아니다.

> **2026-10-31 갱신:** 앱 안의 18세 확인 화면과 서버의 AI 연령 gate를 없앴다. 18세 이상 조건은 App Store 연령 등급(18+)과 이용약관으로 유지한다. 아래 9/30 기록은 이력이다.
>
> **2026-09-30 구현 갱신:** 18세 이상 성인 대상·Gemini 유지. `adult-v1` 자기확인 UI, 계정별 서버 기록, AI·신규 구매 제한과 개인정보 신고 문안을 구현했다. 자기확인은 신원·실제 나이 검증이 아니다. 새 migration과 AI gate는 아직 운영에 배포하지 않았으며, 공개 정책 게시·ASC 입력·Apple 계정 작업·실기기 검증은 남는다.

계정 작업의 담당·순서·정확한 값은 [계정 설정 인계 체크리스트](MORA_ACCOUNT_SETUP_CHECKLIST.md)를 먼저 본다. 이 문서는 입력 초안·검증 순서다. 현재 제출 승인이 아니다. 최신 상태는 [출시 준비 결과](MORA_RELEASE_READINESS.md)를 따른다. 담당자는 아래 결과를 확인한 뒤 ASC에 입력하며, 아직 없는 심사 계정이나 테스트 결과를 만들었다고 기재하지 않는다.

**이전 검증:** 2026-09-29 [재감사 조치](MORA_APP_STORE_REVIEW_AUDIT.md)의 삭제 복구·구독 순서·위젯 안내·게스트 경로·OSS 등을 구현했고 구독 서버를 v2로 배포했다. 당시 Swift111/Deno60/DB68 회귀를 통과했다. 이를 이번 성인 확인 구현의 새 검사로 세지 않는다. **이번 서버 회귀는 Deno61개(성인 확인 9개 하위 검사 포함), 격리DB86개가 통과했다.** 실제 Apple 구매·복원·삭제, 서명·업로드 및 실기기 완료 증명은 아니다. ASC는 실제 값을 확인하지 못했고 [3언어 스토어 문안](MORA_STORE_METADATA.md)은 입력 초안이다.

사용자용 짧은 실행표는 [출시 준비 결과의 남은 일](MORA_RELEASE_READINESS.md#남은-일을-쉽게-정리하면)을 따른다. 현재 AI 구성은 Claude 우선, Gemini 3.5 Flash-Lite 대체이며 운영 서버 배포는 2026-10-26 완료했다. Gemini 대체 성공은 결제 문제 해결 후 검증한다.

## Apple 계정 작업 — 이번 작업에서는 보류

사용자 요청에 따라 아래 계정 내부 입력·계약·인증서 발급·업로드는 이번 작업에서 진행하지 않았다. 이후 소유자가 처리할 실행 순서이며, 완료 상태가 아니다.

1. Apple Developer의 Sign in with Apple 키와 Team ID/Key ID/Bundle ID를 확인해 `APPLE_CLIENT_SECRET` JWT를 발급한다. Bundle ID/client ID는 `trident-KR.ADHD`다. 유효기간·갱신 담당자를 기록하고 Supabase Edge Function secret으로 설정한다. private key/JWT를 Git이나 채팅에 남기지 않는다. 설정 후 `release-preflight.sh`를 다시 실행한다.
2. App Store Connect → Business/계약·세금·은행에서 유료 앱 계약이 활성인지 확인한다. 법적 계약·세금/은행 제출은 소유자가 직접 한다.
3. 앱 → 구독에서 월간/연간 상품 ID와 지역별 실제 가격, 판매 가능 여부, 구독 그룹 및 심사용 스크린샷을 확인한다. “클라우드 백업 (출시 예정)”과 고정 “40% 절약” 문구를 제거한다. **알람·위젯은 현재 main에서 Pro 혜택이므로 제거하지 않는다.**
4. 앱 정보 → App Store 서버 알림의 Production·Sandbox URL을 모두 `https://nmjtswtqwwxxwiolgsnk.supabase.co/functions/v1/app-store-notifications`로 지정한다. Version 2를 사용하며 Apple의 테스트 알림을 보내 수신 결과를 확인한다.
5. 두 개의 Sandbox Apple 계정·두 개의 Mora QA 계정 및 삭제 전용 계정을 지정한다. 한 기기/계정만으로 구매 귀속·복원·삭제 후 재귀속을 통과 처리하지 않는다.

## 성인 확인 배포 순서

1. `202609300002_mora_adult_eligibility.sql`을 먼저 적용해 인증 계정의 `get_adult_eligibility`/`accept_adult_eligibility` RPC를 준비한다.
2. 명시적인 계정별 18세 이상 자기확인 화면을 포함한 호환 앱을 제공하고 RPC 연결·계정 전환을 확인한다. 게스트의 기기 내 응답이 로그인 계정의 서버 승인으로 복사되지 않는다.
3. 이후 `analyze-task`의 서버 gate를 배포한다. 미확인·구버전 기록은 한도 예약·캐시 재생·Gemini 호출 전에 403 `adult_eligibility_required`, 조회 실패는 503으로 차단한다. **확인 UI 없는 기존 앱보다 gate를 먼저 배포하면 AI 사용이 막힌다.**

새 migration과 gate는 2026-10-26 운영 배포했다. 상세 계약·보관·회귀는 [서버 성인 확인 문서](supabase/ADULT_ELIGIBILITY.md)를 따른다. 서버의 기존 구독 동기화·복원·권한 조회·계정 삭제는 자기확인이 없어도 유지한다. 앱의 제한 화면에서는 Apple 구독 관리·탈퇴·지원에 접근할 수 있고 신규 구매는 앱에서 확인 후 진행한다.

## 개인정보·연령·메타데이터

- **제품 방향 (2026-10-31 변경): 18세 이상 성인 대상은 유지하되, 앱 안의 연령 확인 화면은 없앤다.** 18세 이상 조건은 App Store 연령 등급(18+ override)과 이용약관으로 둔다. 앱은 연령을 묻지 않고, 서버도 AI 분석 전에 연령 기록을 요구하지 않는다(`analyze-task`는 계정 환경 연결·삭제 잠금만 먼저 확인). Gemini 약관(18세 미만 대상·이용 가능성이 높은 앱 금지)을 스토어 등급만으로 충족하는지는 법률 확인이 필요하다.
- 이전 버전이 만든 서버 연령 기록(`mora_internal.adult_eligibility`)은 그대로 두며 계정 삭제 purge 때 함께 지워진다. 새 계정은 이 기록을 만들지 않는다.
- [웹 정책 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1)의 성인 대상·Gemini 처리·자기확인 설명을 검토해 게시한다. 초안 수정과 공개 반영은 다르다. 게시 후 support/privacy/terms 실제 접근과 앱 링크의 일치를 확인한다.
- ASC App Privacy 응답은 계정 식별자·Apple relay 이메일(받는 경우), 구독 구매 정보, AI 사용자 입력·결과, 계정별 사용량·최소 운영/진단 기록의 실제 처리 방식에 맞춘다. 새 버전은 연령 응답을 수집하지 않는다. 앱 manifest에는 `NSPrivacyCollectedDataTypeOtherDataTypes`를 **사용자 연결 있음 / 추적 없음 / 앱 기능 목적**으로 추가했다. ASC에도 Other Data Types와 자기확인 용도를 반영해야 하며 아직 입력하지 않았다. “데이터를 수집하지 않음” 또는 “음성은 무조건 기기 내에서만 처리”라고 일괄 표기하지 않는다.
- 앱 설명·스크린샷에는 이미 구현된 일정/루틴/수동 입력/AI 분석/알림만 설명한다. 의료 진단·치료 효능, 알람 전달 보장, 클라우드 백업, 고정 할인율을 주장하지 않는다.
- 현재 소스의 앱 버전은 1.0, build 5다. 기존 build 4 서명 archive는 개발 프로파일의 Time Sensitive 권한 누락으로, 자동 갱신은 Xcode 팀 계정 로그인 부재로 실패했다. 과거 build 3의 개발 서명 성공이나 build 4의 무서명 archive를 build 5 배포 증거로 사용하지 않는다. 이후 Xcode 팀 로그인, App ID의 Time Sensitive capability·개발 프로파일 갱신, Apple Distribution 인증서와 `trident-KR.ADHD`, `trident-KR.ADHD.ADHDWidget`의 App Store 프로파일을 준비해 다시 archive/export한다. 인증서 생성·약관 수락·업로드는 이번 작업에서 보류했다.

## 구독 설명 초안

한국어:

> Mora는 18세 이상을 위한 서비스입니다. Mora Pro는 AI 일정 분석과 Pro 알람·위젯 기능을 제공합니다. 월간 또는 연간 구독을 선택할 수 있으며 가격과 갱신 기간은 구매 화면에서 확인할 수 있습니다. 구독은 자동 갱신되며 Apple 계정의 구독 설정에서 관리·취소할 수 있습니다. 이미 구독한 사용자는 Pro 구독 화면에서 구매를 복원할 수 있습니다. 알림과 전체 화면 알람은 기기의 지원 여부 및 권한·설정에 따라 동작합니다.

영어:

> Mora is for adults aged 18 and older. Mora Pro includes AI task analysis and Pro alarm and widget features. Monthly and annual plans are available; the purchase screen shows the current price and renewal period. Subscriptions renew automatically and can be managed or cancelled in your Apple account subscription settings. Existing subscribers can restore purchases from the Pro subscription screen. Notifications and full-screen alarms depend on device support, permissions and settings.

실제 상품명·지역·언어별 메타데이터 길이 제한은 ASC 입력 화면에서 확인한다. 할인 프로모션·체험은 현재 제공한다고 기재하지 않는다.

## 심사 메모 초안 (필수 QA 완료 후 사용)

> Mora is an iPhone task and routine organizer for adults aged 18 and older. The age requirement is set through the App Store age rating (18+) and the Terms of Use; the app does not show its own age question. Mora does not require sign-in. On first launch the app creates an anonymous server identifier (Supabase anonymous sign-in) used only for the server-side AI usage limit and subscription ownership. Mora is not a medical diagnostic or treatment app. Tasks are stored locally on the device; cloud task backup is not offered in this version.
>
> Users can add and edit tasks right away without signing in. AI analysis is optional and needs no sign-in; the app uses an anonymous server identifier for the free allowance and purchases. Before the first analysis, the app explains sharing through Supabase with Anthropic Claude first and Google Gemini as a fallback, and requests separate consent (version 2). Voice transcription uses Apple's speech recognition. After consent, speech is analyzed as soon as the user stops speaking, and typed text is sent when the user taps Send; nothing is sent to an AI provider before consent. Results appear on a confirmation card before they are saved (on by default; with it turned off, an Undo option remains). Users can withdraw AI sharing consent in Settings. The AI only turns requests into tasks and short reminder lines; there is no open-ended chat. The free AI allowance is three successful analyses per day, resetting at midnight Asia/Seoul.
>
> Subscription prices and periods are shown on the Pro screen. Purchases and Restore Purchases work without signing in. A subscription follows the Apple ID: after reinstalling the app or on another device with the same Apple ID, Pro is restored automatically. Pro removes the free daily AI quota; excessive consecutive requests can be temporarily limited. Restore Purchases is available on the Pro screen. Deleting the app does not cancel the App Store subscription; the app provides Apple's subscription management link.
>
> Reminder tone (Settings → Notifications → Reminder Tone): Gentle (default), Buddy, Nudge and Spicy change the wording of the user's own reminders. Only when Spicy is selected, an optional "Allow Swearing" toggle appears; it is off by default, shows a note that the text also appears on the Lock Screen, and uses fixed, pre-written lines with profanity aimed at the user's own reminder. The AI never writes profanity. The age rating answers reflect this option.
>
> Speak control: users can add Mora's "Speak" control to the Lock Screen, Control Center or the Action Button. It only opens the app on the Voice tab; recording starts when the user taps the microphone. It is available to free users.
>
> Firm reminders use time-sensitive notifications for all users. Pro additionally uses system alarms (AlarmKit) for Firm reminders. Full-screen alarms require compatible hardware, iOS support and permissions. The app and widget require iOS 26.2 or later. Please use an iPhone for review.
>
> No sign-in or demo account is required. Use any Sandbox Apple ID to test purchases. Accounts can be deleted in Settings → Delete Account.

위 메모는 호환 앱·서버 gate 배포와 필수 QA를 완료한 뒤 사용한다. ASC의 심사 연락처에는 담당자의 실제 연락처를 입력한다. 심사자가 모든 기능에 접근할 수 있는 실제 경로·필요한 테스트 안내를 별도로 확인한다. DEBUG presentation demo는 Release에서 사용할 수 없고 심사 계정을 대신하지 않는다.

## 실기기 실행 순서

1. 새로 설치하면 연령 질문 없이 온보딩부터 시작하는지, 온보딩→수동 일정 저장→완료→재시작 보존을 확인한다. 로그인 없이 AI 공유 동의 거절 후 수동 저장, 동의 후 AI 일정 생성(무료 3회·4번째 결제 화면), 초안 편집·취소·오프라인/재연결을 확인한다. 설정 → 계정 삭제로 익명 계정의 서버 기록이 지워지고 기기 일정은 남는지 확인한다.
음성 추가 확인: 녹음 후 침묵 상태에서 키보드 전환, 빈 결과 오류 뒤 재시도, Hold 모드 VoiceOver 이중 탭, 문장 끝 날짜·시간을 말한 직후 중지/백그라운드 전환을 확인한다. 자동 회귀만으로 실제 STT·접근성 동작을 통과 처리하지 않는다.

2. Free/Pro 각각 약한 알림·전체 화면 알람·위젯을 foreground/background/앱 종료·잠금에서 확인한다. 실제 전달 시각과 알람 취소/반복 재예약을 기록한다.
3. 로그인 없이 Sandbox 월간 또는 연간 구매 → 앱 재시작 → 앱 삭제 후 재설치 → Pro 자동 유지 → 같은 Apple ID의 다른 기기에서 Pro 유지 → 다른 Apple ID 기기에서는 무료를 확인한다(#76). 취소/pending/만료/grace/환불·역순 알림이 모든 기기에 반영되는지도 검사한다.
4. 폐기 전용 계정에서 활성 구독 안내 → Apple 재인증 → 삭제 진행/실패 재개 → 완료 안내와 게스트 화면 복귀, 해당 계정 로컬/서버 삭제를 확인한다. 실제 사용자의 계정으로 시험하지 않는다.
5. [QA 계획](MORA_RELEASE_QA_PLAN.md)의 나머지 case를 기록하고, MORA Eval의 검수된 LLM 평가를 인수한다. 같은 RC의 internal TestFlight 48시간 관찰을 완료한 뒤 제출한다. 두 기기/48시간은 팀 품질 기준이며 Apple의 일률적 필수 요건은 아니다.

## Git 인수

- 앱 통합 PR을 먼저 검토·merge한다. PR #57을 별도로 통째로 merge하면 main의 정책/서버 변경과 충돌하므로 인수 스냅샷으로 남긴다.
- 최초 하네스 PR에서는 원래 checkout의 미커밋 변경을 보존했다. 후속 통합에서 로컬 변경을 함께 커밋하고 공유 prompt의 동일성 및 강화된 서버 계약을 다시 검증했다.
- main 자동 merge는 저장소 CLAUDE.md의 명시적 제한으로 수행하지 않았다. 앱 통합 PR은 [#65](https://github.com/TRIDENT-KR/adhd/pull/65)이며 검토 후 `gh pr merge 65 --repo TRIDENT-KR/adhd --squash --delete-branch`로 인수할 수 있다. 웹 PR은 성인 대상·자기확인·Gemini·실제 보관 정책 문안을 검토한 뒤 병합·게시한다. 앱 코드 병합만으로 서버 gate나 공개 정책이 배포된 것으로 처리하지 않는다.

최종9/30 앱 검증: Swift121개(실패/건너뜀0), 앱/위젯1.0(5) 무서명 Release archive, 컴파일 경고0. 성인 게이트·거절 재실행·관리 접근은 단일 시뮬레이터 표본 통과. 실제 Apple 구매/탈퇴와 서명은 별도다. 최신 증거는 `outputs/release-readiness/20260930-adult-release/`.
