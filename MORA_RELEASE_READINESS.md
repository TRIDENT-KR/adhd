# Mora 출시 준비 결과 — 2026-09-29

**확인된 앱·서버 결함을 수정하고 서버에 반영했다. 아직 App Store에 제출할 수 있는 상태는 아니다.** 남은 필수 조건은 대상 연령 결정, Apple/Google 계정 설정, 공개 정책 게시, 배포 서명과 실제 Apple·실기기 QA다. 심사 통과를 보장하거나 실행하지 않은 검사를 통과로 기록하지 않는다.

앱 [PR #65](https://github.com/TRIDENT-KR/adhd/pull/65) · 웹 [PR #1](https://github.com/TRIDENT-KR/waitwhat-site/pull/1). 작업은 관리 worktree에서 했으며 원래 checkout의 Luna 하네스·prompt 미커밋 변경을 보존했다. 팀원 PR #57의 필요한 Gemini/페이월 동작은 통합됐고 해당 구 브랜치를 통째로 병합할 필요는 없다.

## 이번에 완료한 구현

- **로그인 없이 기본 사용:** 일정·루틴·기본 알림을 별도 게스트 저장소에서 사용한다. 계정 데이터와 섞지 않으며 로그인 후 명시적으로 복사한다. 원본 보존·중복 복사 방지·다른 계정 범위 거부를 구현했다. 게스트는 서버 계정 ID나 Pro 권한을 받지 않는다.
- **삭제 복구:** Apple 재인증 요구가 영구 상태와 UI에 반영된다. 서버 완료 뒤 기기 파일·설정·캐시 정리를 마칠 때까지 표식을 남겨 종료/재실행/삭제 오류에서 복구한다. 지연·완료 안내와 구독 별도 해지 안내를 제공한다.
- **계정 전환:** 늦은 인증 응답이 로그아웃을 되돌리지 않도록 막았다. AI·구독 요청의 인증 토큰을 시작 계정에 고정하고, 구독 처리는 계정 세대가 달라지면 적용하지 않는다.
- **구독 정확성:** 앱 거래 재등록이 결제 유예를 지우지 않고, 옛 JWS/역순 알림이 환불을 되돌리지 않는다. 최신 환불 철회·새 구매는 허용한다. 새 계정의 구매 알림이 먼저 와도 이전 계정에 Pro를 주지 않는다. 구매·복원 화면은 서버가 현재 계정의 Pro를 확인했을 때만 완료로 닫힌다.
- **심사 화면:** 위젯 직접 업셀 제거, 구독 관리 항상 접근, Time Sensitive entitlement, AlarmKit 권한 설명·구매/복원/로그인 오류 KO/EN/JA, 위젯 이름 Mora, 불필요한 이름 scope 제거, 실제 포함 SDK6개 라이선스 고지. Pro 알람·위젯 혜택과 기본 무료 알림은 유지한다.
- **개인정보·지원:** 탈퇴 거래 원장에 고정 보관 상한·물리 삭제, Usage Data manifest 선언, 게스트/계정 보관 차이·실제 AI 처리 설명. 지원3언어 페이지와 정책 링크를 준비했고 로컬 브라우저로 확인했다. 공개 사이트 반영은 아직이다.
- **제출 문안:** [스토어 문안](MORA_STORE_METADATA.md)에 KO/EN/JA 이름·부제·키워드·설명과 스크린샷 기준을 준비했다. 실제 연락처/권리자/연령/계약을 임의 입력하지 않았다.

재감사 AR-01~11의 조치와 공식 근거는 [심사 재감사 결과](MORA_APP_STORE_REVIEW_AUDIT.md)에 있다.

## 검증

| 검사 | 결과 | 증거와 한계 |
|---|---|---|
| Swift | **111 passed / 0 failed / 0 skipped**, 19 suites | 실제 전송 토큰 고정, 계정 전환/삭제 복구, 게스트 영구 저장/복사 포함. UI 현지화 후속 변경은 별도 빌드·화면 확인 |
| Deno | **60 passed / 0 failed** | 현재 서버 단위·계약·민감 로그 정책. Luna eval/레거시 유료 러너 제외 |
| PostgreSQL | **68 passed / 0 failed** | 임시 로컬 DB. 전체 migration·기존 원장 업그레이드·grace/환불/소유권·보관 물리 삭제. 운영 DB에 fixture 없음 |
| 배포 소스 | **4개 함수 PASS** | 실제 다운로드한 모든 상대 import 소스 SHA-256·ACTIVE·gateway 설정 일치 |
| 실제 HTTP 차단 | **4개 경로 PASS** | analyze/delete/storekit 무인증401, 알림 위조 서명400. 실제 Apple 거래 성공의 증거 아님 |
| UI 표본 | **PASS** | 1대 iPhone17/iOS26.4.1 simulator에서 아래 흐름 확인. 실기기 E2E 대체 아님 |
| Release / 배포 서명 | **무서명 archive PASS / 서명 BLOCKED** | 앱·위젯 arm64, 1.0(4), iOS26.2, manifest·3언어 권한·OSS 포함. 개발 profile에 Time Sensitive 누락; 자동 갱신도 Xcode 팀 로그인 부재로 실패. 업로드용 산출물 아님 |

Release 빌드에는 기존 경고8개가 남는다: 불변 문자열·순수 scope 계산의 actor 격리 참조7개와 UIScreen.main deprecation1개다. 이번 컴파일에서 오류는 없었고 데이터 변이 경쟁으로 확인된 경로는 아니지만, 향후 Swift 격리 전환·다중 창 화면 크기 처리는 별도 정리 대상이다. 경고 원문은 archive-inspection.json에 보존했다.

새 테스트는 처음 #expect의 변경 메서드 호출4곳에서 컴파일 오류가 났고, 수정 뒤 테스트가 닫힌 SwiftData 모델을 읽어 한 번 종료됐다. .ips로 테스트 수명 위반을 확인해 값 스냅샷 비교로 고쳤다. 게스트3개 단독 통과 후 전체111개를 재실행해 통과했다. 실패 로그도 보존했다. 기존 테스트를 제외하거나 실패를 숨겨 통과 수치를 만들지 않았다.

**UI에서 직접 확인:** 온보딩 스킵, 알림 권한 거절 후 기본 사용, 게스트 수동 일정 저장·완료, 종료/재시작 후 일정·완료 상태 보존, 게스트 AI 안내와 로그인 취소, 무료/게스트의 Apple 구독 관리 링크, 일본어 설정·라이선스 본문, 빈 플래너에서 로그인 없는 수동 추가. 새 일정은 합성 QA 문장만 사용했다. 실제 Apple 로그인·구매·복원·음성 전사·알람 전달을 PASS로 기록하지 않았다.

이전 실제 Gemini smoke에서는 지정 임시 staging Auth 계정의 합성 입력3회 성공, 동일 요청 replay 무차감, 네 번째 무료 요청429를 확인했다. 이번에는 모델/분석 서버를 바꾸지 않았고 추가 유료 호출은 하지 않았다. 이 결과는 LLM 의미 정확도나 p95 성능 점수가 아니며 Luna 평가와 별개다.

## 운영 반영

Supabase 프로젝트 `nmjtswtqwwxxwiolgsnk`, backend `86117cd`:

| 함수 | 실제 상태 |
|---|---|
| analyze-task | v22 ACTIVE, Gemini3.5FlashLite 유지, 기존 소스 일치 |
| delete-account | v3 ACTIVE, 소스 일치; Apple revoke secret 미설정 |
| storekit-sync | **v2 ACTIVE**, 서명 시각 포함 v2 RPC |
| app-store-notifications | **v2 ACTIVE**, 서명 시각/알림 원천 포함 v2 RPC |

4개 migration 적용 이력 확인: `202608040001`, `202609240001`, `202609290001`, **`202609300001`**. 새 migration을 먼저 적용하고 두 StoreKit 함수를 배포했다. 이전 RPC는 시각 없는 증거 쓰기를 거부한다. **Edge Function만 옛 버전으로 롤백하지 않는다.** 현재 스키마와 호환되는 코드를 전진 배포한다. 구 main 그대로 재배포하면 Gemini2.0/구 계약으로 되돌아갈 수 있으므로 먼저 통합 PR을 인수한다.

탈퇴 구독 원장은 일반30일, 재연결 대상은 기존 접근 종료+30일을 고려하되 삭제 후 최대400일이다. 후속 알림은 기한을 늘리지 않는다. 만료 정리 SQL은 검증했지만 실제 운영 cron 실행 이력 관측은 남아 있다.

## 지금 남은 필수 조건

1. **제품 결정:** Gemini API는 18세 미만을 대상으로 하거나 이용 가능성이 있는 API Client를 제한한다. 18세 이상 운영 여부를 사용자에게 질문했고 답변 대기 중이다. 결정 뒤 앱 진입/이용 조건·약관·마케팅·ASC 연령/지역을 일치시켜야 한다. 현재 under13 문구로 제출하지 않는다. [Google 조건](https://ai.google.dev/gemini-api/terms)
2. **Google 설정:** 실제 API 프로젝트의 활성 Cloud Billing, 유료 데이터 처리 조건 및 지원 지역을 확인한다. 무료 조건과 유료 조건을 같다고 안내하지 않는다.
3. **Apple 계정:** APPLE_CLIENT_SECRET 설정·갱신 관리, 유료 앱 계약/세금/은행, 월/연 구독 상품·같은 그룹/혜택 수준·가격·지역·설명·심사 screenshot, 서버 알림 V2 Production/Sandbox URL 설정·Apple 테스트 수신. 첫 구독은 앱 버전과 함께 심사 제출한다.
4. **공개 정보·서명:** 연령/Google 조건을 반영한 웹 PR 게시 후 support/privacy/terms 실제 확인, ASC Privacy·연령·DSA/암호화/심사 연락처, 배포 인증서·앱/위젯 프로파일·TestFlight 업로드.
5. **실제 기능 검증:** 지정 QA Apple/Mora 계정으로 로그인→AI 일정 저장, 구독 구매/복원/환불/유예/재귀속, Apple revoke→삭제 완료, 실제 음성·알람·위젯·VoiceOver·오프라인/계정 전환. LLM 평가 인수와 같은 RC의 팀48시간 관찰. 두 기기/48시간은 팀 기준이며 Apple의 일률적 필수 규정은 아니다.

필요한 사람 작업과 심사 메모는 [제출 인계서](MORA_APP_STORE_HANDOFF.md), 전체 case는 [QA 계획](MORA_RELEASE_QA_PLAN.md)을 따른다. 이번에 ASC 저장·앱 업로드·심사 제출은 하지 않았다.

## 산출물과 인수

`outputs/release-readiness/20260929-final-implementation/`에 Swift xcresult/JSON·Deno·DB 수정 전후·배포/migration/source hash·HTTP 차단·UI 스크린샷을 보존했다. 토큰·키 값·실사용자 일정은 저장하지 않았다. 이전 검증은 각 outputs 폴더에 역사로 남고 최신 PASS를 대신하지 않는다.

[CLAUDE.md](CLAUDE.md)의 “NEVER attempt a programmatic force-push or merge to main”에 따라 main을 자동 병합하지 않았다. 검토 후 앱은 `gh pr merge 65 --repo TRIDENT-KR/adhd --squash --delete-branch`로 인수한다. 웹은 연령/Google 조건을 확정한 뒤 PR #1을 병합·게시한다.
