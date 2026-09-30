# Mora 계정 설정 인계 체크리스트

2026-09-30 작성 · 담당 이연재 · 최종 심사 제출은 김기홍 확인 후

코드는 main에 들어가 있고, 남은 출시 작업은 대부분 Apple·Google·Supabase 계정 안에서 해야 하는 일이다. 이 문서는 그 작업을 순서대로 적은 것이다. 값은 모두 2026-09-30에 저장소와 운영 서버에서 직접 확인했다. 확인하지 못한 것은 "확인 필요"로 표시했다.

**보안 원칙:** `.p8` 키, `APPLE_CLIENT_SECRET`, Gemini API 키, DB 비밀번호는 Slack·채팅·Git·스크린샷에 남기지 않는다. 팀 비밀번호 관리자에만 보관한다.

## 0. 현재 상태 (2026-09-30 확인)

| 항목 | 상태 |
|---|---|
| 앱 코드 | [PR #65](https://github.com/TRIDENT-KR/adhd/pull/65) main 머지. 심사 대비 선제 수정은 브랜치 `fix/mora-review-preflight` |
| 공개 웹 | [웹 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1) 머지·게시. 지원·개인정보·약관 페이지가 머지본과 동일 |
| App Store 공개 이력 | 없음. 한국·미국·일본 스토어에서 번들 ID 조회 결과 0건 |
| Supabase 프로젝트 `nmjtswtqwwxxwiolgsnk` | ACTIVE_HEALTHY (9/24 QA의 INACTIVE 문제 해소) |
| Supabase secret | `GEMINI_API_KEY`, `GEMINI_MODEL`(= `gemini-3.5-flash-lite`), `APPLE_CLIENT_ID`(= `trident-KR.ADHD`), `APPLE_BUNDLE_ID`, `DELETION_STATUS_SECRET` 있음. **`APPLE_CLIENT_SECRET` 없음** |
| 배포된 함수 | `delete-account` v3, `storekit-sync` v2, `app-store-notifications` v2는 main과 같음. `analyze-task` v22는 main에서 성인 확인 gate만 빠진 상태(의도한 상태) |
| 성인 확인 migration | 적용 여부 미확인. DB 연결이 필요해서 이번에 보지 못함 |
| Gemini 모델 | `gemini-3.5-flash-lite`: Google 문서상 정식(GA) 모델이며 종료 일정 없음 |
| 앱 아이콘 | 기존 아이콘에는 Gemini 이미지 생성 표식(✦)과 미리 둥글린 흰 모서리가 있었다. 선제 수정 PR에서 로고는 그대로 두고 둘만 지웠다. 원본 디자인 파일이 있으면 그 파일로 다시 내보내도 된다 |

값은 해시만 대조했고 secret 값 자체는 읽지 않았다.

## 1. 먼저 정할 것 — 김기홍·이연재 합의 필요

**판매 지역.** 18세 이상 전용 앱이라 지역마다 조건이 다르다.

| 지역 | 조건 | 제안 |
|---|---|---|
| 한국·일본 | Gemini 지원 지역, 앱 한국어·일본어 지원 | 1차 출시 |
| 미국 | 텍사스 SB 2420이 2026-06-04부터 새 Apple 계정에 적용된다. 개발자에게 Declared Age Range API 등을 요구한다([Apple 공지](https://developer.apple.com/news/?id=sg176nne)). 18세 이상 전용 앱에 어디까지 적용되는지는 법률 확인이 필요하다 | 확인 전에는 제외 |
| 호주·브라질·싱가포르 | 2026-02-24부터 18+ 앱은 성인 확인이 안 된 사용자에게 다운로드가 막힌다. 개발자에게 별도 의무가 있을 수 있다([Apple 공지](https://developer.apple.com/news/?id=f5zj08ey)) | 제외 |
| EU·EEA·영국·스위스 | Gemini 유료 서비스만 쓸 수 있다. EU는 DSA 판매자(trader) 신고가 필요하고, 판매자면 연락처가 스토어에 공개된다 | 준비 전에는 제외 |

**구독 가격.** 로컬 StoreKit 테스트 설정은 월 $4.99 / 연 $35.99다. 실제 판매 가격은 아직 정하지 않았다.

## 2. Apple Developer — Team ID `5S3Y6973X6`

- [ ] 팀의 **Account Holder가 누구인지** 확인한다. 유료 앱 계약 동의는 Account Holder만 할 수 있다. 이연재 계정에는 인증서·키를 만들 수 있는 Admin 역할이 필요하다.
- [ ] Identifiers에서 App ID 두 개의 기능을 확인한다.
  - `trident-KR.ADHD`: Sign in with Apple, App Groups(`group.trident-KR.ADHD`), Time Sensitive Notifications
  - `trident-KR.ADHD.ADHDWidget`: App Groups(`group.trident-KR.ADHD`)
- [ ] App Group `group.trident-KR.ADHD`가 등록돼 있는지 확인한다.
- [ ] 서명을 준비한다. 프로젝트는 자동 서명이다. Xcode → Settings → Accounts에 팀 계정으로 로그인하면 Apple Distribution 인증서와 App Store 프로파일을 Xcode가 만든다. 이전 개발 서명은 Time Sensitive 권한이 빠진 프로파일 때문에 실패했으므로 프로파일을 새로 받아야 한다.
- [ ] Keys에서 **Sign in with Apple 키**를 만든다(Primary App ID `trident-KR.ADHD`). `.p8` 파일은 한 번만 내려받을 수 있으니 바로 비밀번호 관리자에 보관하고, Key ID를 적어 둔다.
- 확인: Release archive가 서명까지 성공하고, `codesign -d --entitlements - <앱 경로>` 결과에 Apple 로그인·App Group·Time Sensitive 세 가지가 보여야 한다.

## 3. APPLE_CLIENT_SECRET — 계정 탈퇴 시 Apple 연결 해제용

탈퇴할 때 Apple 로그인 연결을 끊는 데 필요하다. 없으면 탈퇴가 끝까지 되지 않는다.

- [ ] 저장소 루트에서 아래 명령을 실행한다. JWT는 화면에 찍히지 않고 바로 secret으로 들어간다. 만료일만 안내된다.

  ```bash
  supabase secrets set APPLE_CLIENT_SECRET="$(deno run --allow-read=<p8 경로> scripts/apple-client-secret.ts --team 5S3Y6973X6 --key-id <Key ID> --p8 <p8 경로>)" --project-ref nmjtswtqwwxxwiolgsnk
  ```

- [ ] 만료일(기본 180일, Apple 최대 약 6개월) 한 달 전에 캘린더 알림을 건다. 갱신할 때는 같은 명령을 다시 실행한다.
- [ ] `scripts/release-preflight.sh`의 [2] 항목이 모두 ✅인지 확인한다.
- 확인: 삭제 전용 테스트 계정으로 탈퇴한 뒤, 그 Apple ID의 설정 → Apple로 로그인 목록에서 Mora가 사라졌는지 본다. 실제 사용자 계정으로는 시험하지 않는다.

## 4. Google — Gemini API

- [ ] `GEMINI_API_KEY`를 발급한 Google Cloud 프로젝트에 **결제(Cloud Billing)가 연결돼 있는지** 확인한다. 무료 등급이면 입력 내용이 Google 제품 개선에 쓰이고 사람이 검토할 수 있다. 약관도 무료 등급에 개인정보를 보내지 말라고 한다. 따라서 유료 등급이 아니면 출시하면 안 된다([Gemini API 약관](https://ai.google.dev/gemini-api/terms)).
- [ ] 이 키의 사용량 한도(분당 요청·일일 요청)를 확인하고, 예상 사용량과 비교한다.
- [ ] Cloud Billing → 예산 및 알림에서 월 예산과 50·90·100% 알림을 건다. 심사 기간에 한도나 예산 때문에 AI가 멈추지 않게 여유를 둔다.
- [ ] API 키 제한을 Generative Language API 하나로 좁힌다.
- 유료 등급을 확인하면 개인정보 처리방침의 "Google의 데이터 이용 여부는 운영 프로젝트 서비스 유형에 따른다" 문장을 유료 등급 기준으로 구체화한다(웹 저장소 별도 PR).

## 5. Supabase — 순서를 꼭 지킨다

성인 확인 서버는 **migration → 호환 앱 → analyze-task gate** 순서로 올린다([상세](supabase/ADULT_ELIGIBILITY.md)).

- [ ] `supabase link --project-ref nmjtswtqwwxxwiolgsnk` (DB 비밀번호 필요)
- [ ] 백업 상태를 확인한 뒤 `supabase db push`로 `202609300002_mora_adult_eligibility.sql`까지 적용한다. **심사 제출 전 필수**다. migration이 없으면 새 앱의 성인 확인이 실패해 AI와 구매가 막히고, 심사에서 "기능이 동작하지 않음"으로 거절될 수 있다.
- [ ] 3번의 `APPLE_CLIENT_SECRET`을 설정한다.
- [ ] 선제 수정 PR이 머지되면 서명 빌드를 TestFlight에 올리고, 실기기에서 성인 확인과 AI 분석을 확인한다. 이 시점이 "호환 앱 제공" 단계다.
- [ ] 그다음 `analyze-task`를 배포한다: `supabase functions deploy analyze-task --no-verify-jwt --use-api --project-ref nmjtswtqwwxxwiolgsnk`
  - 앱이 아직 공개된 적이 없으므로, gate 때문에 AI가 막히는 건 팀 내부의 이전 빌드뿐이다. 심사관이 최종 서버 구성으로 보도록 **심사 제출 전에** 배포하는 것을 권한다. 배포 후에는 팀원에게 TestFlight 업데이트를 안내한다.
- [ ] `scripts/release-preflight.sh`를 다시 실행해 전부 ✅인지 확인한다.

## 6. App Store Connect

**계약·앱 정보**

- [ ] 비즈니스 → 유료 앱 계약·세금·은행이 모두 "활성"인지 확인한다(Account Holder 필요).
- [ ] 앱을 만든다. 번들 ID `trident-KR.ADHD`, 이름 후보 "Mora: 할 일과 루틴"(30자 이내). 이름이 이미 쓰이고 있을 수 있으니 대안도 준비한다.
- [ ] 카테고리는 생산성이다. 지원 URL은 `https://trident-kr.github.io/waitwhat-site/`, 개인정보 URL은 `https://trident-kr.github.io/waitwhat-site/privacy/`다.
- [ ] 저작권 표기와 심사 연락처(실명·전화·이메일)는 실제 권리자와 담당자 정보로 입력한다.

**구독** — 그룹 "Mora Pro", 두 상품 모두 같은 등급, 가족 공유 끔

| 상품 ID | 기간 |
|---|---|
| `com.TRIDENT.ADHD.monthly` | 1개월 |
| `com.TRIDENT.ADHD.yearly` | 1년 |

- [ ] 상품별 가격·판매 지역·표시 이름·설명(한/영/일)을 입력하고, 심사용 스크린샷으로 결제 화면을 올린다.
- [ ] 첫 구독 상품 두 개는 **앱 버전과 같은 제출에 포함**해야 한다.
- [ ] App Store 서버 알림 V2의 Production·Sandbox URL을 둘 다 `https://nmjtswtqwwxxwiolgsnk.supabase.co/functions/v1/app-store-notifications`로 넣고, "테스트 알림 보내기" 후 Supabase의 해당 함수 로그에 수신이 찍히는지 본다.
- [ ] Sandbox 테스트 계정 2개를 만든다. 구매 귀속·복원 확인용이다.

**앱 개인정보** — 앱의 `PrivacyInfo.xcprivacy`와 같게, 모두 "사용자와 연결됨 / 추적 안 함 / 목적: 앱 기능"

| ASC 항목 | 무엇 |
|---|---|
| 연락처 정보 → 이메일 주소 | Apple 로그인에서 받은 이메일(가림 주소 포함) |
| 식별자 → 사용자 ID | 계정 ID |
| 사용자 콘텐츠 → 기타 사용자 콘텐츠 | AI 분석에 보낸 글·음성 초안 |
| 구입 항목 → 구입 내역 | 구독 거래 |
| 사용 데이터 → 제품 상호작용 | 일별 AI 사용량 |
| 진단 → 기타 진단 데이터 | 최소 운영 기록 |
| 기타 데이터 → 기타 데이터 유형 | 성인 자기 확인 기록 |

**연령 등급** — 설문은 실제 동작대로 답한다.

- 사용자 간 콘텐츠 공유 없음, 메시징 없음, 광고 없음, 앱 안 무제한 웹 탐색 없음, 확률형 아이템 없음이다. 2026년 9월부터 필수가 된 소셜 미디어 질문은 "아니요"다. AI는 일정 문장을 해석하는 기능이지 자유 대화형 챗봇이 아니다.
- [ ] 설문을 마친 뒤 **"Override to Higher Age Rating" → 18+** 를 선택한다. 약관에 18세 이상이 명시돼 있어 필수다. Apple 원문: "If your app has a EULA with minimum age requirements that exceed the rating that Apple calculated, you must override to a rating that adheres to the requirements."([출처](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating))

**버전 정보·심사**

- [ ] 설명·키워드·부제는 [스토어 문안](MORA_STORE_METADATA.md)을 쓴다. 설명 끝의 개인정보·이용약관 링크는 구독 규정(3.1.2) 때문에 빼면 안 된다.
- [ ] 스크린샷은 검증한 빌드의 실제 화면만 쓴다. 필수 크기는 업로드 화면에서 확인한다.
- [ ] 심사 메모는 [인계서의 초안](MORA_APP_STORE_HANDOFF.md#심사-메모-초안-필수-qa-완료-후-사용)을 쓴다. 로그인 정보 칸에는 Apple 로그인만 쓰므로 별도 데모 계정이 없다고 적는다.
- [ ] 수출 규정: 선제 수정 PR 이후 빌드에는 `ITSAppUsesNonExemptEncryption = NO`가 들어간다. 코드상 암호화는 HTTPS와 OS 내장 SHA-256 해시뿐이다. 업로드 때 수출 질문이 뜨지 않는 것이 정상이다. 이 판단이 맞는지 소유자가 한 번 확인한다.
- [ ] EU를 제외하더라도 DSA 판매자 여부 질문이 나오면 판매 지역 결정에 맞게 답한다.

## 7. 실기기·TestFlight

[인계서의 실기기 실행 순서](MORA_APP_STORE_HANDOFF.md#실기기-실행-순서)를 따른다. 성인 확인, 로그인, AI 일정 저장, 구매·복원·환불, 탈퇴, 음성·잠금 화면 알람·위젯·VoiceOver를 본다. Luna의 실제 LLM 평가 결과도 이때 인수한다.

## 8. 제출 직전 최종 점검

- [ ] `scripts/release-preflight.sh` 전부 ✅: 프로젝트 활성, secret 4개, 함수 4개가 main과 일치, migration 적용
- [ ] Gemini 유료 등급·한도·예산 알림 확인
- [ ] ASC: 18+ override, 개인정보 응답, 판매 지역, 구독 두 개 첨부, 서버 알림 수신 확인
- [ ] 심사 메모·스크린샷이 제출 빌드와 일치
- [ ] 심사 기간 동안 Supabase·Gemini 키·예산이 멈추지 않도록 유지
- [ ] 김기홍 최종 확인 후 제출. 심사 통과를 보장하는 체크리스트는 아니다.
