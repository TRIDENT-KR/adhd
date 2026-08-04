# MORA_IMPLEMENTATION_PLAN.md

> **이 문서 하나만 보고 전체 기능을 구현할 수 있도록 작성된 자기완결적 구현 기획안.**
> 대상 구현자: Opus 4.8 / Sonnet 5 (추가 질문 없이 실행 가능해야 함).
> 근거: `MORA_SPEC.md` + 코드베이스 전체 정독(2026-07-07) + 사용자 인터뷰 20문항(5라운드, 전부 답변 완료) + [MORA 보안 감사 대응 SDD — 확정 결정사항 (2026-08-01)](https://app.notion.com/p/3af8320bd64b81788d14d50c9cfc2379).
> 작성일: 2026-07-08 · 보안 SDD 동기화: 2026-08-04

> **문서 우선순위:** `2026-08-04 사용자 인터뷰 INT-01~35` > `2026-08-01 보안 SDD` > `D1~D24 / Phase 1~5`. Phase 1~5는 완료 이력으로 보존하며, 충돌하는 동작은 Security Phase 6~11과 §15의 확정 결정으로 교체한다. Finding #21은 이번 범위에서 제외한다.

---

## ⚠️ 구현 현황 로그 (2026-07-09 갱신 — 브랜치 `feat/urgency-alarm-system`)

이 문서는 2026-07-07 `main`(fec2f53) 기준으로 작성되었으나, 이후 **알림 시스템 리워크(1c031db)와 후속 수정이 문서의 일부 지시를 선반영**했다. 아래 완료 항목은 재구현하지 말 것. **문서 내 모든 라인 번호는 밀렸으므로 반드시 주변 코드로 재탐색.**

### 선반영 완료 (재작업 금지)

| 문서 위치 | 상태 |
|---|---|
| §3.6 버그①(weak urgency userInfo)·버그②(criticalAlert)·알림 문구 L화 | ✅ 1c031db에서 완료. 단 알림 액션은 Confirm 단일이 아니라 **Done("완료")+Snooze("5분 뒤 다시")** 2종으로 진화 (`L.alarm.completeAction`/`snoozeAction`) |
| §3.7 오버레이 Pro 게이팅(D14) | ✅ 완료. **`AlarmManager`는 `AlarmCoordinator`로 리네임됨** (AlarmKit.AlarmManager 이름 충돌 회피). 파일명은 `AlarmManager.swift` 유지 |
| §3.8 AlarmOverlayView L화 | ✅ 완료 (`L.alarm.overlaySubtitle/overlayConfirm/overlayHint` 존재) |
| §3.9 premium 플래그 App Group 기록 | ✅ `SubscriptionManager.premiumFlagKey` 존재, NotificationManager·AlarmCoordinator가 이미 읽음. WidgetCenter 리로드 연동만 F4에서 확인할 것 |
| §8.2 알림 매트릭스 | ⚠️ **부분 대체됨**: strong×Pro는 이제 UN 알림이 아니라 **AlarmKit 시스템 알람**(`SystemAlarmScheduler.swift`, 앱 종료 상태에서도 풀스크린)으로 승격. UN 경로는 폴백. 일회성 strong에 +5/+10분 팔로업 체인, 스누즈 존재. §8.2는 UN 폴백 경로의 명세로만 유효 |
| §3.13 `.toggled` 언두 `isDeleted` 가드 | ✅ 이미 존재 |
| §3.13/§3.14 언두 스냅샷 urgency | ✅ `.deleted` 튜플에 `urgency: Urgency` 추가됨(07-09). `.updated`의 previous 튜플도 `urgencyRaw: String`이 아닌 **`urgency: Urgency`로 통일**할 것 (F5⑤ 구현 시) |
| §7.3 `mark_task_complete` | ✅ 완료 시 알림 정리(`clearNotificationsAfterCompletion`) 추가됨(07-09) — 언두는 여전히 `.toggled` |

### 문서 범위 밖 신규 수정 (2026-07-09 — 충돌 주의)

NotificationManager/TaskManager/VoiceInputManager를 수정할 때 아래 코드를 되돌리거나 우회하지 말 것:

- **오디오 세션 해제**: `VoiceInputManager`가 녹음 종료·백그라운드 진입 시 `deactivateAudioSession()` 호출 (미해제 시 타 앱 미디어 차단 버그)
- **고아 알림 자가치유**: `TaskManager.cleanupOrphanedNotifications()`가 매 포그라운드마다 실존 태스크와 대조해 UN 알림+AlarmKit 알람 회수 (MyApp scenePhase 훅)
- **등록-삭제 경합 차단**: `NotificationManager.cancelledIds` 레지스트리 — 비동기 등록이 완료 직전 취소 여부를 확인
- **`AlarmCompletionRelay`**: NSLock 직렬화 + 원자적 `drain()` — 직접 UserDefaults 읽기/삭제로 되돌리지 말 것
- `deleteCompleted()`에 알림 취소 추가됨

### 남은 작업 (이 문서 기준)

**✅ 전 Phase 구현 완료 (2026-07-09)** — Phase 1(PR #59로 main 머지), Phase 2~5(브랜치 `feat/mora-phase2-pro-gating`).

- Phase 2: 위젯 6종 잠금(`WidgetLockedView`) + 버그③(위젯 언어 App Group) + `mora://paywall` 딥링크 + 카피 일치화
- Phase 3: `QuickAddSheet` 3모드 + Routine/Planner + 버튼 (pbxproj 수동 등록 — 앱 타깃은 동기화 그룹 아님)
- Phase 4: `OnboardingView` 3장(D21/D22 플래그 로직) + ? 가이드 버튼 + guideHint 삭제
- Phase 5: 테스트 5파일 전부 green (`checkAndResetDailyTasks`는 now/defaults 주입형으로 리팩터링),
  README 주간 셀렉터 정정, DESIGN.md 확정 차이 Appendix 추가.
  추가 발견 수정: 빈 `ADHDUITests` 타깃이 스킴 Test 액션에 포함되어 `xcodebuild test`가 항상 실패하던
  문제 — 스킴에서 제거 (D19: UI 테스트 범위 제외)

**남은 것 (코드 밖)**
- Edge Function 배포: `supabase functions deploy analyze-task` (07-08 기준 미배포)
- §12 수동 QA 체크리스트 수행 (실기기, 언어×테마×요금제 매트릭스)

### 최신 보안 SDD 후속 작업 (2026-08-04 — 구현 진행)

Phase 1~5 완료와 별개로 Security Phase 6~11을 수행한다. 2026-08-04 현재 로컬 구현과 격리 테스트를 진행했으며, 정확한 구현·부분 구현·외부 미작업 상태는 §15를 단일 상태 원장으로 사용한다.

---

## 목차

1. [Executive Summary](#1-executive-summary)
2. [결정 사항 로그 (D1~D24 + SDD-1~9)](#2-결정-사항-로그)
3. [파일별 변경 목록 (기존 파일)](#3-파일별-변경-목록)
4. [신규 파일 목록](#4-신규-파일-목록)
5. [데이터 모델 / Supabase 스키마](#5-데이터-모델--supabase-스키마)
6. [화면별 상세 스펙](#6-화면별-상세-스펙)
7. [음성 파싱 파이프라인 상세](#7-음성-파싱-파이프라인-상세)
8. [위젯 / 알림 상세 스펙](#8-위젯--알림-상세-스펙)
9. [엣지 케이스 & 에러 핸들링](#9-엣지-케이스--에러-핸들링)
10. [접근성 / 성능 / 비기능 체크리스트](#10-접근성--성능--비기능-체크리스트)
11. [작업 순서 (Phased Rollout)](#11-작업-순서-phased-rollout)
12. [QA / 테스트 체크리스트](#12-qa--테스트-체크리스트)
13. [디자인 금기/지침 셀프 체크](#13-디자인-금기지침-셀프-체크)
14. [최신 보안 SDD 정합성 명세](#14-최신-보안-sdd-정합성-명세)
15. [2026-08-04 인터뷰 확정 및 구현 상태](#15-2026-08-04-인터뷰-확정-및-구현-상태)

---

## 1. Executive Summary

### 1.1 전제: 앱의 현재 상태

Mora(구 Wait, What?)는 **이미 대부분 완성된 앱**이다. 3개 탭(Home/Routine/Planner) 전부 동작하고, 음성 파이프라인(SFSpeechRecognizer STT → Gemini 2.0 Flash 함수 호출 8종 → 확인 카드 → SwiftData 저장), 위젯 6종(인터랙티브 토글 + 딥링크), 로컬 알림(강/약 2단계 + 풀스크린 알람 오버레이), Apple 로그인, StoreKit 2 구독(무료 AI 3회/일), 3개 국어(en/ko/ja), 언두 스택, 검색, 드래그 리오더, 주간 완료 트래커(WeeklyBar)까지 구현되어 있다. **이번 작업은 "앱을 새로 만드는 것"이 아니라 "기존 앱을 스펙과 일치하는 완성 상태로 끌어올리는 것"이다.**

### 1.2 이번 구현 범위 (F1~F8)

| ID | 작업 | 종류 | 관련 결정 |
|---|---|---|---|
| **F1** | 경량 온보딩 3장 신설 (로그인 직후, 스킵 가능) | 신규 기능 | D18, D21, D22 |
| **F2** | 음성 가이드 시트 재연결 (? 버튼 + 조건부 자동 1회) | 버그 수정+개선 | D7, 버그④ |
| **F3** | AI 미경유 "빠른 추가" (Routine/Planner 탭 + 버튼) | 신규 기능 | D9 |
| **F4** | Pro 게이팅: 위젯 잠금 + 풀스크린 알람 Pro 전용화 + 페이월 카피 일치화 | 신규 기능 | D8, D13, D14 |
| **F5** | 버그 수정 13건 (weak 알람 오버레이 오발동, criticalAlert, 위젯 다국어, 한국어 하드코딩 7곳, 언두 중복 등) | 버그 수정 | D17, D23, D24 |
| **F6** | Supabase 스키마 설계 (— **문서 §5에만 수록, 코드 구현 없음**) | 문서 전용 | D1 |
| **F7** | 단위 테스트 5파일 신규 작성 (순수 로직) | 테스트 | D19 |
| **F8** | LLM 프롬프트 미세 보강 (postpone 반복 제외 규칙 1줄) | 프롬프트 | D23 |
| **F9** | 계정별 로컬 데이터 격리 + 인증 상태 머신 + 로그아웃 정리 | 보안 기반 | SDD-1, SDD-2 |
| **F10** | 멱등적 서버 계정 삭제 작업 + 로컬 삭제 + 재시도·완료 상태 | 보안 기능 | SDD-3 |
| **F11** | 서버 AI quota 원장 + 원자적 성공 차감 + abuse limiter | 백엔드 | SDD-4 |
| **F12** | StoreKit transaction과 Mora 계정 연결·복원 | 결제 보안 | SDD-5 |
| **F13** | 편집 가능한 음성 초안 + 마이크 생명주기 + 파괴적 명령 확인 | UX·보안 | SDD-6, SDD-7 |
| **F14** | 최초 기준일 기반 반복 엔진 + 실제 날짜 알림 재예약 | 일정 엔진 | SDD-8 |
| **F15** | 민감 로그 제거 + 배포 후 canary 검증 | 운영 보안 | SDD-9 |

### 1.3 이번 구현에서 명시적으로 **제외**되는 것 (범위 밖)

| 제외 항목 | 근거 결정 | 비고 |
|---|---|---|
| Supabase 일정 데이터 동기화/백업 구현 | D1, SDD-1 | 일정 본문은 로컬 전용 유지. 단 서버 삭제 작업, AI quota, entitlement, 구독 연결 정보는 F10~F12 범위에 포함 |
| Memo(빠른 메모) 카테고리 | D2 | 스펙 JTBD #3은 이번 범위에서 드랍. 2분류(Routine/Appointment) 유지 |
| EventKit(iOS 캘린더) 연동 | D3 | 자체 저장소 유지 |
| 온디바이스 SLM 전환 | D4 | Cloud LLM(Gemini 2.0 Flash) 유지 |
| 오프라인 AI 요청 큐 | D5, SDD-2 | 유효한 저장 세션이면 로컬 일정 확인·수정은 허용하지만 AI·Pro 확인·계정 변경·서버 삭제 요청은 차단 |
| 숫자형 스트릭 카운터 | D10 | WeeklyBar 유지, 모델 변경 없음 |
| 태스크별 사전 알림 오버라이드 | D12 | 전역 단일 값(정시/5/10/15/30분) 유지 |
| Manrope/Inter 커스텀 폰트 | D15 | 시스템 폰트 확정 |
| UI 테스트(XCUITest) | D19 | 수동 QA 체크리스트(§12)로 대체 |
| iPad 전용 레이아웃 | — | 스펙·인터뷰 모두 미요구. iPhone 세로 기준 |

### 1.4 구현 시 절대 전제

- **기술 스택 변경 금지**: SwiftUI + SwiftData + Supabase(Auth/Edge Function) + StoreKit 2 + WidgetKit. 외부 라이브러리 추가 없음.
- **계정별 물리 저장소 확정**: `Application Support/MoraAccounts/<SHA-256(Mora UUID)>/Mora.sqlite`를 사용한다. 생산 사용자가 없는 현재 cutover에서는 기존 owner 없는 테스트 DB를 한 번만 명시적으로 초기화하며 import하지 않는다. 이후 런타임 자동 삭제는 금지한다.
- **디자인 금기 5종**(§13) 위반 금지. 신규 UI(온보딩, QuickAddSheet, 위젯 잠금 뷰)도 전부 적용 대상.
- 배포 타깃 iOS 26.2, 번들 `trident-KR.ADHD`, App Group `group.trident-KR.ADHD`.

---

## 2. 결정 사항 로그

인터뷰(Q1~Q20, 5라운드)에서 확정된 결정 + 파생 확정 사항. D1~D24는 2026-07 구현의 완료 이력이고, 동일 주제에 대한 `SDD-*` 결정은 2026-08-01 이후의 최종 동작이다.

| ID | 결정 | 근거/출처 |
|---|---|---|
| **D1** | 일정 본문은 SwiftData 로컬 유지. Supabase 일정 동기화·백업은 구현하지 않음. 단 계정별 로컬 격리와 서버의 삭제 작업·quota·entitlement·구독 연결은 SDD-1~5에 따라 구현 | 보안 SDD가 로컬 전용 원칙은 유지하되 계정 경계와 서버 권한 검증을 추가 |
| **D2** | Memo 카테고리 미추가. JTBD #3 "빠른 메모"는 스펙에서 드랍 | 2분류 체계(`AppTask.swift:20`, LLM 프롬프트)가 이미 안정적. 사용자 확정 |
| **D3** | EventKit 미연동. 자체 저장소 유지 | "한 곳에서만 관리"가 ADHD 타깃에 명료. 사용자 확정 |
| **D4** | 온디바이스 SLM 범위 제외. 문서상 로드맵으로만 존재 | 스펙 §3의 명시적 확인 항목. 사용자 확정 |
| **D5** | 오프라인 AI 분석·서버 변경은 차단한다. 유효하고 만료되지 않은 저장 세션이며 명시적 로그아웃·삭제 대기가 아니면 로컬 일정 확인·수정은 허용한다. 오프라인 요청 큐는 없음 | SDD-2가 기존의 전체 오프라인 차단을 대체 |
| **D6** | STT 언어 = 앱 설정 언어 자동 동기화(현행). `cycleLanguage`/`enabledLocales`는 죽은 코드로 삭제 | `VoiceInputManager.swift:415-423` 현행 채택 |
| **D7** | 음성 가이드: 상단 바 ? 버튼으로 상시 진입 + (온보딩 스킵자에 한해) 첫 Home 진입 시 자동 1회. 롱프레스 힌트 문구 삭제 | 버그④(`showVoiceGuide` 트리거 부재) 해결책 |
| **D8** | Pro 경계 = ①정상 사용 범위 AI 무제한 ②위젯 ③풀스크린 알람. Pro 권한은 기기가 아니라 구매 당시 Mora 계정에 귀속하며 서버 검증 결과를 권한의 진실 원천으로 사용 | SDD-4, SDD-5가 클라이언트 전용 게이팅을 대체 |
| **D9** | Routine/Planner 탭에 AI 미경유 "빠른 추가"(+ 버튼 → 경량 시트) 신설. AI 할당량 무관 | 무료 사용자가 할당량 소진 후에도 추가 가능해야 함. 사용자 확정 |
| **D10** | 스트릭 카운터 미추가. WeeklyBar(주간 완료 바) 유지 | 스트릭 붕괴가 ADHD 사용자에게 포기 트리거가 될 수 있음. 사용자 확정 |
| **D11** | Planner의 월간 그래픽 캘린더 **시트**는 유지. "먼 날짜 점프용 임시 도구"로서 디자인 금기 #4의 명문화된 예외. 메인 뷰는 7일 주간 유지 | `PlannerView.swift:148-188`. 사용자 확정 |
| **D12** | 사전 알림(Remind Before)은 전역 단일 값 유지 | 설정 항목 최소화(결정 피로 최소화). 사용자 확정 |
| **D13** | 무료 사용자 위젯 = 잠금 플레이스홀더(자물쇠+"Mora Pro"), 탭 → `mora://paywall`. App Group의 `isPremiumUser`는 서버에서 검증된 현재 Mora 계정 entitlement의 표시용 캐시일 뿐 권한 판정 원천이 아니다. 로그아웃·계정 전환 시 계정 데이터와 함께 즉시 제거 | SDD-1, SDD-5 |
| **D14** | strong 알림: 무료 사용자도 strong 선택 가능 + time-sensitive 알림 수신. **풀스크린 오버레이 표시만 Pro 전용** (무료는 일반 배너 폴백). 게이팅 분기는 `AlarmManager` 오버레이 표시 지점 | 기능 회수 감각 최소화. 사용자 확정 |
| **D15** | 시스템 폰트(SF/산돌고딕/히라기노) 확정. Manrope/Inter 미도입. DESIGN.md의 자간 규칙 중 헤드라인 네거티브 tracking만 유지(현행 `-0.5` 수준) | 라틴 전용 폰트라 ko/ja에서 효과 없음. 사용자 확정 |
| **D16** | 알림 권한 요청 시점 현행 유지 (로그인 후 메인 진입 0.5초 뒤, `MyApp.swift:109-113`). 단 `.criticalAlert` 옵션은 버그②로 제거 | 사용자 확정 |
| **D17** | 발견 버그/불일치 13건 전부 이번 범위에 포함 (§3에 건별 수정 방법 명시) | 사용자 확정 |
| **D18** | 경량 온보딩 3장 신설 (로그인 직후, 스킵 가능): ①가치 제안 ②예시 명령어 ③시작 CTA | 스펙 §9 온보딩 흐름 질문에 대한 답. 사용자 확정 |
| **D19** | 비기능 기준: 성능(녹음 종료→확인 카드 p90 ≤ 4초 정상 네트워크 / 마이크 탭→리스닝 ≤ 0.3초 / 콜드 스타트→홈 렌더 ≤ 2초), 접근성(신규 UI 전부 VoiceOver 라벨+힌트, reduceMotion, 44pt 히트 타깃, Dynamic Type 최대 사이즈 QA), 테스트(순수 로직 단위 테스트 5영역, UI 테스트 제외) | 사용자 승인 |
| **D20** | 문서·주석 언어: 한국어 본문 + 영문 기술 용어/식별자 | 사용자 확정 |
| **D21** | 온보딩 **완료** 시 `hasSeenVoiceOnboarding=true`도 함께 설정 → Home 가이드 자동 표시 생략. 온보딩 **스킵** 시에만 첫 Home 진입 때 가이드 자동 1회. ? 버튼은 항상 노출 | D7×D18 중복 해소(예시 명령어가 온보딩 2장과 겹침) |
| **D22** | 기존 사용자(업데이트 설치, 태스크 1개 이상 보유)는 온보딩 자동 스킵 (`hasCompletedOnboarding=true` 자동 설정) | 업데이트 사용자에게 온보딩 재노출 방지 |
| **D23** | `postponeAllTasks`: 반복 일정(recurrenceRule != nil)은 연기 대상에서 제외(일회성만 이동). 이동 결과(0건 포함)를 스낵바로 피드백. LLM 프롬프트에 제외 규칙 명시 | 회차 예외(exception dates) 모델 없이 일관 동작 확보 |
| **D24** | 디자인 세부: 코드 현행 값을 공식 스펙으로 채택 — 카드 radius 18~24pt, Glass 현행 구현(ultraThinMaterial), 주간 셀렉터 "오늘 고정+선택일 ±7일" 윈도우. 단 **UndoSnackbar 배경만** 중성 회색 → 웜 톤으로 실제 수정 (§3.2) | DESIGN.md와의 차이는 §13.2에 명문화 |
| **SDD-1** | A 로그아웃 시 A 일정은 보존하되 B 로그인에서는 B 데이터만 표시한다. SwiftData 조회·위젯·알림·Undo를 현재 Mora 계정 범위로 격리한다 | 최신 보안 SDD §1~2 |
| **SDD-2** | 인증 상태를 부팅·온라인 인증·오프라인 제한 인증·명시적 로그아웃·삭제 대기·무효 세션 잠금으로 구분한다. 로그아웃·세션 무효 시 일정 본문은 보존하지만 알림·AlarmKit·위젯·음성 초안·민감 Undo 노출을 정리한다 | 최신 보안 SDD §2 |
| **SDD-3** | 서버 삭제 요청 뒤 로컬 노출은 즉시 잠그되 물리 store는 서버 완료 확인 후에만 삭제한다. 요청 ID/status token으로 멱등 재개하며 오류를 성공으로 표시하지 않는다 | INT-07, INT-08, INT-34가 SDD 세부 순서를 확정 |
| **SDD-4** | 무료 AI는 모든 사용자에게 `Asia/Seoul` 날짜 기준 하루 3회이며 서버 원장이 권위자다. 스키마에 맞는 분석 응답만 성공 차감하고 네트워크·서버·decode·invalid 실패는 미차감한다. 한 사용자 분석의 네트워크 재시도는 같은 request ID를 사용한다 | INT-13, INT-14, INT-16 |
| **SDD-5** | Pro는 구매 당시 Mora 계정에 귀속한다. 다른 기기는 Apple 검증 후 같은 계정에 복원하고 다른 Mora 계정과 공유하지 않는다. Family Sharing은 v1에서 지원하지 않는다 | 최신 보안 SDD §4 |
| **SDD-6** | STT 종료 후 인식 문장을 편집 가능한 임시 입력으로 보여주며 사용자가 명시적으로 추가·분석을 눌러야 AI를 호출한다. 실패해도 초안을 유지하고 로그아웃·삭제 시 제거한다 | 최신 보안 SDD §5 |
| **SDD-7** | 추가·일반 수정은 `confirmBeforeSave`를 따르지만 삭제·전체 삭제·대량 변경은 설정과 무관하게 항상 대상·날짜·종류·개수를 확인한다 | 최신 보안 SDD §5 |
| **SDD-8** | 격주는 최초 기준일에서 정확히 14일, 월말 부재 날짜는 해당 월 마지막 날로 계산한다. 완료가 늦어도 기준일은 이동하지 않으며 실제 다음 날짜를 계산해 알림을 1회씩 재예약한다 | 최신 보안 SDD §6 |
| **SDD-9** | 일정명·루틴명·음성 전사문·LLM 원문 응답을 운영 로그에 남기지 않는다. 로그인은 Apple만 지원하며 공급자 추상화·최근 로그인 공급자 UI·다른 소셜 로그인은 구현하지 않는다 | INT-05, INT-26, INT-27 |

### 2.1 스펙 §11 "확인 필요" 항목 ↔ 답 매핑 (완결성 증명)

| 스펙 §11 항목 | 답 | 근거 |
|---|---|---|
| 1. Home: 마이크 인터랙션 / 확인 UI / 재시도 흐름 | 탭 토글+홀드 듀얼(설정 선택) / 확인 카드 기본 on(설정 토글) / 에러 토스트+Try Again — **전부 현행 채택** | 코드 구현 완료 (`VoiceInputManager.swift:32-35`, `HomeVoiceInterfaceView.swift:664-923, 299-344`) |
| 2. Routine: 수동 CRUD / 완료 인터랙션 / 스트릭 / 알림 커스터마이징 | 수동 생성은 F3 신설, 편집·삭제 현행 / 체크박스 탭 현행 / 스트릭 없음(D10) / 카테고리 토글+전역 사전알림+태스크별 urgency 현행 | D9, D10, D12 |
| 3. Planner: EventKit / 카드 밀도 / 수동 추가·편집 | 미연동(D3) / 체크박스+제목+시간+반복+긴급도 현행 / 추가는 F3, 편집 현행 | D3, D9 |
| 4. 음성 파싱: 분류 로직 / 애매 발화 / 폴백 | §7에 전체 명세 (현행 채택 + F8 보강) | 코드 구현 완료 |
| 5. 데이터 모델: Supabase 스키마 | 로컬 유지(D1), 스키마는 §5.2 DDL 초안 | D1 |
| 6. 위젯: 종류/표시 정보/딥링크 | 6종 현행 + F4 잠금 상태 추가, `mora://` 딥링크 현행+`/paywall` 추가 | §8 |
| 7. 알림: 로컬 vs 푸시 / 커스터마이징 / 권한 시점 | 로컬 전용 확정 / 현행 유지(D12) / 현행 유지(D16) | §8 |
| 8. 비기능: 오프라인/동기화/접근성/성능/온보딩/로그인/결제/다국어 | D5 / D1 / D19 / D19 / D18 / Apple 로그인 현행 / StoreKit 2 + D8 경계 / 앱 내 설정(현행) | §10 |
| 9. 핵심 컴포넌트 5종 세부 스펙 | §6.6에 코드 현행 수치로 전부 문서화 | D24 |

---

## 3. 파일별 변경 목록

> 경로는 레포 루트 기준. **라인 번호는 2026-07-07 `main`(커밋 `fec2f53`) 기준** — 구현 시점에 밀렸을 수 있으므로 항상 주변 코드로 재확인할 것.
> `[F#]`은 §1.2 작업 ID, `[버그#]`은 §2 D17이 가리키는 버그 번호.

### 3.1 `ADHD/MyApp.swift`

| 변경 | 내용 |
|---|---|
| [F1] 온보딩 분기 | `@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false` 추가. body의 분기를 3단으로 변경: 세션 로딩 중 → ProgressView(현행) / `session != nil && !hasCompletedOnboarding` → `OnboardingView()`에 `.modelContainer(container)`, `.preferredColorScheme(colorScheme)`, `.environment(\.locale, ...)` 적용해 표시 / `session != nil` → MainTabView(현행) / 그 외 → LoginView(현행) |
| [F4] 페이월 딥링크 | `handleWidgetDeepLink(_:)` 를 다음 구조로 변경: `guard url.scheme == "mora" else { return }` 후 `switch url.host` — `"tab"`: 기존 로직 유지, `"paywall"`: `NotificationCenter.default.post(name: .openPaywall, object: nil)`, default: break |

변경 전 핵심 로직: `guard url.scheme == "mora", url.host == "tab" else { return }` (52행) — tab 외 host는 전부 무시.
변경 후: host 스위치로 확장, 기존 tab 라우팅은 그대로.

### 3.2 `ADHD/MainTabView.swift`

| 변경 | 내용 |
|---|---|
| [F4] 페이월 시트 | `@EnvironmentObject private var subscriptionManager: SubscriptionManager` 추가 (MyApp이 이미 96행에서 주입 중). `@State private var showPaywall = false` 추가. `.onReceive(NotificationCenter.default.publisher(for: .openPaywall)) { _ in showPaywall = true }` + `.sheet(isPresented: $showPaywall) { NavigationView { PaywallView().environmentObject(subscriptionManager) } }` 추가 (기존 `.fullScreenCover` 아래에 배치) |
| [F4] Notification 이름 | 파일 하단 `extension Notification.Name`(108-111행)에 `static let openPaywall = Notification.Name("openPaywall")` 추가 |
| [버그⑩] Strings 직접 사용 | `OfflineBanner`의 `DesignSystem.Strings.offlineAlertText`(160, 175행) → `L.offlineText` 로 교체 (DesignSystem.Strings 삭제의 선행 작업) |
| [버그⑪][D24] UndoSnackbar 웜 톤 | `UndoSnackbar.backgroundColor`(118-122행)의 중성 회색을 웜 톤으로 교체: 다크 `UIColor(r: 0x3A, g: 0x2A, b: 0x22)` / 라이트 `UIColor(r: 0x4A, g: 0x30, b: 0x25)` — 에러 토스트(`HomeVoiceInterfaceView.swift:334-338`)와 동일 계열 |

### 3.3 `ADHD/HomeVoiceInterfaceView.swift`

| 변경 | 내용 |
|---|---|
| [F2][D7] ? 버튼 추가 | 상단 바 HStack(46-96행)의 왼쪽 클러스터에 버튼 추가. 순서: [키보드 토글] [? 버튼] Spacer [AI 카운터] [설정]. 스펙: `Image(systemName: "questionmark.circle")`, `.font(.title3.weight(.medium))`, `.foregroundColor(DesignSystem.Colors.onSurfaceVariant)`, `.frame(minWidth: 44, minHeight: 44)`, `.contentShape(Rectangle())`, 액션 `showVoiceGuide = true`, `.accessibilityLabel(L.voice.guideTitle)` |
| [F2][D21] 자동 1회 표시 | 기존 `.onAppear`(196-201행, isBreathing/setupSpeechCallback/warmUp) 안에 추가: `if !hasSeenVoiceOnboarding { showVoiceGuide = true }` — 온보딩 완료자는 D21에 따라 이미 `hasSeenVoiceOnboarding == true`이므로 자동 표시 없음. 기존 sheet의 `onDismiss`(359-361행)가 `hasSeenVoiceOnboarding = true` 설정을 이미 수행하므로 그대로 활용 |
| [F2] 힌트 문구 삭제 | 253-258행의 `if !hasSeenVoiceOnboarding { Text(L.voice.guideHint) ... }` 블록 삭제 (동작하지 않는 롱프레스 안내). `Localization.swift`의 `guideHint` 키도 삭제 |
| [버그⑥] OOV 카드 하드코딩 | 685행 `(isOffTopic ? "알림" : ...)` → `(isOffTopic ? L.voice.offTopicTitle : ...)`. 904행 `Text(isOffTopic ? "다시 질문하기" : L.voice.confirmButton)` → `Text(isOffTopic ? L.voice.askAgain : L.voice.confirmButton)` |
| [버그⑩] TaskEditSheet 삭제 | 926-988행 `struct TaskEditSheet` 전체 삭제 (레포 전체에서 참조 0건 — 삭제 전 `grep -rn "TaskEditSheet"` 재확인) |

### 3.4 `ADHD/RoutineView.swift`

| 변경 | 내용 |
|---|---|
| [F3][D9] + 버튼 | 헤더 HStack(69-85행)에 검색 버튼 **왼쪽**으로 추가: `Image(systemName: "plus")`, `.font(.title3.weight(.light))`, `.foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))`, `.frame(minWidth: 44, minHeight: 44)`, `NoEffectButtonStyle()`, `.accessibilityLabel(L.quickAdd.title)`. 액션: `showQuickAdd = true` |
| [F3] 시트 연결 | `@State private var showQuickAdd = false` 추가. `.sheet(isPresented: $showQuickAdd) { QuickAddSheet(mode: selectedSection == .routines ? .routine : .todayTask) }` — 기존 `.sheet(isPresented: $showSearch)`(182행) 아래 |

### 3.5 `ADHD/PlannerView.swift`

| 변경 | 내용 |
|---|---|
| [F3][D9] + 버튼 | 헤더 HStack(55-101행)의 아이콘 클러스터 **맨 왼쪽**(리오더 버튼 앞)에 RoutineView와 동일 스펙의 + 버튼 추가. 액션: `showQuickAdd = true` |
| [F3] 시트 연결 | `@State private var showQuickAdd = false` 추가. `.sheet(isPresented: $showQuickAdd) { QuickAddSheet(mode: .appointment(selectedDate)) }` |

### 3.6 `ADHD/NotificationManager.swift` — ✅ 2026-07 범위 완료; F9·F14 계정 범위/반복 예약은 후속 교체

| 변경 | 내용 |
|---|---|
| [버그①] weak urgency 수정 | 127-135행 else(weak) 분기의 `content.userInfo`에서 `"urgency": Urgency.strong.rawValue` → `"urgency": Urgency.weak.rawValue`. **이 한 줄이 weak 알림의 풀스크린 오버레이 오발동(강/약 구분 무력화)의 원인** |
| [버그②] criticalAlert 제거 | 50행 `options: [.alert, .sound, .badge, .criticalAlert]` → `options: [.alert, .sound, .badge]` (criticalAlert는 Apple 특별 엔타이틀먼트 필요 — 미보유 상태 요청은 실패/심사 리스크) |
| [버그⑥] 하드코딩 L화 | 107행 `"⚠️ 긴급 확인이 필요합니다"` → `L.alarm.notifSubtitleStrong` / 109행 `"오늘의 한 걸음"` → `L.alarm.notifSubtitleWeak` / 61행 confirmAction title `"확인하기(지금 당장!)"` → `L.alarm.confirmAction`. 문자열 키는 §3.11 표에 정의. **참고**: 알림 콘텐츠는 스케줄 시점 언어로 고정됨(발화 시점 언어 아님) — §9.6에 알려진 제한으로 기록 |

### 3.7 `ADHD/AlarmManager.swift` — ✅ 2026-07 범위 완료; F9 로그아웃·계정 전환 정리는 후속 추가

| 변경 | 내용 |
|---|---|
| [F4][D14] Pro 게이팅 | 프로퍼티 추가: `private var isPremium: Bool { UserDefaults(suiteName: appGroupID)?.bool(forKey: SubscriptionManager.premiumFlagKey) ?? false }`. `willPresent`(31-60행) strong 분기: `if urgency == .strong && isPremium { 오버레이 세팅(현행) ; completionHandler([.sound]) } else { completionHandler([.banner, .sound]) }` — 즉 무료 사용자의 strong은 배너 폴백. `didReceive`(63-86행): `if urgency == .strong, isPremium, ...` 로 조건 추가 (무료는 오버레이 미표시, 앱만 열림) |

변경 전: urgency == .strong이면 무조건 오버레이. 변경 후: strong **AND** Pro일 때만 오버레이. 알림 자체(time-sensitive, 링톤)는 무료도 그대로 수신(D14).

### 3.8 `ADHD/AlarmOverlayView.swift` — ✅ 전체 완료 (1c031db)

| 변경 | 내용 |
|---|---|
| [버그⑥] 하드코딩 L화 | 81행 `"지금 바로 확인하고 완료하세요"` → `L.alarm.overlaySubtitle` / 97행 `"확인"` → `L.alarm.overlayConfirm` / 122행 `"탭하여 알람 끄기"` → `L.alarm.overlayHint` / 115-116행 accessibilityLabel·Hint의 한국어도 동일 키 조합으로 교체 |

### 3.9 `ADHD/SubscriptionManager.swift`

| 변경 | 내용 |
|---|---|
| [F4][D13] premium 플래그 공유 | `import WidgetKit` 추가. `static let premiumFlagKey = "isPremiumUser"` 추가. `refreshPremiumStatus()`(135-145행) 끝에: App Group(`UserDefaults(suiteName: appGroupID)`)에 `hasPremium` 기록, **이전 값과 다를 때만** `WidgetCenter.shared.reloadAllTimelines()` 호출 (매번 리로드 금지 — 위젯 예산 보호) |

F11~F12에서는 `dailyAIUsageCount`의 로컬 판정을 제거하고 서버 quota 응답을 표시용으로만 반영한다. 구매·복원에는 현재 Mora user id에서 생성한 `appAccountToken`을 사용하고, 서버가 검증한 entitlement만 `isPremiumUser` 캐시에 기록한다. 로그아웃·계정 전환·삭제 대기 시 캐시를 제거한다.

`appGroupID` 상수는 `ADHD/Shared/WidgetTaskSnapshot.swift:5`에 이미 정의되어 있고 앱 타깃에 포함되어 있으므로 그대로 사용.

### 3.10 `ADHD/PaywallView.swift`

| 변경 | 내용 |
|---|---|
| [버그⑥] alert L화 | 55-56행 `"구매 오류"` → `L.paywall.purchaseErrorTitle`, `"확인"` → `L.paywall.ok` |
| [F4][D8] 카피 일치화 | `Localization.swift`의 기존 키 값 수정(§3.11 표): `featureAlarmsDesc`·`featureWidgetsDesc`를 "Pro 전용" 사실과 일치하는 문구로 교체. `featureSync`(Cloud backup)는 "Coming soon" 유지(D1) |

### 3.11 `ADHD/Localization.swift`

**(a) 삭제**: `VoiceStrings.guideHint` (F2).

**(b) `LocalizationManager` 수정** [버그③ 연동]: `import WidgetKit` 추가. `currentLanguage`의 `didSet`(10-13행)에 추가 — App Group에도 복제 기록: `UserDefaults(suiteName: appGroupID)?.set(currentLanguage.rawValue, forKey: "appLanguage")` + `WidgetCenter.shared.reloadAllTimelines()`. `init`(15-18행) 끝에도 동일한 App Group 기록 1회 추가 (앱 업데이트 직후 위젯이 언어를 즉시 읽을 수 있도록 시딩).

**(c) 신규/수정 문자열 전체 표** — 새 네임스페이스 `alarm`, `onboarding`, `quickAdd`는 기존 `SettingsStrings` 패턴(언어 저장 struct + `t(en,ko,ja)` 함수)과 동일하게 구현하고 `Strings`에 `var alarm: AlarmStrings { ... }` 형태로 연결:

| 키 | en | ko | ja |
|---|---|---|---|
| `alarm.notifSubtitleStrong` | ⚠️ Needs your attention now | ⚠️ 긴급 확인이 필요합니다 | ⚠️ 今すぐ確認が必要です |
| `alarm.notifSubtitleWeak` | One small step today | 오늘의 한 걸음 | 今日の一歩 |
| `alarm.confirmAction` | Confirm (right now!) | 확인하기(지금 당장!) | 確認する(今すぐ!) |
| `alarm.overlaySubtitle` | Check it off right now | 지금 바로 확인하고 완료하세요 | 今すぐ確認して完了しましょう |
| `alarm.overlayConfirm` | Done | 확인 | 確認 |
| `alarm.overlayHint` | Tap to dismiss | 탭하여 알람 끄기 | タップしてアラームを消す |
| `voice.offTopicTitle` | Heads up | 알림 | お知らせ |
| `voice.askAgain` | Ask me differently | 다시 질문하기 | もう一度話す |
| `voice.undoUpdated(name)` | "{name}" updated | "{name}" 수정됨 | 「{name}」を更新 |
| `voice.postponeResult(count)` (count ≥ 1) | {count} task(s) postponed | {count}개 일정 연기됨 | {count}件延期しました |
| `voice.postponeNone` | No tasks to postpone | 연기할 일정이 없어요 | 延期する予定はありません |
| `paywall.purchaseErrorTitle` | Purchase Error | 구매 오류 | 購入エラー |
| `paywall.ok` | OK | 확인 | OK |
| `paywall.featureAlarmsDesc` (값 교체) | Pro-only full-screen alarms you can't miss. | 절대 놓칠 수 없는 풀스크린 알람 — Pro 전용. | 絶対に見逃せないフルスクリーンアラーム — Pro限定。 |
| `paywall.featureWidgetsDesc` (값 교체) | Pro-only widgets for your Home & Lock Screen. | 홈·잠금 화면 위젯 — Pro 전용. | ホーム・ロック画面ウィジェット — Pro限定。 |
| `onboarding.page1Title` | Just say it | 말하면 끝 | 話すだけ |
| `onboarding.page1Body` | One mic for every routine, task, and plan. | 마이크 하나로 루틴, 할 일, 일정까지 전부. | マイクひとつでルーティンも予定もすべて。 |
| `onboarding.page3Title` | You're all set | 준비 끝 | 準備完了 |
| `onboarding.page3Body` | Start with your first word. | 첫 마디로 시작해보세요. | 最初のひと言から始めましょう。 |
| `onboarding.start` | Start | 시작하기 | はじめる |
| `onboarding.next` | Next | 다음 | 次へ |
| `onboarding.skip` | Skip | 건너뛰기 | スキップ |
| `quickAdd.title` | Quick Add | 빠른 추가 | クイック追加 |
| `quickAdd.save` | Add | 추가 | 追加 |

(온보딩 2장 제목·예시는 기존 키 재사용: `voice.guideTitle`, `voice.exampleAdd`, `voice.exampleAppointment`, `voice.exampleDelete`)

### 3.12 `ADHD/VoiceInputManager.swift`

| 변경 | 내용 |
|---|---|
| [버그⑩][D6] 죽은 코드 삭제 | `cycleLanguage()`(137-145행), `setLocale(_:)`(147-154행), `enabledLocales` 프로퍼티+`enabledLocalesKey`(85-96행) 삭제. **유지**: `speechLocaleKey`와 init의 로케일 복원(100-101행), `SettingsView.swift:409-414`의 speechLocale 기록 — `syncLocaleWithAppLanguage()`가 첫 녹음 전 로케일을 올바르게 준비하도록 하는 워밍 경로이므로 건드리지 않음 |

### 3.13 `ADHD/TaskManager.swift`

| 변경 | 내용 |
|---|---|
| [버그⑤] `.updated` 언두 케이스 신설 | `UndoableAction.ActionType`(12-16행)에 케이스 추가: `case updated(AppTask, previous: (task: String, time: String?, date: Date?, category: String, recurrenceRule: String?, urgency: Urgency))` — `.deleted` 튜플(07-09에 urgency 추가됨)과 동일 형태. `undo()`(170-209행)에 처리 추가: 대상 AppTask가 `isDeleted == false`인 경우에만 이전 필드 전체 복원 → `NotificationManager.shared.cancelNotification(for:)` → `scheduleNotification(for:)` → `safeSave()`. `isDeleted == true`면 아무것도 하지 않고 다음 스택 메시지로 진행 (§9.5) |
| [버그⑤ 방어] toggled 언두 가드 | `undo()`의 `.toggled` 분기(196-199행)에도 `guard !task.isDeleted else { break }` 가드 추가 (삭제된 객체 필드 변경으로 인한 SwiftData 크래시 방지) |

### 3.14 `ADHD/Functions/TaskManager+LLM.swift`

| 변경 | 내용 |
|---|---|
| [버그⑤] updateTask 언두 교체 | 129행 `setUndoAction(.deleted([previousState]), message: "...(하드코딩 한국어)")` → `setUndoAction(.updated(matchingTask, previous: previousState), message: L.voice.undoUpdated(matchingTask.task))` — previousState 튜플에는 urgency가 이미 포함됨(07-09). 기존 방식은 언두 시 원본 재삽입으로 **수정본+원본 중복 생성** 버그 |
| [버그⑨][D23] postpone 반복 제외+피드백 | `postponeAllTasks`(187-217행): 이동 루프에 `guard task.recurrenceRule == nil else { continue }` 추가(반복 일정 제외). 209행 하드코딩 스낵바 → `postponedCount > 0 ? L.voice.postponeResult(postponedCount) : L.voice.postponeNone` — **0건일 때도** 스낵바 표시(사용자가 "왜 아무 일도 없지?" 하는 무응답 상태 제거) |

### 3.15 `ADHD/DesignSystem.swift`

| 변경 | 내용 |
|---|---|
| [버그⑩] Strings 삭제 | 61-64행 `struct Strings` 삭제 (§3.2에서 사용처를 `L.offlineText`로 교체 완료 후) |

### 3.16 `ADHD/ADHDWidget/WidgetDesignSystem.swift`

| 변경 | 내용 |
|---|---|
| [버그③] 위젯 언어 App Group화 | 169-171행 `WidgetL.currentLang`: `UserDefaults.standard.string(forKey: "appLanguage")` → `UserDefaults(suiteName: appGroupID)?.string(forKey: "appLanguage") ?? "en"`. 현재 코드는 위젯 프로세스의 standard defaults를 읽어 **항상 영어**로 표시되는 버그. §3.11(b)의 App Group 시딩과 한 쌍 |
| [F4] 잠금용 문자열 | `WidgetL`에 추가 — `proLocked`: "Widgets are a Pro feature" / "위젯은 Pro 기능이에요" / "ウィジェットはPro機能です", `proCTA`: "Tap to upgrade" / "탭해서 업그레이드" / "タップしてアップグレード" (기존 WidgetL 스위치 패턴 동일) |

### 3.17 위젯 4파일: `NextTaskWidget.swift` / `TodayRoutinesWidget.swift` / `DailyOverviewWidget.swift` / `LockScreenWidgets.swift`

| 변경 | 내용 |
|---|---|
| [F4][D13] 잠금 분기 | 각 어댑티브 뷰(`NextTaskWidgetView`, `TodayRoutinesWidgetView`, `DailyOverviewWidgetView`, 잠금화면 3개 뷰) body 최상단에: `if !WidgetDataStore.isPremium { WidgetLockedView(family: family) } else { 기존 내용 }`. 잠금화면 뷰는 family 파라미터 대신 각각 `.accessoryCircular`/`.accessoryRectangular`/`.accessoryInline` 리터럴 전달. `WidgetLockedView`는 신규 파일(§4.3) |

### 3.18 `ADHD/ADHDWidget/WidgetDataStore.swift` **및** `ADHD/Shared/WidgetDataStore.swift` (⚠️ 중복 파일 — 반드시 두 곳 동일 수정)

| 변경 | 내용 |
|---|---|
| [F4] isPremium 리더 | `static var isPremium: Bool { UserDefaults(suiteName: appGroupID)?.bool(forKey: "isPremiumUser") ?? false }` 추가 |

> **함정 경고**: `WidgetDataStore.swift`/`WidgetTaskSnapshot.swift`는 `ADHD/Shared/`와 `ADHD/ADHDWidget/`에 **동일 내용으로 물리적 복제**되어 있다. F9에서 양쪽 payload에 `accountScope`와 로그인 상태를 함께 추가하고, 키도 계정 범위로 바꾼다. 로그아웃·계정 전환 시 구 payload와 pending toggle을 지운 뒤 두 파일의 동일성을 검증한다.

### 3.19 `ADHD/Untitled.swift`

| 변경 | 내용 |
|---|---|
| [버그⑩] 삭제 | 파일 삭제 (주석 7줄뿐인 빈 파일). Xcode 프로젝트(`ADHD/ADHD.xcodeproj/project.pbxproj`)에서 참조 제거 필수 — Xcode에서 삭제하거나 pbxproj의 해당 PBXFileReference/PBXBuildFile 항목 제거 |

### 3.20 `supabase/functions/analyze-task/index.ts`

| 변경 | 내용 |
|---|---|
| [버그⑦] 에러 문구 정정 | 86행 `"Input too long. Maximum 2000 characters allowed."` → `"Input too long. Maximum 1000 characters allowed."` (실제 제한은 82행 `text.length > 1000`) |
| [F8][D23] postpone 규칙 추가 | 프롬프트의 `5. "postpone_all_tasks"` 블록(168-169행)에 Rules 1줄 추가: `- Rules: Only ONE-TIME appointments on from_date are moved. Recurring appointments (weekly/biweekly/monthly/yearly) are NEVER postponed by this function.` |
| [F11][SDD-4] 서버 quota | 인증 후 현재 Mora 계정 entitlement와 `Asia/Seoul` 날짜 quota를 서버에서 원자적으로 확인한다. 분석 성공 시에만 request id를 commit하고 실패 경로는 미차감한다. 인스턴스 메모리 rate limiter는 abuse 보조 수단으로만 유지 |
| [F15][SDD-9] 로그 정리 | 음성 원문, 일정·루틴명, Gemini raw response와 파싱 결과를 운영 로그에서 제거한다. 허용 로그는 request id, 상태 코드, 지연시간, 길이·개수 같은 비식별 메타데이터뿐 |

### 3.21 `ADHD/ADHD.xcodeproj/project.pbxproj`

| 변경 | 내용 |
|---|---|
| 파일 등록/해제 | `Untitled.swift` 참조 제거. 신규 파일 등록: `OnboardingView.swift`·`QuickAddSheet.swift`(앱 타깃), `WidgetLockedView.swift`(위젯 타깃), 테스트 5파일(`trident-KR.ADHDTests` 타깃 — 타깃은 pbxproj에 이미 존재하나 소스 0개이므로 `ADHDTests/` 폴더부터 생성) |

### 3.22 Security Phase 신규·교체 컴포넌트 [F9~F15]

| 컴포넌트 | 책임 |
|---|---|
| `AccountDataScope` | 현재 Mora 계정의 로컬 store/query/widget/notification namespace 제공 |
| `AuthStateMachine` | 부팅·온라인 인증·오프라인 제한 인증·로그아웃·삭제 대기·무효 세션 잠금 전이 |
| `LocalCleanupCoordinator` | 알림, AlarmKit, 위젯, 초안, Undo, 세션 캐시를 목적별로 정리. 로그아웃은 일정 본문 보존, 계정 삭제는 본문까지 제거 |
| `AccountDeletionCoordinator` + 서버 deletion job | 접수·로컬 삭제·재시도·완료 확인을 분리하고 오류를 UI에 노출 |
| 서버 quota/entitlement 저장소 | 무료 3회 성공 차감, Pro 계정 귀속, abuse 제한 |
| `VoiceDraftState` | 음성·텍스트 공용 비영속 편집 초안과 마이크 생명주기 |
| `RecurrenceEngine` | 최초 기준일에서 다음 실제 날짜 계산 및 알림 1회 재예약 |

---

## 4. 신규 파일 목록

### 4.1 `ADHD/OnboardingView.swift` [F1] — 앱 타깃

```swift
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasSeenVoiceOnboarding") private var hasSeenVoiceOnboarding = false
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var langManager = LocalizationManager.shared   // 언어 즉시 반영(기존 뷰 패턴)
    @State private var page = 0                                    // 0...2

    var body: some View { ... }                                    // §6.4 스펙대로
    private func complete()                                        // 완료: 두 플래그 모두 true (D21)
    private func skip()                                            // 스킵: hasCompletedOnboarding만 true (D21)
    private func skipIfExistingUser()                              // onAppear: fetchCount > 0 → complete() 즉시 호출 (D22)
}
```

- `skipIfExistingUser()`: `let count = (try? modelContext.fetchCount(FetchDescriptor<AppTask>())) ?? 0; if count > 0 { hasCompletedOnboarding = true }` — 기존 사용자는 온보딩 화면이 렌더되기 전에 빠져나감(플래그 변경 → MyApp 분기 재평가).
- 화면 스펙(레이아웃·토큰·전이)은 §6.4.

### 4.2 `ADHD/QuickAddSheet.swift` [F3] — 앱 타깃

```swift
enum QuickAddMode {
    case routine              // Routine 탭 · Daily Routines 섹션에서 진입
    case todayTask            // Routine 탭 · Today's Tasks 섹션에서 진입
    case appointment(Date)    // Planner 탭에서 진입 (연관값 = 현재 선택 날짜)
}

struct QuickAddSheet: View {
    let mode: QuickAddMode
    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var time = ""                 // "" = 시간 미정 (기존 규약: AppTask.time nil)
    @State private var urgency: Urgency = .strong
    @State private var showTimePicker = false
    @FocusState private var isNameFocused: Bool

    var body: some View { ... }                  // §6.5 스펙대로
    private func save()
}
```

`save()` 로직 (AI 완전 미경유 — `SubscriptionManager` 접근 자체가 없음):

```swift
let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmed.isEmpty else { return }           // 버튼 disabled로 선차단, 이중 방어
let (category, date): (String, Date?)
switch mode {
case .routine:              (category, date) = ("Routine", nil)          // 매일 반복 규약 (AppTask.occursOn)
case .todayTask:            (category, date) = ("Appointment", Date())   // 오늘 할 일 = 오늘 날짜 Appointment (LLM 규약과 동일)
case .appointment(let d):   (category, date) = ("Appointment", d)
}
let task = AppTask(task: trimmed, time: time.isEmpty ? nil : time,
                   date: date, category: category, urgency: urgency)
taskManager.insertBatch(task)
NotificationManager.shared.scheduleNotification(for: task)
taskManager.setUndoAction(.added([task]), message: L.voice.undoAdded(1))
taskManager.safeSave()                            // insertBatch는 save하지 않으므로 필수
Haptic.notification(.success)
dismiss()
```

- 시간 선택은 기존 `TimePickerModal`(`RoutineView.swift:523-571`, 동일 모듈 internal) 재사용 — 출력 포맷 `"hh:mm a"`(en_US_POSIX)로 기존 데이터와 완전 동일.
- urgency 토글은 `RoutineView.swift:257-273`(bolt 칩) 시각 패턴 재사용.

### 4.3 `ADHD/ADHDWidget/WidgetLockedView.swift` [F4] — 위젯 타깃

```swift
struct WidgetLockedView: View {
    let family: WidgetFamily
    var body: some View { ... }
}
```

레이아웃 (전 상태 `widgetURL(URL(string: "mora://paywall"))` + `containerBackground(WDS.Colors.background)` — 잠금화면 계열은 `Color.clear` 배경):

| family | 구성 |
|---|---|
| `.systemSmall` | VStack(spacing 8): `lock.fill` 22pt `WDS.Colors.primary` → "Mora Pro" `WDS.Typography.titleSm` onSurfaceVariant → `WidgetL.proCTA` caption onSurfaceVariant 50% |
| `.systemMedium` / `.systemLarge` | HStack(spacing 12): `lock.fill` 28pt primary + VStack(leading, 4): "Mora Pro" titleSm / `WidgetL.proLocked` bodyMd onSurfaceVariant 70% / `WidgetL.proCTA` caption primary 80% |
| `.accessoryCircular` | ZStack: `Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)` + `lock.fill` 16pt |
| `.accessoryRectangular` | VStack(leading, 2): HStack: `lock.fill` 10pt + "Mora Pro" 12pt bold / `WidgetL.proCTA` 10pt secondary |
| `.accessoryInline` | `Label("Mora Pro", systemImage: "lock.fill")` |

### 4.4 테스트 5파일 [F7] — `ADHDTests/` 폴더 신규 생성, `trident-KR.ADHDTests` 타깃. 프레임워크: **Swift Testing** (`import Testing`, `@Test`/`#expect`)

| 파일 | 검증 대상 | 필수 케이스 |
|---|---|---|
| `ADHDTests/AppTaskOccursOnTests.swift` | `AppTask.occursOn(_:)` (`AppTask.swift:91-135`) | Routine(date nil)→모든 날짜 true / Routine(date 지정)→해당 일만 / Appointment 일회성 당일만 / weekly 같은 요일 +7·+14일 true, +1일 false / biweekly +14 true·+7 false / monthly 31일 시작→2월은 말일(28/29) 발생 / yearly 동월동일 / 시작일 이전 날짜 false |
| `ADHDTests/SortableTimeTests.swift` | `AppTask.sortableTime` (`AppTask.swift:66-86`) | "02:00 PM"→"14:00" / "9:05 AM"→"09:05" / "14:00"→"14:00" / nil·""→"99:99" / 파싱 불가 문자열→원본 그대로 / 정렬: 09:00 AM < 02:00 PM < 시간없음 |
| `ADHDTests/DailyResetTests.swift` | `TaskManager.checkAndResetDailyTasks()` (`TaskManager.swift:78-120`) | in-memory `ModelContainer` 사용. 같은 날 재호출 no-op / 다음 날: 어제 ISO 요일 인덱스에 완료 기록 + isCompleted 리셋 / 일→월 주 경계: weeklyCompletions 전체 초기화. **테스트 가능화 리팩터링 허용**: 시그니처를 `checkAndResetDailyTasks(now: Date = Date(), defaults: UserDefaults = .standard)`로 변경(기존 호출부 2곳 — `MyApp.swift:120`, `TaskManager.configure` — 무인자 호출 그대로 유효) |
| `ADHDTests/LLMFunctionCallDecodingTests.swift` | `LLMFunctionCall.init(from:)` (`LLMFunctionCall.swift:89-131`) | 함수 8종 각각의 JSON 디코딩 / category 정규화("appointment"→"Appointment", "routine"·기타→"Routine") / 미지 함수명→`.unknown` / `updateFields`에서 Routine 전환 시 date nil 강제 |
| `ADHDTests/DeleteByNameBatchTests.swift` | `TaskManager.deleteByNameBatch` (`TaskManager.swift:269-320`) | in-memory 컨테이너. 정확 매칭 우선(부분 매칭보다) / 1글자 검색어 무시(0건) / category 필터 / dateString 필터(같은 날만) / "all" 카테고리·날짜 통과 |

---

## 5. 데이터 모델 / Supabase 스키마

### 5.1 SwiftData `AppTask` — 기존 필드 유지 + 계정별 물리 저장소 (`ADHD/AppTask.swift`)

| 필드 | 타입 | 의미 / 규약 |
|---|---|---|
| `id` | `UUID` | 계정 내부 PK. 알림·위젯 외부 식별자는 반드시 `accountScope + id`로 구성해 계정 간 충돌을 막음 |
| `task` | `String` | 제목 |
| `time` | `String?` | `"hh:mm a"`(en_US_POSIX) 우선, `"h:mm a"`/`"HH:mm"`도 파서 허용. nil = 시간 미정(알림 없음) |
| `date` | `Date?` | Routine은 nil(=매일). Appointment는 발생일(반복이면 시작일) |
| `category` | `String` | `"Routine"` 또는 `"Appointment"` 두 값만 (D2) |
| `isCompleted` | `Bool` | 오늘의 완료 상태. Routine은 매일 자정 경과 후 첫 활성화 때 리셋 |
| `recurrenceRule` | `String?` | `"weekly"`\|`"biweekly"`\|`"monthly"`\|`"yearly"`\|nil. Routine은 항상 nil(암묵적 매일) |
| `urgencyRaw` | `String` | `"strong"`(기본)\|`"weak"` — computed `urgency: Urgency` |
| `sortOrder` | `Int` | 0=미지정. 리오더 커밋 시 `(index+1)*10` |
| `weeklyCompletions` | `[Bool]` (7) | ISO: 0=월…6=일. 일일 리셋 때 어제 인덱스 기록, 주 경계에 초기화 |

파생 규약: `isRecurring == (recurrenceRule != nil)`, `occursOn(_:)`이 탭 필터·위젯 스냅샷·clearAllTasks의 반복 판정 진리원이다. 모든 조회와 부수효과에는 반복 판정보다 먼저 현재 `accountScope`를 적용한다.

INT-01~03에 따라 Mora 계정별 별도 `ModelContainer`/store 파일을 확정했다. user id 원문 대신 SHA-256 namespace를 경로에 사용한다. 현재 생산 사용자가 없으므로 기존 `default.store` 테스트 데이터는 한 번만 명시적으로 제거하고 marker를 기록하며 import하지 않는다. marker 이후에는 자동 삭제를 다시 수행하지 않는다.

### 5.2 Supabase 일정 동기화 스키마 DDL 초안 [F6 — 문서 전용] (D1)

향후 클라우드 백업/동기화 착수 시 사용할 초안. `supabase/migrations/`에 넣지 말 것(이번 범위 아님).

```sql
-- tasks: AppTask 1:1 매핑 + 소유자/동기화 메타
create table public.tasks (
  id uuid primary key,                          -- AppTask.id 그대로 (클라이언트 생성)
  user_id uuid not null references auth.users(id) on delete cascade,
  task text not null,
  time text,                                    -- "hh:mm a" 문자열 규약 유지
  date date,
  category text not null check (category in ('Routine','Appointment')),
  is_completed boolean not null default false,
  recurrence_rule text check (recurrence_rule in ('weekly','biweekly','monthly','yearly')),
  urgency text not null default 'strong' check (urgency in ('weak','strong')),
  sort_order integer not null default 0,
  weekly_completions boolean[] not null default '{false,false,false,false,false,false,false}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz                        -- soft delete (동기화 전파용)
);

alter table public.tasks enable row level security;
create policy "own tasks" on public.tasks
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create index tasks_user_date_idx on public.tasks (user_id, date);
```

동기화 전략(향후): 로컬 소스 오브 트루스 + 주기 업로드(단방향 백업부터) → 충돌은 `updated_at` LWW(Last-Write-Wins) → 삭제는 `deleted_at` soft delete 전파. 멀티 디바이스 실시간(realtime)은 그 다음 단계.

### 5.3 보안 운영 스키마 [F10~F12 — 이번에 구현]

일정 본문의 클라우드 동기화와 별개로 다음 서버 상태는 필수다.

| 영역 | 최소 저장 정보 | 필수 규칙 |
|---|---|---|
| 계정 삭제 작업 | job id, user id, 상태, 재시도 횟수, 접수·완료 시각, 실패 코드 | 멱등성 보장, 중복 요청은 동일 진행 상태 반환, Auth 사용자는 마지막 단계에서 삭제 |
| AI quota 원장 | user id, 서버가 계산한 `Asia/Seoul` 날짜, 성공 사용량, request id | `(user_id, usage_date, request_id)` 중복 차감 방지, 무료 3회 원자적 검사·기록 |
| Entitlement | user id, product id, 상태, 검증 시각 | 클라이언트 `isPremium`을 권한 원천으로 사용하지 않음 |
| StoreKit 연결 | Mora user id, `appAccountToken`, transaction 식별자, 환경 | 하나의 구매를 다른 Mora 계정에 자동 공유하지 않음, 삭제·복원 상태 추적 |

테이블명과 세부 DDL은 구현 PR에서 확정하되, 위 불변조건을 약화해서는 안 된다.

---

## 6. 화면별 상세 스펙

> 디자인 토큰 참조 (전부 `DesignSystem.swift` 정의 — 신규 색상 추가 금지, 유일한 예외는 §3.2 UndoSnackbar 웜 톤):
> `background`(#F9F9F7/#1A1A1A) · `primary`(#934A2E/#FFB59B) · `primaryContainer`(#D27C5C/#7C3F24) · `primaryFixedDim`(#FFB59B 고정) · `tertiary`(#006A63/#4FDBD1) · `onSurfaceVariant`(#54433D/#CFC0B8) · `surfaceContainerLow`(#F4F4F2/#252525) · `Gradients.primaryCTA`(primary→primaryContainer, topLeading→bottomTrailing)
> 타이포: `displayLg`=title.semibold · `titleSm`=title3.medium · `bodyMd`=body · `labelSm`=caption.medium (D15: 시스템 폰트 확정)

### 6.1 Home (Voice) — 상태 머신

컴포넌트 트리 (변경 후):

```
HomeVoiceInterfaceView
├─ 상단 바: [키보드/마이크 토글] [? 가이드 버튼 ←F2 신규] Spacer [AI 카운터(무료만)] [설정 gear]
├─ 편집 가능한 공용 입력 초안(TextField) + 추가/분석 버튼
├─ (음성 모드)
│  ├─ Voice Pulse 원(180pt) + 진행 링(140pt) + 마이크 버튼(120pt)
│  ├─ 녹음 타이머 + 침묵 카운트다운
│  └─ 상태 텍스트 / 성공 체크 / 실시간 STT 텍스트+커서
├─ VoiceConfirmationSheet (zIndex 20, 배경 dim)
├─ 에러 토스트 (하단)
└─ 시트: Settings / Paywall / VoiceGuideSheet
```

상태 전이표 (S0~S6 — 기존 구현 수치를 공식 스펙으로 채택):

| 상태 | 진입 트리거 | UI (토큰·수치) | 이탈 |
|---|---|---|---|
| **S0 IDLE** | 초기 / 완료·취소 후 | Pulse: `primaryFixedDim`, scale 0.92↔1.08, opacity 0.15↔0.4, `easeInOut(2.0).repeatForever` 호흡. 마이크 버튼: `Gradients.primaryCTA` 120pt + `mic.fill` 40pt 白. 안내문 `L.voicePlaceholder`(titleSm, primary). reduceMotion 시 scale 1.0/opacity 0.3 고정 | 마이크 탭(→S1), 키보드 토글(→T), ?·설정·페이월 시트 |
| **S1 LISTENING** | 마이크 탭(tap 모드) / press(hold 모드). AI quota와 서버 연결은 아직 검사하지 않고 음성 인식 가능 여부만 확인 | Pulse: scale `1.0 + audioPower×0.5`, opacity 0.6. 진행 링·타이머·실시간 STT는 기존 시각 규칙 유지 | 탭/릴리즈(→S2), 침묵 종료(→S2), 30초 도달(→S2), STT 오류(→S6) |
| **S2 DRAFT_EDITING** | `stopListening()` 또는 STT 최종 결과 | 인식 문장을 공용 입력 초안에 표시하고 키보드로 직접 수정 가능. 이 시점에는 AI를 호출하거나 사용량을 차감하지 않음 | 추가/분석 버튼(→S3), 다시 녹음(초안 교체 전 확인 또는 명시 규칙), 텍스트 모드 전환(상태 유지) |
| **S3 ANALYZING** | 사용자가 편집한 초안에서 추가/분석을 명시적으로 실행 | 서버 quota 사전 승인 후 "Analyzing..." 표시. 성공 응답이 검증된 때 서버가 1회 기록 | 성공(→S4 또는 안전한 명령이며 `confirmBeforeSave=false`면 →S5), 실패(→S6, 초안 유지) |
| **S4 CONFIRM** | 파싱 결과 수신, `confirmBeforeSave==true`(기본) | `VoiceConfirmationSheet`: maxWidth 340, `glassStyle(cornerRadius: 32)`, primary 15% glow(40pt blur, y15). 배경 `.ultraThinMaterial.opacity(0.8)` — 탭하면 취소. 태스크 카드(cornerRadius 24) 탭 → 인라인 편집(세그먼트 카테고리+이름+DatePicker). 긴급도 bolt 칩 토글. 진입/이탈 spring(0.4, 0.7) + bottom move + scale 0.95 | 확인(→검증→S5 또는 필드 누락 시 편집 강제+S6 토스트), 취소/배경 탭(→S0) |
| **S5 SUCCESS** | `taskManager.execute` 완료 | `checkmark.circle.fill` 48pt `tertiary`, scale+opacity 전이, `Haptic.notification(.success)`, 1.5초 후 자동 → S0. **탭 전환 없음(Home 유지)** | 자동 |
| **S6 ERROR** | VoiceError / API 실패 / 확인 검증 실패 | 기존 오류 피드백을 표시하되 편집 초안은 지우지 않음. "다시 시도"는 동일 초안을 다시 분석하며 새 요청으로 계산 | 초안 편집(→S2), 재시도(→S3), 다시 녹음(→S1) |
| **T TEXT_MODE** | 키보드 토글 | S2와 동일한 공용 초안을 편집. 마이크로 돌아가거나 탭을 이동해도 초안은 유지 | 추가/분석(→S3), 마이크 토글(초안 유지) |

OOV(off-topic) 분기: S4의 특수형 — 배지·시간행 없이 메시지만, 타이틀 `L.voice.offTopicTitle`, 버튼 `L.voice.askAgain`(탭=닫기). 분석 실패와 달리 정상 분석 응답이므로 무료 사용량 1회에 포함한다.

마이크는 텍스트 모드 전환, 다른 탭 이동, 앱 백그라운드 진입 시 즉시 중지한다. 이때까지 인식된 문자열은 공용 초안에 남기고, 로그아웃·계정 삭제 시에만 초안을 제거한다. 초안은 자동 영속 저장하지 않는다.

가이드 시트(F2): `.presentationDetents([.medium])` + 드래그 인디케이터(현행 359-364행 유지). 자동 표시 조건은 §3.3.

### 6.2 Routine 탭 (변경: + 버튼 1개 추가 외 현행 유지)

```
RoutineView
├─ 헤더: "Routine"(displayLg, primary, tracking -0.5) … Spacer … [+ ←F3 신규] [돋보기]
├─ 섹션 필: [Daily Routines] [Today's Tasks] … Spacer … [리오더 토글]
├─ 리스트 (spacing 32, LazyVStack): 미완료 → 완료 순
│   └─ TaskRow: [체크박스 32pt 원] [아이콘+제목 bodyMd] [시간 labelSm 50%·bolt urgency]
│       └─ (Routine만) WeeklyBar: M~S 26pt 원, 지난 요일 탭 토글, 오늘 primary 테두리
├─ 빈 상태: mic.fill 48pt primary 50% + 안내문 → 탭하면 Voice 탭 이동
└─ 시트: SearchView / QuickAddSheet(F3)
```

상태: `normal`(체크박스 탭=완료 토글·행 탭=인라인 편집) / `editing`(다른 행 opacity 0.3) / `reordering`(SmoothTaskReorderList, 고스트 scale 1.05) / `empty`. 전부 현행 유지.

### 6.3 Planner 탭 (변경: + 버튼 1개 추가 외 현행 유지)

```
PlannerView
├─ 헤더: "Planner"(displayLg) … [+ ←F3 신규] [리오더] [돋보기] [캘린더]
├─ 주간 셀렉터: [오늘 56×68 고정 pill] | 구분선 | [선택일 ±7일 가로 스크롤 50×64] + 이벤트 도트
├─ EventCard 리스트 (spacing 32): primary 5% 배경, radius 18, 스와이프 삭제
├─ 캘린더 시트: 월간 그래픽 DatePicker (D11 예외 — 점프 도구) + "오늘" 버튼
└─ 시트: SearchView(날짜 점프 콜백) / QuickAddSheet(F3, selectedDate 전달)
```

D24: 주간 셀렉터의 "오늘 고정 + 선택일 ±7일(15일 윈도우)"을 공식 스펙으로 채택 (README의 "오늘+6일"은 §13.2에서 문서 수정 대상으로 기록).

### 6.4 온보딩 (신규, F1) — 상세 스펙

구조: `ZStack { background } → VStack { 상단 Skip 바 / TabView(.page) 3장 / 하단 컨트롤 }`

| 요소 | 스펙 |
|---|---|
| 배경 | `DesignSystem.Colors.background` 전면 |
| Skip | 상단 우측, `L.onboarding.skip`, `labelSm`, `onSurfaceVariant` 60%, 44pt 히트 영역. 1·2장에서만 노출(3장은 CTA가 종착) |
| 1장 | `mic.circle.fill` 64pt `primary` → `L.onboarding.page1Title` `displayLg` `primary` tracking -0.5 → `L.onboarding.page1Body` `bodyMd` `onSurfaceVariant`, 중앙 정렬, 좌우 패딩 32 |
| 2장 | `L.voice.guideTitle`(titleSm) + 예시 3행 — `VoiceGuideSheet`(HomeVoiceInterfaceView.swift:994-1035)의 행 스타일 그대로 재사용: 아이콘(tertiary/primary/red 70%) + 문구, `surfaceContainerLow` 배경 radius 14 |
| 3장 | `checkmark.seal.fill` 56pt `tertiary` → `L.onboarding.page3Title` → `L.onboarding.page3Body` → CTA `L.onboarding.start` = `SatisfyingButtonStyle(color: primary)` 전폭(패딩 32) |
| 페이지 컨트롤 | 커스텀 도트 3개: 현재 `primary` 8pt, 나머지 `onSurfaceVariant` 20% 6pt (기본 UIPageControl의 중성 회색 회피 — 금기 #1) |
| 하단 보조 버튼 | 1·2장: `L.onboarding.next` 텍스트 버튼(titleSm, primary — DESIGN.md Secondary 버튼 규칙: 배경·테두리 없음). 탭 시 `withAnimation(.easeInOut(0.3)) { page += 1 }` |
| 전이 | 페이지 스와이프 허용. 모든 상태 변화 300ms 이상 + reduceMotion 시 애니메이션 제거 |
| 완료/스킵 | §4.1의 `complete()`/`skip()` — 플래그 변경으로 MyApp 분기가 MainTabView로 자연 전환. 별도 dismiss 불필요 |
| 접근성 | 각 장 `accessibilityElement(children: .combine)` + 페이지 위치 힌트("Page 1 of 3"), Skip·Next·Start 전부 라벨 |
| 금기 준수 | 장당 실행 가능 액션 ≤ 2(Skip+Next / Start), 텍스트 2줄 이하 + 아이콘 앵커, 구분선 없음 |

### 6.5 QuickAddSheet (신규, F3) — 상세 스펙

`presentationDetents([.height(360)])` + `.presentationDragIndicator(.visible)`.

```
VStack(spacing: 20, 패딩 H24/T28/B24) — 배경 DesignSystem.Colors.background
├─ 타이틀 행: L.quickAdd.title (title3.bold, onSurfaceVariant) … Spacer … xmark.circle.fill(44pt 히트) = 취소
├─ 이름 입력: TextField(L.voice.fieldName) — surfaceContainerLow 배경, radius 14, 패딩 H16/V14,
│   자동 포커스(onAppear 0.3s 후), submitLabel(.done) → save()
├─ 칩 행 (HStack spacing 8):
│   ├─ 시간 칩: time.isEmpty ? "Set Time"(L.voice.fieldTime) : time — labelSm, onSurfaceVariant 10% 배경
│   │   radius 6 → 탭 시 TimePickerModal 시트 (기존 컴포넌트 재사용)
│   └─ urgency 칩: bolt.fill/bolt + L.voice.urgencyStrong/Weak — orange/gray 토글 (TaskRow 편집 모드와 동일)
├─ (mode == .appointment) 날짜 라벨 행: calendar 아이콘 + 선택 날짜(medium dateStyle) — 표시 전용, labelSm 60%
│   (날짜 변경은 Planner 주간 셀렉터에서 — 시트 안에서 날짜 편집 금지: 정보 밀도 금기)
└─ 저장 버튼: L.quickAdd.save — SatisfyingButtonStyle(primary), 전폭.
    disabled = 이름 trim 빈 값 (opacity 0.5)
```

- 실행 가능 액션: 이름/시간/긴급도/저장 = 시트 내 3개 초과 아님(입력 필드 1 + 칩 2 + CTA 1 — CTA 단일, 금기 #3의 "실행 액션"은 CTA 기준 1개).
- 저장 성공 시 `Haptic.notification(.success)` + dismiss + 언두 스낵바 노출(§4.2 save 로직).
- VoiceOver: 시간 칩 "Set time, button", urgency 칩 "Strong alert, toggle" 라벨.

### 6.6 핵심 컴포넌트 5종 — 확정 스펙 (스펙 §7 "코드 확인 필요" 항목의 답, D24)

| 컴포넌트 | 확정 스펙 (코드 현행 채택) | 출처 |
|---|---|---|
| **Voice Pulse** | 180pt 원, `primaryFixedDim`. idle: 2.0s easeInOut 무한 호흡 scale 0.92↔1.08·opacity 0.15↔0.4 / listening: scale 1.0+audioPower×0.5(easeOut 0.1s)·opacity 0.6 / reduceMotion: 정지(opacity 0.3). 진행 링: 140pt·3pt·primary 60% | `HomeVoiceInterfaceView.swift:154-188` |
| **버튼 시스템** | Primary CTA: `SatisfyingButtonStyle` — 캡슐, 색 30% 그림자(radius 12→4/y 6→2 press), scale 0.94, spring(0.3, 0.6) / Squishy: scale 0.93, easeOut 0.2 / Secondary: 텍스트만(primary), 배경·테두리 없음 / 최소 히트 44pt | `DesignSystem.swift:73-112` |
| **카드 & 리스트** | 카드 radius 18~24pt(확정 — DESIGN.md의 48px은 채택하지 않음), 배경 `surfaceContainerLow` 또는 primary 5%, 행 간격 32pt, 구분선 없음 | `PlannerView.swift:534-536`, `RoutineView.swift:165` |
| **Glass Effect** | `glassStyle(cornerRadius:)`: ultraThinMaterial + 白 반사 그라디언트(0.2→0.05) + 白 스트로크 그라디언트 1pt(글래스 하이라이트 — 섹션 구분선이 아니므로 금기 #2 비저촉) + black 15% 그림자(30pt/y15). 확인 카드는 추가로 primary 15% glow | `DesignSystem.swift:115-155` |
| **햅틱** | `Haptic` 래퍼(설정 `hapticEnabled` 존중): 마이크 탭 medium / 완료 토글 medium / 편집 진입 medium·저장 light / 리오더 시작 medium·이동 soft·종료 light / 성공 success / 오류 error / 경고 warning. **신규 UI도 이 매핑을 따를 것** (QuickAdd 저장=success, 온보딩 CTA=medium) | `DesignSystem.swift:194-210` + 각 호출부 |

---

## 7. 음성 파싱 파이프라인 상세

### 7.1 전체 시퀀스 (현행 확정 + F8 보강)

```
[사용자 발화]
  → VoiceInputManager (SFSpeechRecognizer, 로케일 = 앱 언어 D6)
     · 부분 결과 실시간 표시, 침묵 2s→3s 카운트다운 자동 종료, 최대 30s
  → onSpeechFinalized(text)
     · text 공백뿐 → VoiceError.emptyTranscription → S6 (LLM 호출 없음, 사용량 미차감)
     · 인식 문장을 편집 가능한 공용 초안에 복사하고 S2에서 대기
  → 사용자가 초안을 수정한 뒤 추가/분석 버튼을 명시적으로 탭
     · 오프라인/무효 세션 → 서버 호출 없이 초안 유지
     · request id를 생성하고 서버 quota endpoint에 함께 전달
  → CloudLLMManager.analyzeText(text)
     · payload = { text, currentTime: "yyyy-MM-dd HH:mm", language: "en"|"ko"|"ja", requestId }
     · supabase.functions.invoke("analyze-task") — JWT Authorization 헤더
     · 자동 전송 재시도는 같은 request id 유지. 사용자가 실패 후 다시 누르면 새 request id
  → Edge Function (supabase/functions/analyze-task/index.ts)
     · JWT 검증 → 서버 entitlement 확인 → 무료 계정은 Asia/Seoul 날짜 quota 3회 원자적 검사
     · abuse limiter / 1000자 초과 방어 유지
     · Gemini 2.0 Flash, temperature 0.1, response_mime_type: application/json
     · 방어 정규화: 단일 객체→배열 래핑, function_name 누락→add_single_task,
       category 검증 실패→"Appointment", date 형식 오류→null, recurrence 화이트리스트
     · 검증 가능한 분석 성공 응답에만 quota 1회 commit; 네트워크·서버·분석 실패는 미차감
  → [LLMFunctionCall] 디코딩 (Swift, category 대소문자 정규화)
  → 삭제·전체 삭제·대량 변경 포함 ? 항상 전체 명령 묶음 확인 : confirmBeforeSave 적용
  → TaskManager.execute(pendingCalls:) — 함수 라우터 → SwiftData 저장(safeSave 1회)
  → 부수효과: NotificationManager 스케줄/취소 · 위젯 스냅샷 재기록(0.5s 디바운스) · 언두 스택 push
```

### 7.2 의도 분류 규약 (프롬프트 현행 — 변경 없음, D2)

- **Appointment**: 특정 날짜·시간이 있는 일회성(오늘 포함). "오늘 10시 영양제"도 Appointment.
- **Routine**: 반복 습관·비특정 다짐만 ("매일 아침 스트레칭", "물 많이 마시기").
- 시간 미언급 → `time: null` 강제 (기본값 추측 금지).
- 상대 시간("1시간 후")은 주입된 `currentTime` 기준으로 LLM이 직접 계산, `"hh:mm AM/PM"` 출력.
- OOD(앱 목적 무관 발화) → `handle_off_topic_chat` 최우선 (인사/날씨/농담/하소연/횡설수설 전부). `request_clarification`은 "태스크 관련이지만 치명적으로 모호"할 때만.

### 7.3 함수 8종 파라미터 표 (현행 확정)

| function_name | parameters | 클라이언트 실행 (TaskManager+LLM.swift) |
|---|---|---|
| `add_single_task` | task_name, time?, date?, category, recurrence? | AppTask 생성+알림 스케줄+언두(.added). Routine이면 date nil 강제 |
| `update_task` | target_task_name, new_* 5종 | findBestMatch(정확>부분 2자+) → 필드 선택 갱신, 알림 재설정, 언두(**F5⑤: .updated로 교체**) |
| `delete_specific_task` | target_task_name, target_category?, target_date? | deleteByNameBatch(정확>포함, 1자 무시) + 언두(.deleted) |
| `clear_all_tasks` | target_category?, target_date | occursOn 매칭 일괄 삭제. 날짜 지정+카테고리 미지정이면 Appointment로 한정(루틴 보호) |
| `postpone_all_tasks` | from_date, to_date | **F5⑨: 일회성만** 이동+알림 재설정, 0건 포함 스낵바 피드백 |
| `mark_task_complete` | target_task_name | findBestMatch → isCompleted=true + 언두(.toggled) |
| `request_clarification` | reason | 스낵바에 "🤔 {reason}" 5초 |
| `handle_off_topic_chat` | message | NotificationCenter → OOV 확인 카드 (§6.1) |

확인 정책: `delete_specific_task`, `clear_all_tasks`, 다수 항목을 바꾸는 `postpone_all_tasks` 및 결과 집합이 여러 개인 수정은 `confirmBeforeSave=false`여도 실행하지 않는다. 확인 화면에는 대상, 날짜, 작업 종류, 삭제·변경 개수를 표시한다. 하나의 LLM 응답에 안전한 추가와 파괴적 작업이 섞이면 전체 묶음을 확인해 사용자가 승인한 스냅샷만 실행한다.

### 7.4 폴백 의사코드 (전 계층)

```
STT 계층:
  권한 거부            → VoiceError.permissionDenied → 토스트 "마이크 권한이 필요합니다"
  인식기 unavailable   → .recognitionFailed → 토스트
  결과 빈 문자열       → .emptyTranscription → 토스트 (LLM 미호출·미차감)

네트워크 계층 (CloudLLMManager):
  오프라인             → STT 초안은 유지, 추가/분석 버튼에서 오프라인 안내; 서버 호출·차감 없음
  타임아웃/5xx/디코딩  → 같은 request id로 제한 재시도 → 최종 실패 시 초안 유지·미차감
  401                  → Auth 상태를 무효 세션 잠금으로 전환, 위젯·알림·로컬 노출 정리, 초안은 로그인 화면에 노출하지 않음
  429 quota 소진       → 무료 한도 안내/페이월. abuse 제한 429는 잠시 후 재시도 안내로 구분

LLM 응답 계층 (Edge Function 방어 정규화가 1차 흡수):
  파싱 불가 JSON       → 실패 응답, quota 미차감, 초안 유지
  unknown function     → 실행 금지, quota 미차감, 초안 유지 + 사용자용 오류

확인 카드 검증 (confirmPendingTasks):
  Routine에 time 없음              → 해당 카드 편집 모드 강제 + errorMissingTime 토스트
  Appointment에 date 또는 time 없음 → 편집 강제 + errorMissingDate/errorMissingAppointmentTime
```

---

## 8. 위젯 / 알림 상세 스펙

### 8.1 위젯 6종 × 잠금/해제 상태 (F4, D13)

데이터 흐름: 현재 `accountScope`로 필터한 `TaskManager.writeWidgetSnapshot()` → App Group의 계정 범위 payload → Provider가 active account와 로그인 상태가 일치할 때만 읽기 → 타임라인 갱신. 로그아웃·계정 전환·세션 무효·삭제 대기 진입 시 payload와 pending toggle을 먼저 제거하고 `reloadAllTimelines()`를 호출한다. **Premium 흐름**: 서버에서 검증된 현재 Mora 계정 entitlement → App Group 표시 캐시 `isPremiumUser`; 이 값은 위젯 렌더링용이며 서버 권한을 대체하지 않는다.

| 위젯 (kind) | family | Pro(해제) 상태 — 현행 유지 | Free(잠금) 상태 — 신규 |
|---|---|---|---|
| NextTaskWidget | S / M | S: 다음 미완료 1건+시간+완료 토글(AppIntent) / M: 최대 3건 리스트+"+N more" | `WidgetLockedView(family:)` §4.3 표 |
| TodayRoutinesWidget | S / M | S: 진행률 링 58pt+카운트 / M: 헤더 진행률+루틴 4건 토글 | 〃 |
| DailyOverviewWidget | L | 날짜 헤더+진행률 배지+루틴 5~8건+일정 4~8건(동적 배분) | 〃 |
| RoutineProgressWidget | accessoryCircular | Gauge(accessoryCircularCapacity) N/M | 〃 (자물쇠 링) |
| NextTaskLockWidget | accessoryRectangular | "UP NEXT"+태스크명+"+N more" | 〃 ("🔒 Mora Pro") |
| TaskCountInlineWidget | accessoryInline | "N left" / "All Done!" | 〃 (Label "Mora Pro") |

딥링크 최종 명세: `mora://tab/voice`·`mora://tab/routine`·`mora://tab/planner`(현행) + **`mora://paywall`(신규, 잠금 상태 전용)**. AppIntent 경유 딥링크(`OpenRoutineIntent` 등)는 현행 유지.

잠금 상태 규칙: 잠금 시 인터랙티브 토글 버튼을 제거한다. 로그인 상태·active account·payload account가 하나라도 불일치하거나 키가 없으면 일정 내용을 표시하지 않는 fail-closed 상태가 우선한다. 그 다음 현재 계정의 검증된 Pro 캐시가 false이면 잠금 뷰를 표시한다.

### 8.2 알림 매트릭스 (F4·F5① 적용 후 최종 명세)

스케줄: identifier는 `accountScope + task.id + suffix`로 구성한다. 매일 루틴과 단순 weekly만 검증된 반복 trigger를 사용할 수 있고, biweekly·monthly·yearly는 최초 기준일에서 실제 다음 발생 날짜를 계산해 1회성 trigger로 등록한다. 격주는 정확히 14일, 존재하지 않는 월간 일자는 해당 월 마지막 날이며 늦은 완료가 기준일을 이동시키지 않는다. 완료·수정·앱 활성화·재로그인 시 미래의 다음 1건을 재계산하고, 로그아웃 기간에 지난 알림은 소급 발송하지 않는다. 전역 remind-before를 적용한 시간이 과거면 그 회차는 건너뛴다.

| urgency | 요금제 | 알림 콘텐츠 | 포그라운드 수신 | 배너 탭(백그라운드→복귀) |
|---|---|---|---|---|
| strong | **Pro** | `.timeSensitive` + `defaultRingtone` + category `STRONG_ALARM`(Confirm 액션) + subtitle `L.alarm.notifSubtitleStrong` | 시스템 배너 없음 + **풀스크린 오버레이**(AlarmOverlayView, 대기 큐 FIFO) + 사운드 | **오버레이** 표시 |
| strong | **Free** | 위와 완전 동일 (알림 자체는 무료도 동일 — D14) | `[.banner, .sound]` — 오버레이 없음 | 앱만 열림, 오버레이 없음 |
| weak | 공통 | `.active` + 기본 사운드(설정 존중) + subtitle `L.alarm.notifSubtitleWeak` + **userInfo urgency="weak"** (F5①) | `[.banner, .sound]` | 앱만 열림 |

오버레이 상세(현행 유지): 검정 85% dim + 레드 리플 2겹(1.4s easeOut 무한, reduceMotion 시 생략) + red→orange 그라디언트 아이콘 96pt + 태스크명 title.bold 白 + 확인 버튼(전폭, red→orange, 64pt) → `dismiss()` = `onTaskConfirmed`(태스크 완료 처리) + 대기 큐 pop. 진입 시 warning 햅틱 3연타(0.8s 간격).

권한: 요청 시점 = 메인 진입 0.5s 후(D16), 옵션 = `[.alert, .sound, .badge]`(F5② — criticalAlert 제거).

---

## 9. 엣지 케이스 & 에러 핸들링 (기능별 전수)

### 9.1 Home / 음성
1. 마이크·음성인식 권한 거부 → 에러 토스트(permissionDenied). 이후 매 시도마다 동일 토스트 (설정 앱 유도 문구는 토스트 내 미포함 — 현행 확정).
2. 녹음 중 앱 백그라운드 전환 → audioEngine 세션 중단 → recognitionTask error 콜백 → `stopHandling()`으로 상태 정리 (크래시 없음, 현행).
3. 침묵 카운트다운 중 재발화 → `recognizedText` 갱신 시 `silenceCountdown=0` 리셋 (현행).
4. hold 모드에서 0.5초 미만 초단타 press-release → 텍스트 빈 값 → emptyTranscription 토스트, 사용량 미차감.
5. 30초 상한 도달 → 자동 stop → 정상 파이프라인.
6. AI 사용량: 서버가 검증 가능한 분석 성공 시점에만 1회 commit한다. 네트워크·서버·decode·invalid 실패는 미차감하고, 성공 후 사용자가 저장을 취소하면 차감한다. 날짜 경계는 모든 사용자에게 `Asia/Seoul` 자정을 적용한다.
7. 확인 카드 열린 채 탭 전환 → MainTabView가 `isModalVisible`로 바텀 바 blur 처리 중, 카드도 함께 유지 (현행).
8. 다중 명령 발화("A 추가하고 B 삭제해") → 배열 파싱 → 파괴적 작업이 하나라도 있으면 전체 묶음을 항상 확인 → 사용자가 승인한 스냅샷만 일괄 실행.

### 9.2 QuickAdd (F3 신규)
9. 이름 공백만 → 저장 버튼 disabled (이중: save() 가드).
10. 시간 미선택 저장 → `time=nil` = "시간 미정" — 알림 미등록 (scheduleNotification의 time 가드).
11. 과거 시간 선택(예: 오늘 09:00에 08:00 지정) → 저장은 정상, 알림만 생략 (`fireDate > Date()` 가드 — 현행 규약 재사용).
12. Routine 모드 저장 → date nil 이므로 매일 발생 + (time 있으면) 매일 반복 알림.
13. 시트 위 TimePickerModal 중첩 → 기존 TaskRow 편집과 동일 패턴(시트 위 시트) — iOS 정상 지원.

### 9.3 Routine / Planner
14. 자정 경과 후 앱 활성화 → `checkAndResetDailyTasks`(scenePhase active) — 어제 요일 기록→isCompleted 리셋→주 경계면 weeklyCompletions 초기화. 앱을 며칠 안 연 경우: lastReset 요일에만 기록되고 중간 날짜는 미기록(false 유지) — 알려진 제한, 허용.
15. WeeklyBar 과거 요일 수동 토글 → 즉시 safeSave (현행).
16. 리오더 중 외부 데이터 변경(@Query 갱신) → 드래그 중이면 순서 동기화 무시 (현행 가드).
17. 반복 Appointment의 "오늘 완료"는 회차 개념 없이 단일 isCompleted — 다음 회차에도 완료 유지됨. 알려진 제한(모델 확장 없이는 해결 불가, D10·D23과 동일 계열) — §12 QA에서 동작 확인만.
18. 월간 시트에서 날짜 선택 → selectedDate 변경 → 주간 셀렉터 스크롤 동기화(onChange 프록시 스크롤, 현행).

### 9.4 위젯 / Pro 게이팅 (F4 신규)
19. 신규 설치 직후(스냅샷 없음) → payload nil → 빈 상태 뷰 (현행). 잠금 여부가 우선: free면 잠금 뷰.
20. Pro 캐시가 없거나 서버 검증이 완료되지 않음 → 기본 잠금. 로그인 계정·payload 계정 불일치 시에는 잠금 카피보다 데이터 없는 로그인 상태를 우선 표시.
21. 구독 만료·환불·철회 → Apple 검증 결과를 서버 entitlement에 반영 → 현재 Mora 계정 캐시 갱신 → 위젯 잠금 전환. 앱 미실행 중 만료는 다음 서버 검증 전까지 권한 기능을 새로 승인하지 않는다.
22. 무료 사용자가 잠금 위젯 탭 → `mora://paywall`. 로그아웃 상태에서는 일정·Pro 캐시를 표시하지 않고 LoginView만 표시하며, 로그인 후 사용자가 다시 명시적으로 진입해야 결제 화면을 연다.
23. 위젯 토글 후 앱 미실행 → `pendingWidgetToggles` 큐 대기 → 다음 활성화 때 `syncWidgetToggles()` 일괄 반영 (현행). 같은 태스크를 위젯과 앱에서 연속 토글 시 큐가 blind toggle이라 상태가 뒤집힐 수 있음 — 알려진 제한(현행 유지, §12 QA 관찰 항목).
24. 잠금 전환 시 열려 있던 타임라인 → `reloadAllTimelines()`가 즉시 재렌더.

### 9.5 언두 / 데이터
25. 언두 스택 10 초과 → 최고(最古) 항목 제거 (현행).
26. `.toggled`/`.updated` 언두 대상이 이미 삭제됨 → `isDeleted` 가드로 무시하고 스택 진행 (F5⑤ 방어 — SwiftData 삭제 객체 변경 크래시 방지).
27. `.deleted` 언두 → 스냅샷 재생성(새 UUID) + 알림 재등록 (현행 — id 변경은 허용된 동작).
28. clear_all_tasks("all","all") → 전체 삭제도 언두 1회로 복원 가능 (현행).
29. SwiftData 컨테이너 초기화 실패 → 기존 저장소 파일을 자동 삭제하지 않는다. 읽기 전용 복구·마이그레이션 실패 상태를 표시하고 진단 정보를 민감 데이터 없이 기록한다. 데이터 삭제는 사용자가 명시적으로 계정 삭제를 승인한 경우에만 정리 코디네이터를 통해 수행한다.

### 9.6 알림 / 다국어
30. weak 알림 탭 → (F5① 후) 오버레이 미발동, 앱만 열림.
31. 알림 권한 거부 상태 → `center.add`가 조용히 실패(에러 로그만) — 저장·UI는 정상 (현행 확정).
32. 언어 변경 → 이미 스케줄된 알림의 문구는 스케줄 당시 언어 유지. 재스케줄(태스크 편집/토글) 시 새 언어 적용. **알려진 제한으로 확정** (전체 재스케줄은 이번 범위 아님).
33. 언어 변경 → 위젯은 App Group 복제+reloadAllTimelines로 즉시 반영 (F5③).
34. biweekly 알림은 최초 기준일에서 실제 다음 날짜를 계산한 1회성 예약으로 정확히 14일마다 울린다. weekly trigger 폴백은 허용하지 않는다.

### 9.7 온보딩 (F1 신규)
35. 온보딩 도중 앱 강제 종료 → 플래그 미설정 → 다음 실행 때 처음부터 다시 (허용).
36. 계정 삭제 후 재가입 → `hasCompletedOnboarding`은 UserDefaults(기기) 기준이라 온보딩 재표시 없음 — 확정 동작.
37. 기존 사용자(태스크 보유) → onAppear에서 즉시 스킵되어 화면 깜빡임 최소 (§4.1 — 렌더 전 플래그 전환).

---

## 10. 접근성 / 성능 / 비기능 체크리스트 (D19 확정 기준)

### 10.1 성능 (측정 조건: iPhone 실기기, 정상 Wi-Fi/LTE)
- [ ] 녹음 종료 → 확인 카드 표시 **p90 ≤ 4초** (Gemini 왕복 포함)
- [ ] 마이크 탭 → 리스닝 시작 **≤ 0.3초** (`warmUp()` 사전 초기화 유지 필수)
- [ ] 콜드 스타트 → 홈 렌더 **≤ 2초** (세션 캐시 복원 경로 유지)
- [ ] 위젯 스냅샷 기록이 메인 스레드 저장 핫패스를 막지 않음 (0.5s 디바운스 유지)

### 10.2 접근성 (신규·수정 UI 전부 적용)
- [ ] VoiceOver: 온보딩 3장·QuickAddSheet·? 버튼·위젯 잠금 뷰·페이월 변경분 전부 라벨+힌트
- [ ] `reduceMotion`: 온보딩 페이지 전환·QuickAdd 시트 전이에서 애니메이션 제거 분기 (기존 뷰 패턴 동일)
- [ ] 히트 타깃: 모든 신규 버튼 `minWidth/minHeight 44` + `contentShape`
- [ ] Dynamic Type: 최대 접근성 사이즈(AX5)에서 Home·Routine·Planner·온보딩·QuickAdd 레이아웃 깨짐 없음 (§12 QA 수행)
- [ ] 다국어: 신규 문자열 전부 en/ko/ja 3종 존재 (§3.11 표와 1:1 대조)

### 10.3 비기능 확정 사항 (문서적 확정 — 코드 작업 없음)
- 오프라인: 만료되지 않은 저장 세션이고 명시적 로그아웃·삭제 대기가 아니면 계정 범위의 로컬 일정 확인·수정 허용. AI·Pro 재검증·계정 변경·서버 삭제는 차단 (D5, SDD-2)
- 동기화: 단일 기기 로컬 전용, 클라우드 백업은 "Coming soon" (D1)
- 푸시 알림: 미사용 — 로컬 알림 전용 확정
- 다국어 전환: 앱 내 설정, 재시작 불필요, 기본 "en" (현행 확정)
- 결제: StoreKit 2 monthly/yearly. 무료 AI 3회/일과 Pro 권한은 서버가 현재 Mora 계정 기준으로 검증하며 App Group 플래그는 표시 캐시만 담당 (D8, SDD-4, SDD-5)

---

## 11. 작업 순서 (Phased Rollout)

> 각 Phase는 독립 PR 단위. 순서 근거: Phase 1이 가장 저위험·무의존, Phase 2가 App Group 인프라(언어·premium 플래그)를 함께 구축, Phase 3~4가 그 위의 신규 UI, Phase 5가 검증 마감.
> 매 Phase 공통 완료 조건: `xcodebuild -project ADHD/ADHD.xcodeproj -scheme ADHD -destination 'generic/platform=iOS Simulator' build` 성공(경고 신규 발생 0) + 앱/위젯 두 타깃 모두 빌드.

### Phase 1 — 버그 수정 일괄 (F5 중 ①②⑤⑥⑦⑨⑩⑪ + F8)
대상: §3.6(①②⑥), §3.13·3.14(⑤⑨), §3.11(⑥ 문자열+guideHint 삭제 제외 — guideHint는 Phase 4), §3.3(⑥ OOV 2곳 + TaskEditSheet 삭제), §3.8(⑥), §3.10(⑥ alert만), §3.12(⑩), §3.15+3.2(⑩ Strings·⑪ 스낵바), §3.19(⑩), §3.20(⑦+F8).

**Acceptance Criteria**
- [ ] weak 태스크 알림: 포그라운드=배너, 탭=오버레이 없음 / strong은 (아직 게이팅 전이므로) 오버레이 정상
- [ ] 알림 권한 팝업이 실기기에서 정상 표시 (criticalAlert 제거 확인)
- [ ] `grep -rn "긴급 확인\|오늘의 한 걸음\|지금 당장\|다시 질문하기\|구매 오류\|일정이 업데이트\|일정이 연기" ADHD --include="*.swift" | grep -v Localization.swift` → **0건**
- [ ] update_task 실행→언두: 중복 없이 원래 필드로 복원
- [ ] "오늘 일정 내일로 미뤄줘"(0건 상황 포함) → 스낵바 피드백 항상 표시, 반복 일정 미이동
- [ ] `TaskEditSheet`·`cycleLanguage`·`Untitled.swift`·`DesignSystem.Strings` 참조 grep 0건, 빌드 성공
- [ ] ja/en 설정에서 알람 오버레이·알림 문구가 해당 언어로 표시

### Phase 2 — Pro 게이팅 + App Group 인프라 (F4 + F5③)
대상: §3.9, §3.16, §3.17, §3.18(양쪽!), §4.3, §3.1(paywall 라우팅), §3.2(페이월 시트), §3.10(카피), §3.11(b).

**Acceptance Criteria**
- [ ] 무료 계정: 위젯 6종 전부 잠금 뷰, 탭 → 앱 페이월 시트 오픈
- [ ] Pro 계정(StoreKit 로컬 테스트): 위젯 6종 정상 데이터 표시
- [ ] 무료 strong 알림: time-sensitive 배너 수신 O, 오버레이 X / Pro: 오버레이 O
- [ ] 구독 구매/만료 전환 시 위젯이 앱 재실행 없이(리스너 경유) 잠금↔해제 전환
- [ ] 언어 변경 즉시 위젯 문자열이 ko/ja/en으로 갱신
- [ ] `diff ADHD/Shared/WidgetDataStore.swift ADHD/ADHDWidget/WidgetDataStore.swift` → 차이 없음
- [ ] 페이월 기능 목록이 실제 게이팅과 문구상 일치

### Phase 3 — 빠른 추가 (F3)
대상: §4.2, §3.4, §3.5, §3.11(quickAdd 문자열).

**Acceptance Criteria**
- [ ] 3개 모드(routine/todayTask/appointment) 각각 저장 → 올바른 category·date·섹션에 즉시 표시
- [ ] 저장 전후 AI 카운터(`remainingAIUsage`) 불변 — 네트워크 끊고도 저장 성공
- [ ] 시간 지정 시 알림 등록(설정 앱 Pending 확인), 미지정 시 미등록
- [ ] 저장 직후 언두 스낵바 → 언두로 제거 가능
- [ ] 빈 이름 저장 불가(버튼 disabled)

### Phase 4 — 온보딩 + 음성 가이드 (F1 + F2)
대상: §4.1, §3.1(분기), §3.3(? 버튼·자동 표시·힌트 삭제), §3.11(onboarding 문자열, guideHint 삭제), §6.4.

**Acceptance Criteria**
- [ ] 신규 사용자: 로그인 → 온보딩 3장 → 시작 → Home (가이드 자동 표시 없음 — D21)
- [ ] 온보딩 스킵: Home 진입 시 가이드 시트 자동 1회 → 닫으면 재표시 없음
- [ ] 기존 사용자(태스크 보유): 온보딩 완전 미노출
- [ ] ? 버튼으로 가이드 상시 재진입
- [ ] "마이크를 길게 눌러" 문구 앱 전체에서 소멸 (grep 0건)
- [ ] reduceMotion + VoiceOver로 온보딩 전 과정 완주 가능

### Phase 5 — 테스트·QA·문서 마감 (F7 + F5⑫⑬)
대상: §4.4 테스트 5파일(+§3.13 테스트 가능화 리팩터링), §12 수동 QA 수행, README.md(주간 셀렉터 기술 정정 — "오늘 고정+±7일")·DESIGN.md(§13.2 확정 차이 각주 추가).

**Acceptance Criteria**
- [ ] `xcodebuild test` — 신규 테스트 전부 green (5파일, 각 파일 최소 §4.4 필수 케이스 커버)
- [ ] §12 체크리스트 전 항목 수행 및 실패 0
- [ ] §13 셀프 체크 통과

### Security Phase 6 — 계정별 로컬 저장소·Auth 상태 머신·정리 코디네이터 (F9)

1. SHA-256 계정 namespace별 물리 store를 사용하고 기존 테스트 `default.store`를 1회 cutover reset한다.
2. Auth 상태를 `booting`, `authenticatedOnline`, `authenticatedOfflineLimited`, `signedOut`, `deletionPending`, `lockedInvalidSession`으로 분리한다.
3. 로그아웃·계정 전환·세션 무효 시 현재 계정의 알림, AlarmKit, 위젯, 음성 초안, 민감 Undo를 제거한다. 로그아웃에서는 일정 본문을 보존한다.
4. A/B 계정 전환, 오프라인 재실행, 로그아웃·재로그인 회귀 테스트를 먼저 추가한다.

**Acceptance Criteria**
- [ ] A 로그아웃 후 B 로그인에서 A의 일정·루틴·위젯·Undo가 보이지 않음
- [ ] A로 재로그인하면 A 일정이 복원되고 미래 알림만 재예약됨
- [ ] 로그아웃·삭제 대기 중 LoginView 외 일정 노출 경로가 없음
- [ ] 로그아웃 기간에 지난 알림이 소급 발송되지 않음

### Security Phase 7 — 멱등적 계정 삭제 (F10)

최종 확인 → 로컬 노출 즉시 잠금 → 서버 Apple token revoke·계정 데이터 purge·Auth 삭제 → request ID/status token 완료 확인 → 해당 계정 물리 store 삭제 순서로 구현한다. 삭제 작업은 중복 요청과 앱 종료·재실행에 안전해야 하며 서버 오류를 성공으로 표시하지 않는다. App Store 구독은 프로그램 방식으로 해지할 수 없으므로 삭제를 막지 않고 Apple 구독 관리 링크를 제공한다.

**Acceptance Criteria**
- [ ] 서버 요청 상태와 로컬 잠금/완료 후 물리 삭제 상태를 별도로 처리
- [ ] 네트워크 중단 후 자동 재시도되고 동일 요청이 중복 삭제 부작용을 만들지 않음
- [ ] 서버 확인 전 “삭제 완료” UI가 나오지 않음
- [ ] 계정 삭제 후 재부팅·재설치·재로그인으로 로컬 데이터가 복원되지 않음

### Security Phase 8 — 서버 quota·entitlement·StoreKit 귀속 (F11, F12)

서버 quota 원장과 원자적 성공 차감을 먼저 구현한 뒤 StoreKit transaction을 현재 Mora 계정과 연결한다. 같은 Mora 계정의 다른 기기는 Apple 검증 후 복원할 수 있지만 다른 Mora 계정에는 자동 공유하지 않는다. Family Sharing은 v1에서 비활성으로 검증한다.

**Acceptance Criteria**
- [ ] 직접 Edge Function 호출과 동시 요청으로 무료 3회 제한을 우회할 수 없음
- [ ] 네트워크·서버·분석 실패는 미차감, 분석 성공 후 저장 취소는 차감
- [ ] 다른 Mora 계정으로 전환하면 기존 Pro가 자동 공유되지 않음
- [ ] 클라이언트 `isPremium` 변조만으로 서버 권한 기능을 사용할 수 없음

### Security Phase 9 — 편집 가능한 음성 초안·파괴적 명령 확인 (F13)

STT 최종 문장을 공용 입력 초안으로 옮기고 사용자의 명시적 추가·분석에서만 AI를 호출한다. 실패 시 초안을 유지한다. 텍스트 모드·탭 이동·백그라운드에서 마이크를 즉시 중지하며 초안은 유지한다. 로그아웃·삭제에서만 초안을 제거한다.

**Acceptance Criteria**
- [ ] 인식 문장을 직접 수정한 뒤 분석 가능
- [ ] 분석 실패 후 같은 편집 초안으로 재시도 가능
- [ ] 삭제·전체 삭제·대량 변경은 `confirmBeforeSave`와 무관하게 확인 전 실행되지 않음
- [ ] 탭 이동·텍스트 전환·백그라운드에서 마이크가 계속 실행되지 않음

### Security Phase 10 — 최초 기준일 반복 엔진·알림 재예약 (F14)

반복 계산을 `RecurrenceEngine`으로 통합한다. 격주·월간·연간은 실제 다음 날짜를 산출해 1회성 알림으로 예약하고 완료·수정·앱 활성화·재로그인에서 다음 1건을 재계산한다.

**Acceptance Criteria**
- [ ] 격주가 최초 기준일에서 정확히 14일 간격이며 완료 지연으로 drift하지 않음
- [ ] 31일 월간 일정이 4월 30일·2월 28/29일에 실행됨
- [ ] 화면 발생일과 UN 알림·AlarmKit 발생일이 일치

### Security Phase 11 — 민감 로그 제거·배포 검증 (F15)

앱과 Edge Function에서 음성 전사문·일정명·루틴명·Gemini raw response를 제거한다. 비식별 운영 메타데이터만 남기고 배포 후 canary에서 민감 문자열이 수집되지 않는지 확인한다.

**Acceptance Criteria**
- [ ] 앱 콘솔과 서버 로그에 실제 전사문·일정명·루틴명이 없음
- [ ] 오류 추적은 request id·상태 코드·지연시간만으로 가능
- [ ] 배포된 Edge Function 소스와 검증한 커밋이 일치

---

## 12. QA / 테스트 체크리스트 (수동)

공통 매트릭스: **언어 en/ko/ja × 라이트/다크 × 무료/Pro** — 아래 시나리오 중 (★)표시는 전 매트릭스 수행, 나머지는 ko+다크+무료 1회.

**음성 파이프라인**
- [ ] ★ "오전 9시에 약 먹기" → Routine 분류·09:00 AM·확인 카드→저장→Routine 탭 표시
- [ ] "내일 오후 3시 치과" → Appointment·내일 날짜·Planner 탭 표시+알림 등록
- [ ] "지금부터 1시간 뒤 미팅" → 상대 시간 정확 계산
- [ ] "운동 삭제해줘" → 삭제 + 언두 복원
- [ ] "물 마시기 완료" → 완료 처리
- [ ] ★ "오늘 날씨 어때?" → OOV 카드(선택 언어로 재치 응답, `다시 질문하기` 버튼)
- [ ] 무음/30초 상한으로 녹음 종료 → 인식 문장이 편집 초안에 표시되고 AI는 자동 호출되지 않음
- [ ] 비행기 모드 → 저장 세션이 유효하면 로컬 일정 확인·수정 가능, AI 분석은 차단되고 초안·사용량 유지
- [ ] 무료 3회 성공 분석 후 4회째 서버가 차단 / Asia/Seoul 자정 후 서버 quota 갱신
- [ ] hold 모드 전환 후 press-and-hold 동작, 침묵 카운트다운 비활성 확인
- [ ] "저장 전 확인" off → 안전한 추가·일반 수정만 즉시 실행; 삭제·전체 삭제·대량 변경은 여전히 확인
- [ ] AI 분석 실패 → 편집 초안 유지·서버 사용량 미차감

**QuickAdd / Routine / Planner**
- [ ] Phase 3 AC 전 항목 + 리오더·검색·스와이프 삭제·WeeklyBar 과거 토글 회귀 확인
- [ ] 월간 시트로 +20일 점프 → 주간 셀렉터 동기 스크롤 → "오늘" 복귀
- [ ] 자정 경과(기기 시간 변경) 후 활성화 → 루틴 리셋+어제 기록

**알림/알람**
- [ ] ★ strong 알림 (Pro): 포그라운드 오버레이 / 배너 탭 오버레이 / 확인=완료 처리
- [ ] ★ strong 알림 (무료): 배너만, 오버레이 없음
- [ ] weak 알림: 배너, 탭해도 오버레이 없음
- [ ] 사전 알림 15분 설정 → 15분 전 발화
- [ ] 루틴 알림 토글 off → 신규 루틴 알림 미등록
- [ ] 연속 strong 2건 → 오버레이 큐 순차 표시
- [ ] 격주 일정 → 최초 기준일에서 +14/+28일 알림, +7/+21일에는 미발화
- [ ] 31일 월간 일정 → 짧은 달의 마지막 날 발화, 늦게 완료해도 다음 기준일 drift 없음

**위젯**
- [ ] ★ 6종 잠금(무료)/해제(Pro) 상태, 잠금 탭→페이월
- [ ] 위젯 완료 토글 → 앱 복귀 시 동기화 / 언어 변경 즉시 위젯 반영
- [ ] 앱에서 태스크 추가 → 1초 내 위젯 갱신(디바운스 후)

**온보딩/계정/구독**
- [ ] Phase 4 AC 전 항목
- [ ] A 로그아웃→B 로그인: A 데이터·위젯·알림 미노출 / A 재로그인: A 데이터 복원+미래 알림만 재예약
- [ ] 명시적 로그아웃 후 오프라인 재실행 → 저장 세션과 관계없이 로그인 화면만 표시
- [ ] 계정 삭제 → 로컬 데이터 즉시 미노출, 서버 완료 전 성공 표시 없음, 중단 후 재시도 가능
- [ ] 구매/복원/취소 흐름, 구매 오류 alert 지역화(★), 구매 Pro가 다른 Mora 계정에 자동 공유되지 않음
- [ ] 앱 삭제 데이터 손실 안내와 App Store 구독 관리 링크가 설정·삭제 확인 화면에 표시

**보안 로그**
- [ ] 실제 일정명·루틴명·음성 전사문을 식별 가능한 marker로 입력한 뒤 앱 콘솔·Edge Function 로그 검색 결과 0건
- [ ] 삭제·quota·entitlement 오류 로그에는 request/job id와 상태만 남고 이메일·원문은 없음

**접근성/레이아웃**
- [ ] VoiceOver로 핵심 플로우(음성 추가→완료 토글→삭제) 완주
- [ ] Dynamic Type AX5에서 5개 화면(홈/루틴/플래너/온보딩/QuickAdd) 잘림·겹침 없음
- [ ] reduceMotion에서 모든 화면 전이 정상

---

## 13. 디자인 금기/지침 셀프 체크

### 13.1 금기 5종 × 이번 변경분 검증

| 금기 | 검증 결과 |
|---|---|
| **#1 하드 그레이 금지** | UndoSnackbar 중성 회색을 웜 톤으로 **수정**(§3.2). 신규 UI(온보딩·QuickAdd·위젯 잠금)는 전부 DesignSystem 토큰만 사용 — `#000000`·중성 회색 신규 도입 0건. 온보딩 페이지 도트도 onSurfaceVariant 기반(§6.4) |
| **#2 1px 구분선 금지** | 신규 UI 구분은 배경 전환(surfaceContainerLow)과 여백만 사용. GlassModifier의 1pt 白 스트로크는 "글래스 하이라이트"로 섹션 구분 용도가 아님 — 비저촉 판정(§6.6). 위젯 DailyOverview의 기존 Divider는 위젯 내부 관례로 현행 유지(변경분 아님) |
| **#3 정보 밀도 초과 금지 (화면당 실행 액션 ≤3)** | 온보딩: 장당 CTA 1+Skip(§6.4) / QuickAdd: CTA 1(저장)+입력 칩(§6.5) / Home 상단 바에 ? 버튼 1개 추가 — 상단 유틸리티 아이콘이며 메인 캔버스는 여전히 마이크 단일 포커스 / 탭 헤더 + 버튼도 로우 컨트라스트 유틸리티(60% opacity) |
| **#4 월간 캘린더 금지** | 메인 Planner 뷰 = 7일 주간 유지. 월간 그래픽 시트는 **D11로 명문화된 예외**(먼 날짜 점프용 임시 도구, 상시 노출 아님) |
| **#5 텍스트 장벽 금지** | 온보딩 각 장 = 아이콘 앵커 + 제목 + 1문장. 신규 문자열 전부 1줄 레이블 수준(§3.11) |

### 13.2 DESIGN.md와 확정 차이 (D24 — Phase 5에서 DESIGN.md에 각주 반영)

| 항목 | DESIGN.md | 확정 스펙 (코드 채택) |
|---|---|---|
| 폰트 | Manrope + Inter | 시스템 폰트 (D15) |
| 카드 radius | xl(3rem≈48px) | 18~24pt |
| Glass | surface-lowest 80% + 20px blur | ultraThinMaterial 기반 `glassStyle` |
| display-lg | 3.5rem | `Font.title.semibold` (≈28pt) |
| 주간 뷰 | 오늘+6일(7일) | 오늘 고정 + 선택일 ±7일 스크롤 |
| Shadow=Glow | onSurfaceVariant 5%/40px/y10 | 확인 카드: primary 15%/40px/y15 + onSurfaceVariant 5%/10px/y5 (이중 글로우) |

### 13.3 Do's 준수 확인
- [x] 여백 = 기능: 온보딩 장당 요소 3개 이하, Home 캔버스 불변
- [x] 의도적 비대칭: 탭 헤더 좌측 타이틀 + 우측 유틸 클러스터 유지, 신규 버튼도 우측 클러스터 편입
- [x] 300ms+ 전환: 온보딩 페이지 전환 easeInOut 0.3s, 시트 전이 spring(0.4)
- [x] Shadow=Glow: 신규 그림자 추가 없음 (기존 토큰 재사용)
- [x] 배경 전환 구조화: QuickAdd 입력 필드 = surfaceContainerLow on background

### 13.4 최종 자체 검증 (문서 작성 시 수행 완료)
- [x] 스펙 §11 확인 필요 9항목 전부 §2.1에서 답 매핑
- [x] 금지 표현("적절히", "필요시", "일반적인 방식으로") 본문 미사용
- [x] §3의 모든 파일 경로가 실제 레포 경로와 일치 (2026-07-07 정독 기준)
- [x] 모든 신규 문자열 en/ko/ja 3종 완비 (§3.11)

---

## 14. 최신 보안 SDD 정합성 명세

원문: [MORA 보안 감사 대응 SDD — 확정 결정사항 (2026-08-01)](https://app.notion.com/p/3af8320bd64b81788d14d50c9cfc2379)

### 14.1 폐기·대체된 과거 규칙

| 과거 규칙 | 최종 규칙 |
|---|---|
| SwiftData 모델 변경·마이그레이션 금지 | 계정 격리를 위한 store/owner 모델과 기존 데이터 마이그레이션 필수 |
| 오프라인 전체 입력 차단 | 유효한 저장 세션의 계정 범위 로컬 일정 확인·수정 허용, 서버 기능만 제한 |
| AI 호출 시도 시 로컬 사용량 차감 | 서버가 검증한 분석 성공만 1회 차감, 실패 미차감 |
| 기기 StoreKit 상태가 Pro 권한 | 구매 당시 Mora 계정에 귀속된 서버 entitlement가 권한 원천 |
| STT 종료 즉시 AI 분석 | 인식 문장을 편집 초안으로 표시하고 명시적 추가·분석에서 호출 |
| `confirmBeforeSave=false`면 모든 명령 즉시 실행 | 삭제·전체 삭제·대량 변경은 항상 확인 |
| biweekly UN 알림을 weekly로 허용 | 최초 기준일에서 실제 날짜를 계산해 정확히 14일마다 1회 예약 |
| SwiftData 초기화 실패 시 store 파일 자동 삭제 | 자동 삭제 금지, 복구·마이그레이션 오류 상태로 전환 |
| 민감한 파싱 결과·LLM 응답 콘솔 출력 | 원문 로그 금지, 비식별 메타데이터만 허용 |

### 14.2 인증 상태와 데이터 노출

| 상태 | 일정 본문 | 위젯·알림 | 서버 기능 |
|---|---|---|---|
| `booting` | 숨김 | 숨김·미예약 | 금지 |
| `authenticatedOnline(account)` | 현재 계정만 표시 | 현재 계정만 활성 | 허용 |
| `authenticatedOfflineLimited(account)` | 만료되지 않은 저장 세션의 현재 계정만 표시·수정 | 기존 미래 예약은 계정 범위로 유지 | AI·Pro 확인·계정 변경·삭제 금지 |
| `signedOut` | 보존하되 숨김 | 모두 취소·스냅샷 제거 | 금지 |
| `deletionPending(job)` | 보존하되 잠금·숨김, 서버 완료 시 해당 store 삭제 | 모두 취소·제거 | 삭제 상태 확인·재시도만 허용 |
| `lockedInvalidSession` | 보존하되 숨김 | 모두 취소·스냅샷 제거 | 재인증 전 금지 |

세션 무효 시 “로컬 노출 정리”는 일정 본문 삭제가 아니라 잠금·위젯 제거·알림 취소를 뜻한다. 명시적 계정 삭제만 일정 본문을 제거한다.

### 14.3 로그아웃·계정 전환·삭제 정리 매트릭스

| 대상 | 로그아웃/세션 무효 | 계정 전환 | 계정 삭제 |
|---|---|---|---|
| SwiftData 일정·루틴 | 보존·숨김 | 계정별 격리 | 해당 계정 데이터 삭제 |
| UN 알림·AlarmKit | 취소 | 이전 계정 취소, 새 계정 미래분만 예약 | 취소 |
| Widget payload·pending toggle | 제거 | 이전 제거 후 새 계정 payload 작성 | 제거 |
| 음성 초안·민감 Undo | 제거 | 이전 계정 상태 제거 | 제거 |
| Supabase 세션·공급자 캐시 | 로그아웃 상태로 정리 | 새 계정 세션으로 교체 | 제거 |
| 서버 Auth·프로필·quota·구독 연결 | 유지 | 계정별 유지 | 멱등적 서버 작업으로 삭제 |

### 14.4 계정 삭제 사용자 흐름

설정 또는 데이터 관리 화면에 다음 취지의 지속 안내를 표시한다.

> 이 앱의 일정과 루틴은 기기에 저장됩니다. 앱을 삭제하면 기기 데이터가 삭제되며, 앱을 다시 설치해도 복원되지 않습니다.

계정 삭제 확인에는 일정·루틴·알림·위젯의 영구 삭제와 App Store 구독 별도 해지를 함께 고지하고 구독 관리 화면 링크를 제공한다. 서버 작업 접수와 로컬 삭제를 분리해 표시하며 서버 완료 전에는 “삭제 완료”라고 표시하지 않는다. 삭제 대기 계정은 재로그인을 차단한다.

로컬 삭제 대상은 해당 계정의 SwiftData 일정·루틴, 계정별 UserDefaults·캐시, Widget App Group 스냅샷·pending toggle, UN 알림, AlarmKit 예약, Undo, 음성 초안, Supabase 세션·공급자 캐시다. 서버 삭제 대상은 Auth 계정, 프로필, AI quota, 구독 연결, Apple 로그인 토큰·연결 정보다. 각 단계 오류를 조용히 무시하지 않는다.

### 14.5 로그인 공급자

로그인은 Apple만 지원한다. 다른 소셜 로그인, 공급자 추상화, 계정 선택기, 최근 로그인 공급자 저장·표시는 구현하지 않는다. 설정의 인증 표시는 고정된 `Apple ID`로 충분하며 로그아웃 화면에는 일정이나 계정의 민감 식별 정보를 노출하지 않는다.

### 14.6 잔여 위험

잠금 화면에서 기존 방식으로 일정 완료가 가능한 동작은 이번 보안 대응에서도 유지한다. 이는 해결 완료가 아니라 사용자 승인으로 수용한 잔여 위험이며, 이번 범위에서 동작을 확장하지 않는다. Finding #21은 추적 대상에서 제외한다.

---

## 15. 2026-08-04 인터뷰 확정 및 구현 상태

### 15.1 INT-01~35 확정 원장

아래 결정은 같은 주제의 SDD/D1~D24 문구보다 우선한다.

| ID | 확정 결정 |
|---|---|
| INT-01 | Mora 계정마다 물리적으로 분리된 SwiftData store를 사용한다. |
| INT-02 | 현재 생산 사용자는 없고 이관할 생산 데이터도 없다. |
| INT-03 | 기존 owner 없는 테스트 `default.store`는 cutover에서 한 번만 초기화한다. import하지 않으며 런타임 자동 삭제는 금지한다. |
| INT-04 | 로그아웃은 현재 기기만 대상으로 하며 서버 sign-out 실패와 무관하게 즉시 잠근다. 위젯·알림·AlarmKit·초안·Undo는 제거하고 계정 store는 보존한다. |
| INT-05 | Apple 로그인만 지원한다. 다른 소셜 로그인, 공급자 추상화, 계정 선택기, 최근 로그인 UI는 만들지 않는다. 계정 전환은 로그아웃 후 Apple 로그인이다. |
| INT-06 | 알림 토글·사전 알림·저장 전 확인·위젯·entitlement·삭제/reset marker는 계정 범위, 테마·언어·햅틱·마이크 모드·온보딩은 기기 범위다. |
| INT-07 | 서버가 계정 삭제 완료를 확인한 경우에만 해당 계정 store를 삭제한다. 만료·무효 세션은 잠그고 보존한다. |
| INT-08 | 계정 삭제는 영구 손실/구독 안내 → 명시적 인지 → Sign in with Apple 재인증 → 정확 범위 최종 확인 → Apple token revoke 순서다. |
| INT-09 | v1 데이터 내보내기는 제공하지 않는다. |
| INT-10 | 비식별 삭제 receipt는 30일 보관하고 bounded daily purge한다. 태스크명·이메일 등 직접 식별/본문 데이터는 즉시 제거한다. |
| INT-11 | 활성 구독이 계정 삭제를 막지 않는다. Apple 구독 관리 링크를 제공하며, 명시적 Restore에서만 새 Mora 계정으로 1회 rebind할 수 있다. 자동 rebind는 금지한다. |
| INT-12 | 마지막 서버 검증 `accessUntil`/만료 시각까지만 오프라인 Pro를 허용하고 AI는 오프라인에서 차단한다. |
| INT-13 | schema-valid AI 응답은 clarification/OOV/no-op을 포함해 성공 차감한다. network/server/decode/invalid/unknown 응답은 차감하지 않는다. |
| INT-14 | 무료 quota 날짜는 모든 사용자에게 `Asia/Seoul` 자정을 적용한다. |
| INT-15 | 명시적 billing grace만 Pro다. grace 없는 `billing_retry`는 Free다. |
| INT-16 | 요청 당시 Free였던 성공 분석만 무료 quota를 소비한다. |
| INT-17 | 월 $4.99/연 $35.99, 안정된 product ID, StoreKit 동적 표시 가격, 단일 StoreKit config를 사용한다. |
| INT-18 | 무료 체험은 제공하지 않는다. |
| INT-19 | 한 AI bundle은 항목별 부분 성공을 허용한다. 성공 항목은 저장·알림하고 실패 항목은 재시도 가능하게 남기며 store 오류면 이후 항목 실행을 중단한다. |
| INT-20 | 한 번의 승인에서 성공한 mutation들은 하나의 grouped Undo로 묶는다. |
| INT-21 | 승인 뒤 대상이 수동 변경되면 최신 수동 편집이 우선한다. stale 항목은 최신 preview로 갱신해 다시 확인하고, 변하지 않은 항목만 실행한다. |
| INT-22 | 2월 29일 연간 반복은 평년 2월 28일에 발생하되 anchor는 2월 29일로 유지한다. |
| INT-23 | 여행/시간대 변경 후 반복 시각은 현재 로컬 wall clock을 따른다. |
| INT-24 | DST gap은 다음 유효 시각, overlap은 첫 번째 발생을 한 번만 사용한다. |
| INT-25 | 저장소 오류 시 데이터를 보존하고 Retry·재시작 안내·오류 코드·지원 경로를 제공한다. 자동 reset은 금지한다. |
| INT-26 | Apple crash report와 Supabase 최소 구조화 로그만 사용하며 Sentry는 도입하지 않는다. |
| INT-27 | raw 오류 메타데이터 14일, 일별 익명 aggregate 90일, bounded daily purge를 적용한다. |
| INT-28 | Supabase 프로젝트 하나에서 prod/stage를 논리 schema/route로 분리한다. Auth·secret·quota 공유 위험은 수용 위험으로 기록한다. |
| INT-29 | 앱·위젯·테스트 target의 최소 버전은 iOS 26.2다. |
| INT-30 | v1은 iPhone만 지원한다. |
| INT-31 | 자동 테스트 → internal TestFlight 48시간 → App Store 순서다. 외부 beta는 하지 않는다. |
| INT-32 | iOS 26.2 실기기 iPhone 최소 2대로 검증한다. |
| INT-33 | 현재 Sandbox 계정은 1개이며 출시 전 두 번째 계정을 준비한다. |
| INT-34 | 삭제 상태는 앱 안에서 로컬 request ID/status token polling으로 표시한다. 이메일 알림은 보내지 않는다. |
| INT-35 | 부분 성공 뒤 성공 카드와 원본 초안은 닫을 때 제거한다. 실패/stale 카드만 편집·재확인하며 전체 초안을 다시 분석해 중복 생성하지 않는다. |

### 15.2 구현 상태 원장

| 상태 | 범위 | 현재 결과 |
|---|---|---|
| 구현 | 계정별 로컬 격리 | SHA-256 계정 경로, 동적 ModelContainer, 1회 legacy test DB reset, 무인증 시 store 미오픈 |
| 구현 | 인증/로그아웃/계정 전환 | 6상태 Auth, 현재 기기 즉시 잠금, 알림·AlarmKit·위젯·초안·Undo 정리, store 보존·재로그인 복원 |
| 구현 | 계정별 설정/위젯 | 알림·사전 알림·확인 설정 namespace 분리, widget payload/toggle/Pro cache에 동일 account scope 검증 |
| 구현 | 음성·AI 승인 | 편집 가능한 초안, 명시적 분석, 파괴적 명령 강제 확인, UUID preview/stale 재확인, 항목별 부분 성공, grouped Undo |
| 구현 | AI quota 코드 | strict JWT/입력/출력, KST 원자 quota, 성공만 차감, 같은 request ID 재시도·10분 결과 replay, 클라이언트는 서버 snapshot만 표시 |
| 구현 | 반복 일정 | 정확한 14일, 월말 clamp, Feb 29 anchor, wall clock/DST 정책, biweekly/monthly/yearly one-shot 재무장 |
| 구현 | 저장 오류 안전 UI | 자동 DB 삭제 없이 오류 코드·Retry·재시작 안내·지원 링크 제공 |
| 부분 구현 | 계정 삭제 | iOS 영구 손실/구독 안내·Apple 재인증·Keychain request 상태·저빈도 polling·완료 후 store 삭제와 서버 idempotent state machine을 구현했다. 실제 Supabase 배포, Apple secret, 실계정 end-to-end 검증은 미완료다. |
| 부분 구현 | StoreKit/entitlement | 서버 read model, account-scoped cache, active/grace/offline deadline, stable server appAccountToken 경계를 구현했다. 안전한 Apple JWS 검증 write endpoint와 App Store Server Notification V2가 없어 결제·Restore는 과금 전에 의도적으로 차단한다. |
| 부분 구현 | 보존/운영 로그 | private prod/stage schema, 10분 AI 결과 cache, 14/90/30일 보존과 bounded cleanup 함수를 구현했다. 실제 daily schedule과 배포 후 로그 검사는 미완료다. |
| 미구현(외부) | 출시 검증 | 두 번째 Sandbox 계정, iOS 26.2 실기기 2대, internal TestFlight 48시간, App Store 제출 |

### 15.3 검증 기록과 남은 외부 작업

- `analyze-task` 순수 Deno test **11/11**, `delete-account` contract Deno test **4/4** 통과. 이번 변경 파일의 format/lint/type-check도 통과했다. 기존 `analyze-task/test/` 레거시 도구의 포맷·lint 문제는 변경 범위 밖이어서 수정하지 않았다.
- 보안 migration은 격리된 PostgreSQL 16 DB에 두 번 적용해 재실행 가능성을 확인했다. 삭제 `begin → claim → Apple revoked marker → purge → Auth delete → complete`, 30일 receipt, lock 제거, anon RPC 접근 거부를 확인한 뒤 임시 DB/role을 제거했다.
- iOS 앱·위젯은 시뮬레이터를 부팅하지 않은 generic iPhone Debug 빌드(`CODE_SIGNING_ALLOWED=NO`, `-jobs 2`)가 성공했다. 최종 통합 상태의 시뮬레이터 test는 Mac 발열 보호를 위해 재실행하지 않았으므로 출시 검증으로 간주하지 않는다. 남은 비차단 경고는 Swift 6 actor-isolation, 누락된 AccentColor asset, `UIScreen.main` deprecation이다.
- 실제 환경에는 아직 migration/Edge Function/cleanup schedule을 배포하지 않았다. 필요한 secret은 `APPLE_CLIENT_ID`, 회전 가능한 `APPLE_CLIENT_SECRET`, 32-byte 이상 `DELETION_STATUS_SECRET`, 기존 Supabase/Gemini secret이다.
- Apple은 앱이 사용자의 App Store 구독을 직접 해지하는 API를 제공하지 않는다. 계정 삭제는 구독 때문에 막지 않으며 앱에서 Apple 구독 관리 링크를 제공한다.
- StoreKit 서버 write를 열기 전 App Store Server API/JWS 검증, Notification V2, environment 검증, original transaction 단일 귀속, 명시적 1회 rebind를 구현·검증해야 한다.
- prod/stage는 한 프로젝트의 논리 분리이므로 Auth·service-role secret·프로젝트 장애 영역을 공유한다. 이는 INT-28의 수용 위험이다.

---

*문서 끝. 구현 중 이 문서와 실제 코드가 충돌하면 라인 번호는 코드를, 동작 명세는 §15의 INT-01~35, 2026-08-01 보안 SDD, Security Phase 6~11, 기존 D1~D24 순으로 우선한다.*
