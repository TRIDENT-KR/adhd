# 로컬 변경 통합 검증 — 2026-10-29

원래 checkout의 미커밋 앱·서버·문서·연구 자료 82개 파일은 `2e1a123`에 먼저
보존했다. `fix/mora-local-integration`에서 MORA Eval이 머지된 main `634ca52`를
합쳤으며, 최신 메인의 UI·일정·위젯·알림 수정과 로컬 계정 보호·분석 라우팅을
함께 유지했다.

## 통합 시 조정

- 계정별 초기화 날짜는 main의 `lastResetDate` 키·이전 값 승계를 유지한다.
  저장 실패 시 완료·주간 상태와 초기화 날짜를 복구한다.
- 서버·앱의 강화된 분석 계약을 유지한다. 모델의 빈 시간은 거부하지만,
  확인 카드에서 사용자가 고른 ‘시간 없음’은 로컬 편집으로 실행할 수 있다.
- 같은 이름 후보는 명시적으로 선택한다. 선택 후 상태가 바뀌면 후보 선택을
  다시 보여 주며, 승인된 UUID 밖으로 실행 대상이 늘어나지 않는다.
- 같은 UUID의 AlarmKit 등록과 실패 정리를 직렬화해 이전 세션의 늦은 취소가
  재로그인 후 복원된 알람을 지우지 않게 한다.
- AI 동의 v2 오류는 재동의 화면으로 연결하고, 요청 제한은 결제 화면과 구분한다.
- MORA Eval과 live 검증 스크립트가 같은 `prompt.ts`를 사용한다. 공유 template은
  보존 커밋 `2e1a123`의 기존 프롬프트와 byte 단위로 동일하다. 최초 추출 기록은
  변경하지 않고 별도 `tools/mora-eval/evidence/prompt-integration.json`에 근거를 남긴다.

## 완료된 오프라인 검사

- MORA Eval: 28 passed / 0 failed. 타입·lint·format·102개 개발 데이터 검사 통과.
- 전체 서버 Deno: 86 passed, 18 steps / 0 failed.
- 일회용 로컬 PostgreSQL: 97 passed / 0 failed. 원격 DB에 접속하지 않는다.
- macOS 운영 소스 추출 테스트: 3 suites, 15 tests / 0 failed. 분석 핵심과
  같은 UUID의 알람 등록 순서를 실제 소스 그대로 검사한다.
- iOS Debug 앱·위젯·테스트 번들 `build-for-testing`: TEST BUILD SUCCEEDED.
- Python 검증 스크립트 구문 검사, release-preflight shell 구문 검사 통과.
- 고정 커밋 서버 검토와 통합 Swift 검토를 별도 수행하고 발견한 회귀를 수정했다.

## iOS 실행 검증의 제한

전체 iOS Simulator 테스트는 앱·테스트 번들 컴파일 후 실행 시작 단계에서
정체되어 중단했다. 당시 8GB Mac의 load average가 159까지 관측됐고, 전용
Mora 시뮬레이터의 launchd 프로세스 시작도 지연됐다. 다른 프로젝트 프로세스는
종료하지 않았다. Xcode는 중단 과정에서 결과 로그 저장 오류를 보고했다.
**전체 iOS 회귀 테스트 통과는 확인하지 못했다.** macOS 핵심 검사와 테스트 번들
빌드는 SwiftData·SwiftUI·Speech·AlarmKit 실환경 실행을 대체하지 않는다.

실제 모델 API 평가·서버 배포·App Store 배포·사용자 실기기 조작은 이 작업에서
실행하지 않았다. 합성 데이터 검사나 단위 테스트 통과를 모델 정확도 또는 출시
승인으로 해석하지 않는다. 과거 연구·배포 기록은 당시 관측값으로 보존한다.
