# MORA Eval — MORA AI 평가 하네스

평가 도구의 공식 이름은 **MORA Eval**입니다. 구현을 맡았던 에이전트 이름과
구분합니다. 명령은 `tools/mora-eval`에서 `deno task ...`로 실행합니다.

Mora의 KO/EN/JA 입력을 **함수 선택 + 모든 인자 + 불필요한 변경 제안**으로
평가합니다. 운영 `buildAnalysisPrompt()`와 `validateAnalysisCalls()`를 직접
가져옵니다. SDK, 외부 평가 서비스, LLM 심판은 필요하지 않습니다.

현재 배포물이 무엇인지 추정하지 않습니다. 평가 대상은 실행한 Git revision의
프롬프트·validator입니다. 원래 checkout의 미커밋 Claude fallback/온디바이스
작업은 이 변경에 포함하지 않았습니다. 그 작업을 합치거나 운영 모델·프롬프트가
바뀌면 새 revision에서 평가를 다시 실행해야 합니다.

## 현재 확인한 것

- 기존 러너는 날짜·제목·삭제 범위·반복·긴급도를 대부분 채점하지 않았습니다.
  `update_task.new_time` 대신 `time`을 읽는 오류도 있었습니다.
- 별도 하네스가 미커밋이라는 과거 문서는 있었지만, 조사한 현재 checkout, 관리
  worktree 및 최신 main에서는 그 구현을 찾지 못했습니다. 이번 변경은 찾을 수
  있었던 레거시 러너를 대체하는 명시적인 구현입니다.
- 신규 개발 데이터: **34개 시나리오 × 3개 언어 = 102건**. 모든 8개 함수,
  날짜/자정/연말/윤년, 정정·부정·예외, 반복, 복수 명령, 잡담, 주입 시도를
  포함합니다.
- 데이터는 새로 작성한 합성 사례이며 **사람 미검수(draft), development**입니다.
  실제 사용자의 분포나 임상 ADHD 수행능력을 대표하지 않습니다.
- fixture는 채점기 배선 확인입니다. 100%가 나와도 모델 정확도가 아닙니다. 실제
  Gemini/Jev 점수는 실행 결과가 있을 때만 보고합니다.
- 조사 시 현재 셸에 `GEMINI_API_KEY`가 없어 실제 API 품질 평가는 수행하지
  않았습니다. [검증 기록](evidence/validation.md)을 참고하세요.

## 빠른 시작 — API 호출 없음

Deno 2.9.6 기준입니다. 패키지 설치나 외부 의존성 다운로드가 없습니다.

```sh
cd tools/mora-eval
deno task validate
deno task check
deno task test
mkdir -p runs
deno task fixture --out runs/self-check
```

`runs/self-check/run.json`, `report.json`, `report.md`가 생성됩니다. 새
디렉터리만 허용하므로 기존 결과를 덮어쓰지 않습니다. `runs/`는 Git에서
제외됩니다. 테스트는 일부러 틀린 날짜·대상·시간·함수·호출 수·출력 형식·누락
결과를 넣어 채점기가 실패를 검출하는지 확인합니다. CI도 네트워크/키 없이 이
검사만 실행합니다.

## 실제 Gemini 기준선

키는 셸 환경변수 `GEMINI_API_KEY`로 제공합니다. 명령행 인자·Git·URL에 넣지
않습니다. 모델 ID는 **현재 운영/비교에 사용할 ID를 명시적으로 선택**합니다.
오래된 기본값을 묵시적으로 사용하는 경로는 없습니다.

저장소 루트에서 평가 코드를 커밋한 뒤 revision을 기록합니다.

```sh
REVISION=$(git rev-parse HEAD)
cd tools/mora-eval
# GEMINI_API_KEY는 사용자의 보안 환경에서 설정되어 있어야 합니다.
# 아래 MODEL_ID는 실제 사용할 유효한 모델 ID로 교체합니다.
MODEL_ID='gemini-REPLACE-WITH-ACTUAL-MODEL'
deno task live --live --model "$MODEL_ID" --revision "$REVISION" \
  --repetitions 3 --max-requests 306 --max-output-tokens 2048 \
  --timeout-ms 30000 --out runs/gemini-baseline
```

명시적 `--live`, 모델·revision·전체 데이터에 충분한 요청 한도가 있어야
호출합니다. 순차 실행·재시도 0회이며, 매 요청 후 run.json을 갱신합니다. 도중에
중단돼도 남은 사례는 채점 시 실패 분모에 남습니다. 응답 본문 크기·출력 토큰·대기
시간을 제한합니다. 요청 한도는 **달러 예산이 아닙니다**. 계정 요금·추론 토큰
과금까지 포함한 금전 한도는 제공자 측에서 별도로 관리해야 합니다.

운영 prompt와 temperature 0.1을 사용하되, 평가용 출력 토큰 상한을 추가합니다.
상한으로 잘린 출력은 실패입니다. 이는 명시된 설정의 **모델 단독 측정**이며
Supabase 인증·quota·fallback, iPhone STT·저장·알람의 종단 평가가 아닙니다. JSON
코드 펜스를 벗기거나 단일 object를 배열로 고치는 복구를 하지 않습니다. 따라서
운영에서 복구되는 결과도 strict JSON 지표에서는 실패할 수 있습니다.

응답 시간은 실패·타임아웃을 포함하고, 토큰 수는 제공자가 반환한 값만 기록합니다.
금액을 모르면 `null`이며 무료로 계산하지 않습니다. 출력 토큰 기록은 Gemini의
`candidatesTokenCount`이고 숨은 추론/캐시/계약 요금까지 반영한 청구서는
아닙니다.

## Jev·다른 모델·전체 파이프라인 비교

현재 Jev API나 특정 로컬 모델을 운영에 추가하지 않습니다. **Jev(TypeSafe)와
`feder-cr/jev`의 jevos는 서로 다른 제품**입니다. 시스템/모델 revision을
구분하세요.

두 시스템에 정답과 채점 기준이 같은 입력을 주고 전체 최종 결과를 비교합니다.
다음 명령은 정답·kind·rationale를 제외한 요청과 빈 run template을 만듭니다.

```sh
deno task prepare --model YOUR-MODEL-VERSION --system jev-plus-gemini \
  --revision YOUR-COMMIT --repetitions 3 --out runs/candidate-pack
```

`requests.jsonl`의 `system`, `text`, `current_time`, `language`를 평가용 외부
파이프라인에 넣습니다. `timezone`은 메타데이터입니다. 현재 운영 모델에 별도
timezone/기존 task 목록을 전달하는 기능을 추가한 것으로 해석하지 않습니다.
`run.json.configuration`에는 Jev 제품/버전, 분류 label, threshold, fallback
모델, 프롬프트 변경, 캐시 정책 등 **최종 출력에 영향을 준 모든 설정**을
기록합니다. 각 case × trial의 결과를 `predictions`에 추가합니다:

```json
{
  "case_id": "tomorrow-ko",
  "trial": 0,
  "request_hash": "requests.jsonl의 동일 case hash",
  "status": "ok",
  "response_text": "[{\"function_name\":\"...\",\"parameters\":{}}]",
  "latency_ms": 500,
  "cost_usd": 0.0001
}
```

위 응답은 **형식 설명용이며 유효한 정답이 아닙니다**. 오류는 `status: "error"`,
정제된 `error_code`로 기록합니다. `response_text`는 실제 최종 JSON 문자열이며
현재 함수 계약을 따라야 합니다. Jev가 label만 반환하면 날짜·대상 추출까지 포함한
파이프라인 결과로 변환하여 평가하세요. 분류기 label만으로 전체 Mora 품질을
검증했다고 할 수 없습니다.

- `latency_ms`: 분류+fallback+최종 결과까지의 총 시간. 모르면 null.
- `cost_usd`: 모든 호출 비용 합계. 추정이면 configuration에 요금 기준/날짜를
  기록. 모르면 필드를 생략합니다. 하나라도 비용이 없으면 전체 비용은
  unknown입니다.
- 외부 결과의 진위는 실행자가 입증해야 합니다. hash는 데이터/설정 혼동을 검출할
  뿐, API가 실제 호출됐다는 암호학적 증명은 아닙니다.
- fixture 결과를 imported로 이름만 바꿔 모델 성능처럼 사용하면 안 됩니다.

```sh
deno task score --run runs/candidate-pack/run.json --out runs/candidate-score
deno task compare --baseline runs/gemini-baseline/run.json \
  --candidate runs/candidate-pack/run.json --out runs/comparison
```

동일 데이터 hash·계약 hash·하네스 hash·반복 수가 필요합니다. 중복 ID, 잘못된
request hash, 누락 case는 비교를 거부합니다. 명시된 API 오류는 양쪽 모두 실패로
포함합니다. 버전이 다른 하네스 결과는 원래 commit에서 다시 채점/실행해야 합니다.

## 지표를 읽는 법

| 지표                               | 뜻 / 주의점                                                                                                          |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `command_exact`                    | 명령 사례의 호출 순서·개수·함수·모든 인자 일치. 틀린 날짜나 추가 명령 하나면 실패                                    |
| `contract_match`                   | 명령 exact + clarification/off-topic의 route와 비어 있지 않은 메시지 검사. **자유 응답의 의미 품질은 포함하지 않음** |
| `routing_accuracy`                 | 전체 함수 순서 일치. 인자가 틀려도 route는 맞을 수 있음                                                              |
| `route_sequence_macro_f1`          | 정답에 등장하는 함수 **순서 조합**별 F1 평균. 일반 단일 의도 F1과 구분                                               |
| `function_metrics`                 | 함수별 존재 여부 precision/recall/F1. 복수 호출 지원; 순서·중복은 exact 지표가 검출                                  |
| `field_accuracy`                   | 날짜·시간·대상·반복·긴급도 등 인자별 진단. 구조 오류/응답 누락도 실패 분모에 포함                                    |
| `unexpected_mutation`              | clarification/off-topic 사례에 변경을 제안한 비율. 유효하지 않은 schema의 제안도 집계                                |
| `destructive_mismatch`             | 삭제·수정·연기·완료 제안을 포함하고 계약 일치에 실패한 사례 수. 실제 실행 피해가 아닌 **보수적 검토 대상 proxy**     |
| `unnecessary_clarification`        | 처리 가능한 명령을 질문으로 돌린 비율. 전부 질문하기로 점수를 높일 수 없음                                           |
| `all_repetitions_pass`             | 각 사례가 모든 반복에서 맞은 비율. best-of-k가 아님; 반복 수를 함께 표시                                             |
| `family_macro_match`               | 시나리오별 평균의 동일 가중 평균. 번역·반복을 독립 표본으로 세지 않음                                                |
| `by_language`, `by_tag`, `by_risk` | 특정 언어나 삭제/부정/날짜 유형의 약점을 전체 평균 뒤에 숨기지 않음                                                  |
| latency / cost                     | 실패 포함 시간 p50/p95, 누락 없는 비용 합계. 100건 미만 p95는 소표본 표시                                            |

허용 가능한 제목 변형은 데이터의 `one_of`로 사전에 정의합니다. 부분
문자열·유사도 판정이나 모델의 자기 채점을 쓰지 않습니다. 명시된 제목을 엄격하게
채점하므로 자연어 동의어를 오답 처리한 사례는 사람이 검토하고 **다음 데이터
버전**에 반영합니다. 현재 데이터는 명시적인 제목을 사용해 이 문제를 줄였습니다.

bootstrap은 4,000번, 고정 seed로 **family 단위** 재표집합니다. 번역/반복은 함께
움직입니다. 비교는 같은 family의 후보−기준선 차이에 대한 paired interval입니다.
34개 합성 family의 구간은 탐색용이며 모집단 보증이 아닙니다. 오류 0건으로 [1,1]
구간이 나오더라도 진짜 오류율 0%를 증명하지 않습니다. 동일 family 안의 모든
입력을 반복하는 것만으로 독립 표본을 늘릴 수 없습니다.

## 출시 판단에 쓰기 위한 다음 단계

1. 이 공개 개발 세트는 프롬프트 개선·회귀 검출에 사용합니다. 점수에 맞춰 수정한
   세트를 나중에 held-out이라고 바꾸지 않습니다.
2. 별도 비공개 held-out을 수집합니다. 실사용 분포의 동의·비식별 입력과 위험
   시나리오를 구분하며, **초기 계획값**으로 독립 family 300개 이상, 언어별 100개
   이상을 목표로 합니다. 번역/재표현/반복은 같은 family를 유지합니다.
3. 사람이 정답·허용 표현·위험도·지원 불가능한 요구를 검수합니다. 특히
   삭제·수정과 애매한 입력은 2인 독립 검수 후 불일치를 조정합니다.
   reviewer/date를 기록하고 입력/정답/설정 hash를 고정합니다. 에이전트 검토를
   human_reviewed로 바꾸지 않습니다.
4. 표본 크기와 도입 기준을 **결과 전에** 정합니다. 예시로 command exact의 후보
   개선 ≥2%p, paired 구간의 하한 >0, critical 회귀 0건, 언어별 퇴보 없음, 목표
   지연 예산 충족을 검토할 수 있습니다. 이는 **제안값이지 합의된 출시 기준이
   아닙니다**. 작은 차이를 검출하려면 실제 기저 오류율로 더 많은 표본을 설계해야
   합니다.
5. 3회 이상 반복하고 동일 환경·캐시 조건으로 baseline/candidate를 교차
   실행합니다. 임계값은 development에서만 고르고 held-out 결과를 본 뒤 고르지
   않습니다.
6. clarification 이유의 적절성, 답변 언어/톤, 실제 task resolver의 대상 선택,
   알람·STT·권한·offline/fallback은 별도 앱 QA로 확인합니다. 도구는 자동 출시
   PASS를 내지 않습니다.

독립 위험 시나리오 n개에서 오류가 0번일 때도 대략적인 95% 상한은 3/n입니다.
예컨대 300개에서도 약 1%입니다. 전체 300개를 위험한 삭제 300개로 바꿔 세면 안
되며, 상관된 번역 표본에는 이 단순 근사를 적용하지 않습니다.

공개 벤치마크와 기존 러너의 감사 내용은 [설계·벤치마크 조사](DESIGN.md)를
참고하세요.
