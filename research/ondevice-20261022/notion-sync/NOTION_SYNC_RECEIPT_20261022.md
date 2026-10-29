# MORA Notion 정본 반영 기록

작성: 2026-10-22

- 상위: [MORA](https://app.notion.com/p/3928320bd64b80cf883df0af9ad0187b)
- 새 정본: [AI·온디바이스 처리 정본 — 자동 하이브리드 결정 (2026-10-22)](https://app.notion.com/p/4018320bd64b81fc8b22d40317178739)
- 정본 범위: AI 제공자, 온디바이스 적용 범위, 별도 설정 없는 UX, 모델 평가 및 도입 조건.
- 새 로컬·Apple 경로의 구현·배포 완료를 주장하지 않는다. 다른 제품·보안 정책은 유지한다.

## 반영 내용

기존 문서 15개를 업데이트했다. 주요 문서 6개의 충돌 문구 23곳을 보정하고, 과거 감사 9개에는 본문을 그대로 보존한 채 정본 링크와 역사적 적용 범위를 추가했다. 과거 취약점을 해결 완료로 바꾸지 않았다.

- [MORA](https://app.notion.com/p/3928320bd64b80cf883df0af9ad0187b)
- [📋 MORA 전체 기능 구현 명세서 (v1)](https://app.notion.com/p/2edbd8b75826480ea2cd41655b9a7ef3)
- [🚀 창업 아이디어 — Problem / Solution / Market / Identity](https://app.notion.com/p/7e0db44f42db4de0a948907da8155db3)
- [🔐 MORA 보안 감사 대응 SDD — 확정 결정사항 (2026-08-01)](https://app.notion.com/p/3af8320bd64b81788d14d50c9cfc2379)
- [🤖 Fable5 실행 프롬프트 — 구현 기획안 작성용](https://app.notion.com/p/6e6d537121034303aa504afb326b9fcd)
- [🚦 출시 QA 후속 작업 — 2026-09-24](https://app.notion.com/p/3e58320bd64b8140b184dac95705a8ac)
- [🛡️ 출시 전 코드베이스·시스템 감사 — 2026-07-12](https://app.notion.com/p/39b8320bd64b81eab417efb8a7d75f3d)
- [🛡️ MORA LLM 보안감사 — 2026-08-11](https://app.notion.com/p/3b98320bd64b814c8f56e82d6047d872)
- [🗺️ 01. 범위·방법·신뢰경계와 데이터 흐름](https://app.notion.com/p/3b98320bd64b81bb9774d33e548a4e50)
- [🚢 03. 배포·모델·Secret·공급망](https://app.notion.com/p/3b98320bd64b81288dd4cf2b6ed89e7c)
- [💸 04. Quota·비용·인증 Control Plane](https://app.notion.com/p/3b98320bd64b81aab59cd2ee4301a4bd)
- [📲 05. 출력 검증·과도한 권한·iOS 부작용](https://app.notion.com/p/3b98320bd64b811a92f5cadd0238996c)
- [🔐 06. 개인정보·보존·약관](https://app.notion.com/p/3b98320bd64b8160a9b1e60c3f1eca0c)
- [🏗️ 08. 방어 아키텍처·우선순위·Acceptance Criteria](https://app.notion.com/p/3b98320bd64b818bb4f7e4c4f13a7de6)
- [🧾 09. Red Team 테스트 계획·증거·검증 기록](https://app.notion.com/p/3b98320bd64b8189abb5d0618ddc4b0b)

## 첨부

정본에 원본 보고서 `MORA_ONDEVICE_DECISION_20261022.md`와 재현 자료 `MORA_ONDEVICE_EVIDENCE_20261022.json`을 첨부했다. 후자는 합성 입력·원본 출력·판정·버전·검증 스크립트 등 15개 파일의 스냅샷이며 가중치나 바이너리를 포함하지 않는다.

## 확인

- 저장 후 기존 15개 페이지와 새 정본을 다시 읽었다.
- 주요 문서 23개 변경 구간이 모두 반영되었음을 확인했다.
- 과거 감사 9개는 기존 본문 전체가 유지됨을 확인했다.
- MORA 메인에 새 정본이 실제 하위 페이지로 생성되었고 기존 하위 페이지가 보존되었다.
- 새 정본의 MD·JSON 첨부 2개와 정본 적용 범위를 확인했다.
- Fable 프롬프트의 잘못 이스케이프된 페이지 표기는 이동 없는 정상 페이지 멘션으로 보정했다.

