# Mora App Store 재감사 및 수정 결과

2026-09-29 · RC 1.0 (4) · **확인된 코드 결함을 수정했다. 심사 제출은 외부 설정·AI 제공 방식 전환·실기기 검증이 남아 있어 BLOCKED다.** 수정 전 상세 근거는 Git `5472051`의 이 문서와 `outputs/release-readiness/20260929-final-implementation/audit-before.md`에 보존했다. 심사 통과를 보장하거나 미실행 항목을 PASS로 처리하지 않는다.

## 확인된 문제의 현재 상태

| ID | 문제 | 구현 및 검증 | 남은 조건 |
|---|---|---|---|
| AR-01 | 삭제 상태 조회의 Apple 재인증 요구가 UI에 반영되지 않음 | 409 구조화 오류 적용·Keychain 저장·polling 중단·재인증 화면 복구. 재실행 회귀 포함 | 유효 Apple secret으로 실제 삭제 |
| AR-02 | 서버 삭제 후 로컬 정리가 실패하면 재실행 복구 불가 | 로컬 파일·설정·캐시 정리까지 완료 표식 유지, 재시도·완료 알림. 저장/표식 제거 오류 회귀 | 기기 장애/강제종료 표본 |
| AR-03 | 거래만 재등록하면 grace가 expired로 바뀜 | 거래·알림 증거 우선순위와 signedDate 저장. 과거 expiresDate/미래 grace로 SQL 회귀 | Apple Sandbox grace 수신 |
| AR-04 | 유효한 옛 JWS/역순 알림으로 환불이 취소됨 | 오래된 증거 거부, 명시 REFUND_REVERSED·새 구매 허용. 같은 시각·누락/미래 시각 회귀 | Apple Sandbox 환불/철회 |
| AR-05 | 위젯의 직접 업셀 | 중립 안내·일반 routine 링크, Pro/업그레이드 문구·paywall 링크 제거 | 실제 홈/잠금 화면 크기별 표시 |
| AR-06 | Pro 인식 실패 시 구독 관리도 숨김 | 게스트·무료·삭제 대기에도 Apple 구독 관리와 삭제 시 구독 유지 고지 | Apple 설정 이동/복귀 실기기 |
| AR-07 | Time Sensitive entitlement 누락 | 앱 entitlement 추가, AlarmKit 목적 설명 KO/EN/JA 정리 | 현재 개발 프로파일 권한 누락·팀 로그인 부재로 서명 실패. 프로파일 갱신·실기기 Focus 검사 |
| AR-08 | 오류·현지화·OSS·결제 완료 표시 | 로그인 실패/사용자 취소 분리, 구매·복원 현지화, 서버 유효 Pro 확인 뒤 닫기, 위젯 이름 Mora, SDK6개 LICENSE/NOTICE, 이름 scope 제거 | 실제 구매·복원 오류 및 VoiceOver |
| AR-09 | 기본 로컬 일정까지 로그인 강제 | 게스트 물리 저장소·설정 분리, 수동 추가/알림, 명시 복사·원본 보존·중복 방지. 게스트는 서버 identity/Pro 미보유 | 실제 A/B 로그인·재설치·오프라인 QA |
| AR-10 | Gemini 연령·요금제·지역 조건 | **제품 결정 완료:** 18세 이상 제한 없이 폭넓게 출시. Developer API와 Cloud §20(d)의 기본 조건 모두 불일치 확인 | 미성년자 지원 가능한 제공 방식 선정·전환·평가, 어린이 보호/데이터 조건 반영 |
| AR-11 | 공개 정책/보관/수집 신고 차이 | 탈퇴 거래 원장 물리 삭제 및 고정 보관 상한, Usage Data(Product Interaction) manifest, 게스트/보관/지원3언어 웹 초안 | 새 AI 제공자·어린이 보호 조건 확정, 웹 PR 게시, ASC Privacy 입력 |

추가로 계정 전환 중 Supabase SDK가 현재 세션으로 Authorization을 바꾸는 경로를 막았다. AI·구독 요청은 시작 계정 토큰을 고정하고 구독 응답에는 계정 세대를 검사한다. 로그아웃 이후 늦게 도착한 인증 검증/이벤트도 계정을 재개방하지 않는다. 실제 HTTP 전송은 URLProtocol 격리 회귀로 확인한다.

새 구독의 알림이 앱 등록보다 먼저 와서 이전 계정에 Pro가 붙는 실패도 DB에서 재현했다. 다른 살아 있는 계정 토큰이면 명시 등록까지 이전 계정 권한을 갱신하지 않게 수정했다.

## 데이터 보관

로그인 계정의 구독 원장은 기능 유지에 필요하다. 탈퇴하면 일반 거래 원장은30일, 재연결 대상은 기존 접근 종료+30일을 고려하되 삭제 후 최대400일로 고정한다. 이후 알림으로 연장하지 않으며 cron이 행을 물리 삭제한다. 정상 재연결 시 새 계정의 사용 중 원장으로 전환된다. 계정 ID를 비웠다는 이유만으로 익명정보라고 주장하지 않는다.

게스트 일정은 계정 일정과 별도 로컬 저장소다. 계정 삭제는 그 계정의 데이터를 지우며 게스트 원본이나 다른 기기의 로컬 사본까지 지웠다고 표시하지 않는다. 이 버전에 클라우드 일정 백업·기기 간 동기화는 없다.

## 실제 확인 범위

최신 숫자·archive·배포 버전·UI 기록은 [출시 준비 결과](MORA_RELEASE_READINESS.md)를 따른다. Deno/Swift/격리 DB 회귀, 실제 배포 소스 대조, 무인증/위조 서명 차단은 자동 근거다. 실제 Apple 구매·복원·토큰 revoke·알람 전달은 별도 미완료이며 자동 근거로 대체하지 않는다.

로컬 브라우저에서 지원 FAQ, 한/영 정책 전환, 지원→privacy→terms→지원 탐색을 확인했다. 공개 사이트는 아직 기존 문서이며 루트404 문제도 PR 병합·게시 전까지 남는다.

## 외부 조건 — 소유자가 확인할 항목

| 조건 | 현재 상태 / 종료 근거 |
|---|---|
| Apple revoke | APPLE_CLIENT_SECRET 미설정. 소유자의 Sign in with Apple 키로 생성/설정 후 실제 Apple 연결 해제·삭제 |
| 배포 서명 | 최신 개발 서명도 Time Sensitive 누락으로 실패; 자동 갱신은 Xcode 팀 로그인 부재. 계정 로그인·개발 profile 갱신 및 Apple Distribution 인증서·앱/위젯 App Store provisioning profile 필요. App Group/Apple 로그인/Time Sensitive 포함 |
| 계약·지급 정보 | ASC 유료 앱 계약·세금·은행 상태 미확인. 소유자 직접 확인 |
| 구독 상품 | 월/연 상품, 같은 그룹/동일 혜택 수준, 가격/지역/설명/심사 screenshot, 가족 공유 꺼짐. 로컬 StoreKit 설정은 수정했으나 ASC 상태는 미확인 |
| 최초 IAP 제출 | 두 자동 갱신 구독·그룹을 앱 버전과 같은 제출에 포함 |
| 서버 알림 | Production/Sandbox V2 URL 지정 및 실제 Apple 테스트 알림 수신 |
| 거래 및 계정 E2E | Sandbox 구매·복원·취소·pending·만료·grace·환불·철회·다른 계정 귀속·삭제 후 복원 |
| 개인정보/연령/지역 | Google 유료 프로젝트·지역·연령 정책, ASC Privacy/연령 질문, 실제 공개 정책 일치 |
| EU DSA/수출 | 판매 지역에 맞는 DSA 지위/검증, 실제 포함 암호화 기능의 수출 질문. 추정으로 대신 답하지 않음 |
| 심사 접근/메타데이터 | 실제 연락처·지원URL·스크린샷·검증한 build 선택. DEBUG demo는 심사 접근 대체 불가 |
| TestFlight | 배포용 export·업로드·실기기 검증. 2기기/48시간은 팀 품질 기준이며 Apple 일률적 필수 규정은 아님 |

Pro 알람·위젯은 기존 제품 정책대로 유지했다. 기본 알림은 무료로 제공하고 유료 기능을 앱 고유 기능과 AI 서비스 묶음으로 설명한다. Apple 4.10 적용 여부는 심사 판단이며 유료 위젯이 무조건 허용/금지라고 단정하지 않는다.

## 공식 근거

- [Apple 심사 가이드라인](https://developer.apple.com/app-store/review/guidelines/) — 완성도, 구독, 확장 내 마케팅, 로그인/개인정보/AI 전송
- [계정 삭제](https://developer.apple.com/support/offering-account-deletion-in-your-app/) — 인앱 삭제, Apple 토큰 revoke, 지연·구독 안내
- [currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements), [signedDate](https://developer.apple.com/documentation/appstoreservernotifications/signeddate) — grace와 알림 순서
- [Time Sensitive](https://developer.apple.com/videos/play/wwdc2021/10091/), [App Privacy](https://developer.apple.com/app-store/app-privacy-details/)
- [최초 IAP 제출](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/), [연령 설정](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating)
- [Gemini API 조건](https://ai.google.dev/gemini-api/terms) — 18세 미만 대상/접근 가능성, 유료 서비스 데이터 조건·지원 지역

[앱 PR #65](https://github.com/TRIDENT-KR/adhd/pull/65) · [웹 PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1). main 자동 병합은 저장소 CLAUDE.md의 명시적 금지에 따라 하지 않는다.

2026-09-29 후속 근거: [Google Cloud §20(d)](https://cloud.google.com/terms/service-terms)도 같은18세 제한을 명시한다. [OpenAI 미성년자 지침](https://developers.openai.com/api/docs/guides/safety-checks/under-18-api-guidance)은 대안 검토 근거이며 조건 없는 전 연령 허용 판정은 아니다.
