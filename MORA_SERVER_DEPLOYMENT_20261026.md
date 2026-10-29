# MORA 서버 배포·실호출 검증 — 2026-10-26

**Claude 우선 서버 배포와 실제 호출 검증을 완료했다. Gemini로 전환되는 것까지 확인했지만, 실제 Gemini 응답은 HTTP 402로 실패했다. 사용자 결정에 따라 결제 문제와 성공 재검증은 [GitHub 이슈 #68](https://github.com/TRIDENT-KR/adhd/issues/68)로 이관했다.**

기준 정본: [AI·온디바이스 처리 결정](https://app.notion.com/p/4018320bd64b81fc8b22d40317178739). 이 문서가 2026-10-13·10-23 보고서의 **서버 배포 상태**를 갱신한다. 앱 배포·실기기 QA·로컬 분석 출시 활성화 상태는 변경하지 않았다.

## 배포한 변경

대상은 기존 Supabase 프로젝트 `nmjtswtqwwxxwiolgsnk`다. 기존 계정·일정·구독 데이터를 일괄 수정하거나 삭제하지 않았다.

| 항목 | 결과 |
|---|---|
| `202609300002_mora_adult_eligibility.sql` | 원격 적용, 성인 확인 RPC·계정별 기록 |
| `202610130001_mora_ai_broker.sql` | 원격 적용, service-role 전용 사용량 원장·분당 제한·이전 클라이언트 쓰기 권한 회수 |
| `analyze-task` | v23 → **v24 ACTIVE**, Claude 우선 → Gemini 대체, 동의 v2, 검증·사용량 예약/확정/실패 해제 |
| `delete-account` | v4 → **v5 ACTIVE**, Apple 재인증 검증 후 삭제 잠금 생성 |
| `storekit-sync`, `app-store-notifications` | v3 유지, 배포 소스·gateway 설정 일치 확인 |

함수는 기존처럼 gateway `verify_jwt=false`를 사용하며, 각 handler의 사용자 인증 또는 Apple 서명 검증은 유지한다. 실제 분석 API의 인증 거부도 확인했다. migration 적용 후 새 함수를 연속 배포했다. 이전 Edge의 원장 권한이 회수되므로 해당 전환 구간의 분석 성공을 보장하지 않는다.

배포 후 다운로드한 **4개 함수의 실제 소스와 모든 로컬 상대 import 파일 SHA256**을 대조했고 모두 일치했다. migration 6개 전체의 원격 이력도 로컬과 일치했다. Git 커밋·push가 아닌 현재 작업 트리에서 Supabase CLI로 배포했다.

## 실호출 결과

운영 `analyze-task`에 실제 사용자 JWT를 보내되, 이번 실행에서만 만든 **staging 환경에 묶인 임시 Auth 계정**을 사용했다. 합성 입력만 보냈고 이메일 발송, 개인 일정 입력, iPhone 일정 저장은 하지 않았다. 종료 후 이 계정을 삭제하고 Auth에서 404로 조회되지 않는 것까지 확인했다.

| 검사 | 실제 결과 |
|---|---|
| 인증 없는 분석 | HTTP 401 |
| 성인 확인 전 분석 | HTTP 403 `adult_eligibility_required` |
| 동의 v2 없는 분석 | HTTP 403 `ai_consent_required` |
| 클라이언트의 이전·v2 원장 직접 호출 | 둘 다 HTTP 403 / PostgreSQL `42501` |
| 한국어: 내일 오후 3시 치과 예약 추가 | HTTP 200, **Claude**, `2026-10-27 / 03:00 PM / Appointment` |
| 영어: 같은 의미 | HTTP 200, **Claude**, 동일 날짜·시각·분류 |
| 일본어: 같은 의미 | HTTP 200, **Claude**, 동일 날짜·시각·분류 |
| 같은 requestId·본문 재전송 | HTTP 200, **cache**, 동일 결과·used=1 유지 |
| 같은 requestId에 다른 본문 | HTTP 409 `request_conflict` |
| 세 번의 정상 성공 | used=1→2→3, reserved=0, remaining=2→1→0 |
| 네 번째 무료 요청 | HTTP 429 `quota_exhausted`, 모델 성공 헤더 없음 |

실제 endpoint 검증 **15개 검사와 임시 계정 정리 모두 통과**했다. 짧은 합성 smoke test이므로 일반 자연어 정확도나 앱 UI E2E를 인증하는 결과는 아니다.

별도의 임시 검증 함수에서 동일한 production router·검증기·시스템 프롬프트를 사용했다. 정상 호출은 `claude-haiku-5-5` **HTTP 200 / 1,205ms**, 실제 Gemini 요청 0회였다. 이것은 단일 관측값이며 p95나 성능 보장이 아니다.

## Gemini 검증과 보류 범위

운영 전체 `ANTHROPIC_ENABLED`나 키를 변경하지 않고, 격리된 임시 함수의 fetch 경계에서만 Claude HTTP 503을 주입했다. 같은 라우터가 다음 제공자로 전환하여 **실제 `gemini-3.5-flash-lite` API를 호출**했다.

- Claude 주입 오류: 503, 실제 Claude 요청 없음.
- Gemini 실응답: **402**, `RESOURCE_EXHAUSTED`, 오류 분류 `billing_or_credit`.
- 따라서 **fallback 선택은 확인**, **Gemini 정상 응답·최종 성공은 미확인**이다.
- 실패 원인 진단을 한 번 더 확인한 뒤, 사용자 지시에 따라 추가 Gemini 호출·충전·키 변경을 중단했다.
- 결제 복구 및 Claude 503/402 → Gemini HTTP 200 재검증은 [#68](https://github.com/TRIDENT-KR/adhd/issues/68)에 체크리스트와 근거를 남겼다.

Google 공식 문서는 402를 선불 크레딧 소진 오류로 설명한다. 실제 계정의 결제 화면·잔액을 조회하거나 결제를 수행한 것은 아니다. [오류 표](https://ai.google.dev/gemini-api/docs/generate-content/api-errors), [Billing 안내](https://ai.google.dev/gemini-api/docs/billing).

지금은 Claude가 정상일 때 운영 분석이 가능하지만, Claude 장애·소진 시 Gemini가 정상적인 대체 서비스를 제공하지 못한다. 양쪽 실패 시 사용량 예약 해제는 로컬 통합/DB 테스트로 검증했으며, 이번 운영 endpoint에서 Gemini 성공 후 한 번 차감하는 경로까지 검증한 것은 아니다.

## 이번에 추가한 관측·재현 도구

- `model-router.ts`: 요청 원문·키·응답 본문 없이 제공자, 모델 ID, HTTP 상태, 성공/실패, 지연과 제한된 실패 분류를 전달한다. 진단 callback 실패가 fallback을 유발하지 않도록 격리했다.
- `index.ts`: 요청 ID별 허용된 진단 필드만 기록한다. 성공 응답의 `X-Mora-AI-Provider`는 `claude`, `gemini`, `cache`다. 기존 JSON 응답 계약은 유지한다.
- `model-router_test.ts`, `log_policy_test.ts`: 제공자 전환 증거, 진단 실패 격리, 민감 정보 로그 금지 회귀 검증.
- `scripts/verify-live-ai-providers.py`: 동일 production 소스를 복사한 임시 Edge 함수에서 정상/Claude 503/402 실호출을 검증한다. 실행별 운영자 토큰의 SHA256만 임시 함수에 포함하며 종료 시 함수를 삭제한다. 키는 메모리에서만 사용한다.
- `scripts/verify-live-ai-endpoint.py`: 임시 staging 계정으로 실제 운영 endpoint의 인증·동의·Claude·캐시·quota·원장 권한을 검증하고 계정을 정리한다.

초기 임시 함수는 런타임 service-role 값과 호출 측 키의 직접 비교에서 401을 반환했다. 운영 handler 인증을 약화하지 않고, 임시 함수에만 실행별 고엔트로피 토큰 인증을 적용해 검증을 수행했다. 임시 검증 함수는 전부 삭제되었고 잔여 목록이 비어 있음을 확인했다.

## 검증 및 증거

- Deno 서버 테스트: **86 passed, 18 steps, 0 failed**.
- 로컬 PostgreSQL 16 DB harness: **97 passed, 0 failed**.
- `analyze-task`와 `delete-account` TypeScript 검사 통과.
- 배포 소스/gateway 대조 4개 함수 통과, migration 원격 이력 일치.
- `git diff --check` 통과.

장기 증거: `research/deploy-20261026/`의 provider/endpoint 결과, 원격 소스 SHA256 대조, 배포 manifest. 결과 파일에는 비밀키·JWT·실제 사용자 원문을 저장하지 않았다.

상세 명령 로그와 배포 전 함수 소스 백업은 `/tmp/mora-deploy-20261026/`에 있다. 임시 경로의 보존은 보장하지 않는다. 재현 스크립트는 현재 로컬 작업 트리 기준이며 GitHub main에 push된 것으로 간주하지 않는다.

## 운영 조건과 복구

새 분석 서버는 **성인 확인 및 AI 동의 v2가 포함된 현재 앱 빌드**를 요구한다. 이전 앱 요청은 이 gate에서 거절될 수 있다. iOS 앱을 App Store/TestFlight에 배포하지 않았다. 로컬 분석 Release 활성화, Apple 모델 연결, 전체 iOS 회귀 재검증·실기기 QA는 기존 미완료 상태를 유지한다.

`APPLE_CLIENT_SECRET`은 아직 없으므로 Apple 계정 삭제의 실제 완료 경로는 별도 설정·검증이 필요하다. 이번 `delete-account` 배포는 준비된 재인증 순서 보안을 반영한 것이며 실제 사용자 계정 삭제를 실행하지 않았다.

문제 발생 시 v2 원장과 호환되는 검증 소스를 재배포한다. 이전 클라이언트 원장 grant를 다시 열거나 구버전 `analyze-task`만 복구하지 않는다. **Gemini가 402를 반환하는 현재 상태에서 Claude 비활성화는 정상 복구 수단이 아니다.** Gemini 복구 후에만 `ANTHROPIC_ENABLED=false`를 사용한 대체 운영을 검토한다. 키 회전·자동 충전·제공자 지출 한도는 변경하지 않았다.
