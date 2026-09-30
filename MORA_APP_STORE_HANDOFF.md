# MORA App Store 제출 인계서

> **2026-09-30 결정 변경:** 성인 전용 출시·Gemini 유지. 아래9/29의 전 연령/AI 교체 계획은 폐기한다. 최신 미완료 항목은 [출시 잔여 점검](MORA_RELEASE_REMAINING_20260930.md)을 따른다. 성인 이용 조건의 앱·약관·스토어 반영은 아직 완료되지 않았다.

이 문서는 입력 초안·검증 순서다. 현재 제출 승인이 아니다. 최신 상태는 [출시 준비 결과](MORA_RELEASE_READINESS.md)를 따른다. 담당자는 아래 결과를 확인한 뒤 ASC에 입력하며, 아직 없는 심사 계정이나 테스트 결과를 만들었다고 기재하지 않는다.

**2026-09-29 구현 갱신:** [재감사 조치](MORA_APP_STORE_REVIEW_AUDIT.md)의 삭제 복구·구독 순서·위젯 안내·게스트 경로·OSS 등을 구현했고 구독 서버를 v2로 배포했다. Swift111/Deno60/DB68 회귀를 통과했다. 이는 실제 Apple 구매·복원·삭제와 실기기 완료 증명이 아니다. 폭넓은 연령을 지원하는 AI 전환·제공자 설정·Apple secret/계약/서명·공개 정책·실기기 QA가 남는다. ASC는 로그인 필요 상태로 실제 값을 확인하지 못했다. [3언어 스토어 문안](MORA_STORE_METADATA.md)은 입력 초안이다.

사용자용 짧은 실행표는 [출시 준비 결과의 남은 일](MORA_RELEASE_READINESS.md#남은-일을-쉽게-정리하면)을 따른다. 아래 심사 문안의 Google Gemini 표기는 현재 구현 기준이며 제공자 전환 후 함께 고친다.

## 소유자가 먼저 처리할 계정 설정

1. Apple Developer의 Sign in with Apple 키와 Team ID/Key ID/Bundle ID를 확인해 `APPLE_CLIENT_SECRET` JWT를 발급한다. Bundle ID/client ID는 `trident-KR.ADHD`다. 유효기간·갱신 담당자를 기록하고 Supabase Edge Function secret으로 설정한다. private key/JWT를 Git이나 채팅에 남기지 않는다. 설정 후 `release-preflight.sh`를 다시 실행한다.
2. App Store Connect → Business/계약·세금·은행에서 유료 앱 계약이 활성인지 확인한다. 법적 계약·세금/은행 제출은 소유자가 직접 한다.
3. 앱 → 구독에서 월간/연간 상품 ID와 지역별 실제 가격, 판매 가능 여부, 구독 그룹 및 심사용 스크린샷을 확인한다. “클라우드 백업 (출시 예정)”과 고정 “40% 절약” 문구를 제거한다. **알람·위젯은 현재 main에서 Pro 혜택이므로 제거하지 않는다.**
4. 앱 정보 → App Store 서버 알림의 Production·Sandbox URL을 모두 `https://nmjtswtqwwxxwiolgsnk.supabase.co/functions/v1/app-store-notifications`로 지정한다. Version 2를 사용하며 Apple의 테스트 알림을 보내 수신 결과를 확인한다.
5. 두 개의 Sandbox Apple 계정·두 개의 Mora QA 계정 및 삭제 전용 계정을 지정한다. 한 기기/계정만으로 구매 귀속·복원·삭제 후 재귀속을 통과 처리하지 않는다.

## 개인정보·연령·메타데이터

- **제품 방향 확정: 18세 이상 제한 없이 최대한 넓은 연령대 출시.** 현 Gemini Developer API와 Google Cloud 생성형 AI의 기본 조건이 맞지 않아 AI 제공 방식을 재선정·전환한다. 어린이까지 포함하는 개인정보·보호자 동의 요건과 스토어 연령 질문도 맞춰야 한다. 사용자 연령 결정은 더 이상 대기 항목이 아니다.
- 새 AI 제공자의 미성년자 이용·개인정보 보관·보호자 동의·결제·판매 지역 조건을 확인한다. OpenAI API는 검토 후보이며 선정·전환 완료 상태는 아니다. Gemini 유료 전환이나 Vertex 연결만으로 해결되지 않는다.
- [웹 정책 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1)을 위 결정과 맞춰 확정·게시한다. 공개 privacy/terms URL이 HTTP 200인지, 앱의 링크와 같은 문서인지 확인한다.
- ASC App Privacy 응답은 계정 식별자·Apple relay 이메일(받는 경우), 구독 구매 정보, AI에 전송/서버에 잠시 보관되는 사용자 입력·결과, 계정별 사용량·최소 운영/진단 기록의 실제 처리 방식과 맞춘다. “데이터를 수집하지 않음” 또는 “음성은 무조건 기기 내에서만 처리”라고 일괄 표기하지 않는다. Apple 음성 인식과 Google 처리 항목을 각 제공자의 실제 조건과 대조한다.
- 앱 설명·스크린샷에는 이미 구현된 일정/루틴/수동 입력/AI 분석/알림만 설명한다. 의료 진단·치료 효능, 알람 전달 보장, 클라우드 백업, 고정 할인율을 주장하지 않는다.
- 앱 버전은 1.0, build 4이다. 최신 서명 archive는 기존 개발 프로파일에 Time Sensitive 권한이 없어 실패했고, 자동 갱신도 Xcode의 팀 계정 로그인 부재로 실패했다. 과거 build 3의 개발 서명 archive 성공을 build 4의 근거로 사용하지 않는다. Xcode에 팀 계정을 로그인하고 App ID의 Time Sensitive capability 및 개발 프로파일을 갱신한다. 배포를 위해서는 Apple Distribution 인증서와 `trident-KR.ADHD`, `trident-KR.ADHD.ADHDWidget`의 App Store 프로파일을 준비한 뒤 다시 export한다. Xcode Organizer에서 권한 있는 Apple 계정으로 서명 관리/배포 절차를 진행할 수 있다. 인증서 생성·약관 수락·업로드는 소유자가 처리한다.

## 구독 설명 초안

한국어:

> Mora Pro는 AI 일정 분석과 Pro 알람·위젯 기능을 제공합니다. 월간 또는 연간 구독을 선택할 수 있으며 가격과 갱신 기간은 구매 화면에서 확인할 수 있습니다. 구독은 자동 갱신되며 Apple 계정의 구독 설정에서 관리·취소할 수 있습니다. 이미 구독한 사용자는 Pro 구독 화면에서 구매를 복원할 수 있습니다. 알림과 전체 화면 알람은 기기의 지원 여부 및 권한·설정에 따라 동작합니다.

영어:

> Mora Pro includes AI task analysis and Pro alarm and widget features. Monthly and annual plans are available; the purchase screen shows the current price and renewal period. Subscriptions renew automatically and can be managed or cancelled in your Apple account subscription settings. Existing subscribers can restore purchases from the Pro subscription screen. Notifications and full-screen alarms depend on device support, permissions and settings.

실제 상품명·지역·언어별 메타데이터 길이 제한은 ASC 입력 화면에서 확인한다. 할인 프로모션·체험은 현재 제공한다고 기재하지 않는다.

## 심사 메모 초안 (필수 QA 완료 후 사용)

> Mora is an iPhone task and routine organizer. It is not a medical diagnostic or treatment app. Sign in with Apple is used for account identity, subscription ownership and server-side AI usage limits. Tasks are stored locally on the device; cloud task backup is not offered in this version.
>
> Users can add and edit tasks manually without an account. Guest schedules and signed-in account schedules are stored separately; users can explicitly copy guest schedules into an account in Settings. AI analysis is optional and requires sign-in. Before the first analysis, the app explains sharing with Supabase and Google Gemini and requests separate consent. Voice transcription uses Apple's speech recognition. Users can review and edit the text before tapping Analyze and withdraw AI sharing consent in Settings. The free AI allowance is three successful analyses per day, resetting at midnight Asia/Seoul.
>
> Subscription prices and periods are shown on the Pro screen. Pro removes the free daily AI quota; excessive consecutive requests can be temporarily limited. Restore Purchases is available there. Account deletion is available in Settings and uses Apple reauthentication. Pending deletion and local cleanup resume after relaunch, and the app displays completion confirmation; deleting a Mora account does not cancel its App Store subscription. The app provides Apple's subscription management link.
>
> Full-screen alarms require compatible hardware, iOS support and permissions. The app and widget require iOS 26.2 or later. Please use an iPhone for review.

ASC의 심사 연락처에는 담당자의 실제 연락처를 입력한다. 심사자가 모든 기능에 접근할 수 있는 실제 경로·필요한 테스트 안내를 별도로 확인한다. DEBUG presentation demo는 Release에서 사용할 수 없고 심사 계정을 대신하지 않는다.

## 실기기 실행 순서

1. 게스트로 온보딩→수동 일정 저장→완료→재시작 보존→AI 로그인 안내/취소를 확인한다. 이후 두 기기에서 Apple 로그인·온보딩, 동의 거절 후 수동 저장, 동의 후 AI 일정 생성, 초안 편집·취소·오프라인/재연결을 확인한다.
음성 추가 확인: 녹음 후 침묵 상태에서 키보드 전환, 빈 결과 오류 뒤 재시도, Hold 모드 VoiceOver 이중 탭, 문장 끝 날짜·시간을 말한 직후 중지/백그라운드 전환을 확인한다. 자동 회귀만으로 실제 STT·접근성 동작을 통과 처리하지 않는다.

2. Free/Pro 각각 약한 알림·전체 화면 알람·위젯을 foreground/background/앱 종료·잠금에서 확인한다. 실제 전달 시각과 알람 취소/반복 재예약을 기록한다.
3. Sandbox 월간 또는 연간 구매 → 앱 재시작 → 다른 기기 같은 Mora 계정 복원 → 다른 Mora 계정 귀속 거부/정책대로 복구를 확인한다. 취소/pending/만료/grace/환불·역순 알림도 검사한다.
4. 폐기 전용 계정에서 활성 구독 안내 → Apple 재인증 → 삭제 진행/실패 재개 → 완료 안내와 게스트 화면 복귀, 해당 계정 로컬/서버 삭제를 확인한다. 실제 사용자의 계정으로 시험하지 않는다.
5. [QA 계획](MORA_RELEASE_QA_PLAN.md)의 나머지 case를 기록하고, Luna의 검수된 LLM 평가를 인수한다. 같은 RC의 internal TestFlight 48시간 관찰을 완료한 뒤 제출한다. 두 기기/48시간은 팀 품질 기준이며 Apple의 일률적 필수 요건은 아니다.

## Git 인수

- 앱 통합 PR을 먼저 검토·merge한다. PR #57을 별도로 통째로 merge하면 main의 정책/서버 변경과 충돌하므로 인수 스냅샷으로 남긴다.
- 원래 checkout의 Luna 하네스는 미커밋 상태를 보존했다. 통합 브랜치와 합칠 때 prompt 추출 전후 동일성 및 운영 모델/서버 계약을 다시 검증한다.
- main 자동 merge는 저장소 CLAUDE.md의 명시적 제한으로 수행하지 않았다. 앱 통합 PR은 [#65](https://github.com/TRIDENT-KR/adhd/pull/65)이며 검토 후 `gh pr merge 65 --repo TRIDENT-KR/adhd --squash --delete-branch`로 인수할 수 있다. 웹 PR은 새 AI 제공자·아동 보호 요건 반영 전 Draft를 유지한다.
