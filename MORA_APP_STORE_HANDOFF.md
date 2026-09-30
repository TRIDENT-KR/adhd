# MORA App Store 제출 인계서

> **2026-09-30 구현 갱신:** 18세 이상 성인 대상·Gemini 유지. `adult-v1` 자기확인 UI, 계정별 서버 기록, AI·신규 구매 제한과 개인정보 신고 문안을 구현했다. 자기확인은 신원·실제 나이 검증이 아니다. 새 migration과 AI gate는 아직 운영에 배포하지 않았으며, 공개 정책 게시·ASC 입력·Apple 계정 작업·실기기 검증은 남는다.

계정 작업의 담당·순서·정확한 값은 [계정 설정 인계 체크리스트](MORA_ACCOUNT_SETUP_CHECKLIST.md)를 먼저 본다. 이 문서는 입력 초안·검증 순서다. 현재 제출 승인이 아니다. 최신 상태는 [출시 준비 결과](MORA_RELEASE_READINESS.md)를 따른다. 담당자는 아래 결과를 확인한 뒤 ASC에 입력하며, 아직 없는 심사 계정이나 테스트 결과를 만들었다고 기재하지 않는다.

**이전 검증:** 2026-09-29 [재감사 조치](MORA_APP_STORE_REVIEW_AUDIT.md)의 삭제 복구·구독 순서·위젯 안내·게스트 경로·OSS 등을 구현했고 구독 서버를 v2로 배포했다. 당시 Swift111/Deno60/DB68 회귀를 통과했다. 이를 이번 성인 확인 구현의 새 검사로 세지 않는다. **이번 서버 회귀는 Deno61개(성인 확인 9개 하위 검사 포함), 격리DB86개가 통과했다.** 실제 Apple 구매·복원·삭제, 서명·업로드 및 실기기 완료 증명은 아니다. ASC는 실제 값을 확인하지 못했고 [3언어 스토어 문안](MORA_STORE_METADATA.md)은 입력 초안이다.

사용자용 짧은 실행표는 [출시 준비 결과의 남은 일](MORA_RELEASE_READINESS.md#남은-일을-쉽게-정리하면)을 따른다. 출시 모델은 Gemini 3.5 Flash-Lite다. AI 제공자 교체는 현재 작업 범위가 아니다.

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

새 migration과 gate는 모두 아직 미배포다. 상세 계약·보관·회귀는 [서버 성인 확인 문서](supabase/ADULT_ELIGIBILITY.md)를 따른다. 서버의 기존 구독 동기화·복원·권한 조회·계정 삭제는 자기확인이 없어도 유지한다. 앱의 제한 화면에서는 Apple 구독 관리·탈퇴·지원에 접근할 수 있고 신규 구매는 앱에서 확인 후 진행한다.

## 개인정보·연령·메타데이터

- **제품 방향: 18세 이상 성인 대상, Gemini 유지.** 앱은 `adult-v1` 자기확인을 받으며 미성년 응답 뒤에는 일반 기능 사용을 제한한다. 생년월일·신분증을 수집하지 않는 자기신고이므로 실제 나이·신원 검증이나 공급자 조건 충족을 보장한다고 설명하지 않는다. 성인 표시만으로 검증 완료 처리하지 않고 Google 프로젝트의 유료 데이터 조건·판매 지역·요청 한도도 확인한다.
- 서버는 계정 UUID·정책 버전·확인 시각만 기록한다. 거절 응답은 서버에 저장하지 않으며 탈퇴 데이터 purge 단계에서 승인 기록을 삭제한다. 앱의 게스트/계정별 로컬 응답과 기기 제한 상태는 별도로 관리하며, 로그아웃·계정 전환으로 미성년 응답이 승인으로 바뀌지 않는다.
- [웹 정책 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1)의 성인 대상·Gemini 처리·자기확인 설명을 검토해 게시한다. 초안 수정과 공개 반영은 다르다. 게시 후 support/privacy/terms 실제 접근과 앱 링크의 일치를 확인한다.
- ASC App Privacy 응답은 계정 식별자·Apple relay 이메일(받는 경우), 구독 구매 정보, AI 사용자 입력·결과, 계정별 사용량·최소 운영/진단 기록과 성인 자기확인 기록의 실제 처리 방식에 맞춘다. 앱 manifest에는 `NSPrivacyCollectedDataTypeOtherDataTypes`를 **사용자 연결 있음 / 추적 없음 / 앱 기능 목적**으로 추가했다. ASC에도 Other Data Types와 자기확인 용도를 반영해야 하며 아직 입력하지 않았다. “데이터를 수집하지 않음” 또는 “음성은 무조건 기기 내에서만 처리”라고 일괄 표기하지 않는다.
- 앱 설명·스크린샷에는 이미 구현된 일정/루틴/수동 입력/AI 분석/알림만 설명한다. 의료 진단·치료 효능, 알람 전달 보장, 클라우드 백업, 고정 할인율을 주장하지 않는다.
- 현재 소스의 앱 버전은 1.0, build 5다. 기존 build 4 서명 archive는 개발 프로파일의 Time Sensitive 권한 누락으로, 자동 갱신은 Xcode 팀 계정 로그인 부재로 실패했다. 과거 build 3의 개발 서명 성공이나 build 4의 무서명 archive를 build 5 배포 증거로 사용하지 않는다. 이후 Xcode 팀 로그인, App ID의 Time Sensitive capability·개발 프로파일 갱신, Apple Distribution 인증서와 `trident-KR.ADHD`, `trident-KR.ADHD.ADHDWidget`의 App Store 프로파일을 준비해 다시 archive/export한다. 인증서 생성·약관 수락·업로드는 이번 작업에서 보류했다.

## 구독 설명 초안

한국어:

> Mora는 18세 이상을 위한 서비스입니다. Mora Pro는 AI 일정 분석과 Pro 알람·위젯 기능을 제공합니다. 월간 또는 연간 구독을 선택할 수 있으며 가격과 갱신 기간은 구매 화면에서 확인할 수 있습니다. 구독은 자동 갱신되며 Apple 계정의 구독 설정에서 관리·취소할 수 있습니다. 이미 구독한 사용자는 Pro 구독 화면에서 구매를 복원할 수 있습니다. 알림과 전체 화면 알람은 기기의 지원 여부 및 권한·설정에 따라 동작합니다.

영어:

> Mora is for adults aged 18 and older. Mora Pro includes AI task analysis and Pro alarm and widget features. Monthly and annual plans are available; the purchase screen shows the current price and renewal period. Subscriptions renew automatically and can be managed or cancelled in your Apple account subscription settings. Existing subscribers can restore purchases from the Pro subscription screen. Notifications and full-screen alarms depend on device support, permissions and settings.

실제 상품명·지역·언어별 메타데이터 길이 제한은 ASC 입력 화면에서 확인한다. 할인 프로모션·체험은 현재 제공한다고 기재하지 않는다.

## 심사 메모 초안 (필수 QA 완료 후 사용)

> Mora is an iPhone task and routine organizer for adults aged 18 and older. The app asks for an explicit adult self-attestation, not identity or age-document verification. An under-18 response restricts regular use while account deletion, Apple subscription management and support remain accessible. Sign in with Apple is used for account identity, subscription ownership, account adult eligibility and server-side AI usage limits. Mora is not a medical diagnostic or treatment app. Tasks are stored locally on the device; cloud task backup is not offered in this version.
>
> After local adult self-attestation, users can add and edit tasks manually without an account. Guest schedules and signed-in account schedules are stored separately; users can explicitly copy guest schedules into an account in Settings. A guest answer does not grant account eligibility. AI analysis is optional and requires sign-in and current account adult eligibility. Before the first analysis, the app explains sharing with Supabase and Google Gemini and requests separate consent. Voice transcription uses Apple's speech recognition. Users can review and edit the text before tapping Analyze and withdraw AI sharing consent in Settings. The free AI allowance is three successful analyses per day, resetting at midnight Asia/Seoul.
>
> Subscription prices and periods are shown on the Pro screen. New purchases require current account adult eligibility. Pro removes the free daily AI quota; excessive consecutive requests can be temporarily limited. Restore Purchases is available on the Pro screen, and existing subscription synchronization is preserved. Account deletion uses Apple reauthentication and is accessible from Settings and the restricted-use management screen. Pending deletion and local cleanup resume after relaunch, and the app displays completion confirmation; deleting a Mora account does not cancel its App Store subscription. The app provides Apple's subscription management link.
>
> Full-screen alarms require compatible hardware, iOS support and permissions. The app and widget require iOS 26.2 or later. Please use an iPhone for review.
>
> Sign in with Apple is the only sign-in method, so no separate demo account is required; any Apple ID can be used. On first launch, confirm that you are 18 or older to continue.

위 메모는 호환 앱·서버 gate 배포와 필수 QA를 완료한 뒤 사용한다. ASC의 심사 연락처에는 담당자의 실제 연락처를 입력한다. 심사자가 모든 기능에 접근할 수 있는 실제 경로·필요한 테스트 안내를 별도로 확인한다. DEBUG presentation demo는 Release에서 사용할 수 없고 심사 계정을 대신하지 않는다.

## 실기기 실행 순서

1. 성인 자기확인의 미선택·수락·미성년 응답·재시작·게스트→계정·A→B 전환을 각각 확인한다. 미성년 응답은 별도 테스트 설치에서 검사하고 제한 화면의 계정 삭제·Apple 구독 관리·지원 접근을 확인한다. 서버 미확인·조회 실패에서는 AI·신규 구매가 시작되지 않아야 한다. 성인 게스트로 온보딩→수동 일정 저장→완료→재시작 보존→AI 로그인 안내/취소를 확인한다. 이후 두 기기에서 Apple 로그인·계정 자기확인, AI 공유 동의 거절 후 수동 저장, 동의 후 AI 일정 생성, 초안 편집·취소·오프라인/재연결을 확인한다.
음성 추가 확인: 녹음 후 침묵 상태에서 키보드 전환, 빈 결과 오류 뒤 재시도, Hold 모드 VoiceOver 이중 탭, 문장 끝 날짜·시간을 말한 직후 중지/백그라운드 전환을 확인한다. 자동 회귀만으로 실제 STT·접근성 동작을 통과 처리하지 않는다.

2. Free/Pro 각각 약한 알림·전체 화면 알람·위젯을 foreground/background/앱 종료·잠금에서 확인한다. 실제 전달 시각과 알람 취소/반복 재예약을 기록한다.
3. Sandbox 월간 또는 연간 구매 → 앱 재시작 → 다른 기기 같은 Mora 계정 복원 → 다른 Mora 계정 귀속 거부/정책대로 복구를 확인한다. 취소/pending/만료/grace/환불·역순 알림도 검사한다.
4. 폐기 전용 계정에서 활성 구독 안내 → Apple 재인증 → 삭제 진행/실패 재개 → 완료 안내와 게스트 화면 복귀, 해당 계정 로컬/서버 삭제를 확인한다. 실제 사용자의 계정으로 시험하지 않는다.
5. [QA 계획](MORA_RELEASE_QA_PLAN.md)의 나머지 case를 기록하고, Luna의 검수된 LLM 평가를 인수한다. 같은 RC의 internal TestFlight 48시간 관찰을 완료한 뒤 제출한다. 두 기기/48시간은 팀 품질 기준이며 Apple의 일률적 필수 요건은 아니다.

## Git 인수

- 앱 통합 PR을 먼저 검토·merge한다. PR #57을 별도로 통째로 merge하면 main의 정책/서버 변경과 충돌하므로 인수 스냅샷으로 남긴다.
- 원래 checkout의 Luna 하네스는 미커밋 상태를 보존했다. 통합 브랜치와 합칠 때 prompt 추출 전후 동일성 및 운영 모델/서버 계약을 다시 검증한다.
- main 자동 merge는 저장소 CLAUDE.md의 명시적 제한으로 수행하지 않았다. 앱 통합 PR은 [#65](https://github.com/TRIDENT-KR/adhd/pull/65)이며 검토 후 `gh pr merge 65 --repo TRIDENT-KR/adhd --squash --delete-branch`로 인수할 수 있다. 웹 PR은 성인 대상·자기확인·Gemini·실제 보관 정책 문안을 검토한 뒤 병합·게시한다. 앱 코드 병합만으로 서버 gate나 공개 정책이 배포된 것으로 처리하지 않는다.

최종9/30 앱 검증: Swift121개(실패/건너뜀0), 앱/위젯1.0(5) 무서명 Release archive, 컴파일 경고0. 성인 게이트·거절 재실행·관리 접근은 단일 시뮬레이터 표본 통과. 실제 Apple 구매/탈퇴와 서명은 별도다. 최신 증거는 `outputs/release-readiness/20260930-adult-release/`.
