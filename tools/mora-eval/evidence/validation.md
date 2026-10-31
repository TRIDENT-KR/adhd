# 검증 기록 — 2026-10-29

대상: `codex/mora-ai-eval`, base `84f95e6`.

- Deno 2.9.6 / macOS arm64. 외부 의존성 없음.
- 결과: 신규 하네스 테스트 **28 passed / 0 failed**, 기존 서버 계약 테스트 **11
  passed / 0 failed**. 타입 검사·lint·format·데이터 검증 통과.
- 모든 102개 gold 응답이 실제 운영 validator를 통과하고 채점기에 일치함을 확인.
  이것은 데이터/채점기 내부 정합성 검사이며 모델 정확도가 아님.
- 의도적인 날짜·시간·제목·반복·긴급도·삭제 범위·호출 수·형식 오류를 넣은 회귀
  검사.
- 응답 누락·API 오류의 분모 유지, 중복/변조 hash 거부, 반복/번역 family 집계
  검사.
- 네트워크 mock으로 요청 payload·timeout·실패 본문 비노출·응답 크기 제한 검사.
- CLI gold-free export, 결과 덮어쓰기 거부, 빈 run 0점/누락 102건 검사.
- 원본 운영 프롬프트의 6개 렌더링 hash 비교.
- 기존 analysis-service/validator 회귀 검사.

현재 셸에 GEMINI_API_KEY가 없어 실제 Gemini/Jev 추론은 실행하지 않았습니다.
fixture 실행은 네트워크 없이 정답 fixture를 넣은 도구 자체 확인입니다. 이 기록을
Gemini 정확도나 출시 승인으로 인용하면 안 됩니다.

최종 검사 명령:

```sh
deno fmt --check tools/mora-eval supabase/functions/analyze-task/prompt.ts
deno lint tools/mora-eval
deno task --cwd tools/mora-eval check
deno task --cwd tools/mora-eval validate
deno task --cwd tools/mora-eval test
deno test --no-remote supabase/functions/analyze-task/validator_test.ts supabase/functions/analyze-task/analysis-service_test.ts
```

## 같은 날 후속 통합

보존된 로컬 변경과 main을 합친 뒤 하네스 28개, 전체 서버 86개(18 steps), 로컬 DB
97개, macOS 분석·알람 큐 15개 검사가 통과했습니다. 프롬프트 snapshot은 로컬 운영
커밋 `2e1a123`의 의도적인 제약 추가에 맞춰 갱신했습니다.
[통합 검증 기록](../../../research/integration-20261029/validation.md)에 iOS
전체 테스트 실행 제한을 포함해 구분해 두었습니다. 실제 모델 정확도 평가는
아닙니다.
