# Minimalist Voice-First Task Manager

## 1. Product Overview (기획 배경 및 목적)
현존하는 알람, 미리알림, 캘린더 앱들은 기능이 파편화되어 있고 텍스트 입력 방식이 번거롭습니다. 이로 인해 루틴이나 일정 관리에 어려움을 겪는 사용자(특히 ADHD 성향)들은 "일일이 기록하느니 그냥 기억하고 말지" 하다가 중요한 일정을 놓치는 악순환을 겪습니다.
본 프로젝트는 이러한 페인 포인트(Pain Point)를 해결하기 위해, 마이크 하나로 모든 것을 기록하고 알려주는 극강의 미니멀 통합 일정/루틴 관리 플랫폼을 개발합니다.

## 2. Target Audience (타겟 유저)
- 복잡하고 빽빽한 플래너 앱에 인지적 과부하를 느끼는 사용자
- 주의력 분산이 쉬워 직관적이고 단순한 UX가 필요한 사용자 (ADHD 등)
- 텍스트 타이핑의 마찰(Friction)을 극도로 귀찮아하는 사용자

## 3. Core UX/HCI Principles (핵심 디자인 원칙)
사용자의 주의력 분산을 막고 인지적 긴장감(Cognitive Tension)을 최소화하는 것이 최우선 목표입니다.

- **Voice-First (마찰 최소화)**: 복잡한 텍스트 타이핑 대신 자연어 음성 입력으로 진입 장벽을 낮춥니다.
- **Zero Visual Clutter (시각적 노이즈 제거)**: 화면당 요구하는 단일 행동(Single Action) 외의 불필요한 상호작용 요소를 배제합니다. 눈이 편안한 오프화이트(Off-white) 배경과 따뜻한 톤의 포인트 컬러를 사용합니다.
- **Low-Contrast Secondary Actions**: 메인 태스크(할 일) 외의 수정/추가 버튼 등은 시각적 대비(투명도, 회색 톤)를 낮춰 시야를 방해하지 않도록 설계합니다.
- **Visual Anchors & Padding**: 텍스트 장벽(Wall of text)을 피하기 위해 직관적인 아이콘을 사용하고, 컴포넌트 간 여백을 극단적으로 넓게 가져갑니다.

## 4. Screen Requirements (주요 화면 및 기능 명세)

### 📍 Tab 1: Home (Voice Interface)
- **목적**: 앱의 핵심인 '음성 기록'에만 온전히 집중하는 랜딩 페이지.
- **UI 구조**: 화면 정중앙에 시각적 계층이 가장 높은 커다란 마이크 버튼 단일 배치. 하단에 "What should I remember for you?"라는 직관적인 안내 문구 노출.

### 📍 Tab 2: Routine (Habits & Tasks)
- **목적**: 매일 반복되는 루틴과 일회성 할 일을 관리.
- **UI 구조**:
  - `Daily Routines` / `Today's Tasks`: 두 섹션을 시각적으로 명확히 분리.
  - **Row Design**: 좌측 체크박스, 중앙 할 일 이름. 시간 텍스트는 매우 작고 연하게 배치. 우측의 수정/음성 아이콘은 인지적 과부하를 막기 위해 Low-contrast로 은은하게 배치.

### 📍 Tab 3: Planner (Weekly Appointments)
- **목적**: 자잘한 루틴을 배제하고, 굵직한 약속과 외출 일정만 한눈에 파악.
- **UI 구조**: 
  - 빽빽한 월간 달력 대신 **오늘 기준 + 6일(총 7일)**만 노출되는 가로형 주간 캘린더 배치.
  - 하단에는 해당 날짜의 주요 약속(Appointments) 리스트만 넉넉한 여백과 함께 노출.

## 5. Tech Stack & Architecture (기술 스택)
- **Frontend**: Native iOS (SwiftUI)
- **UI Automation**: Google Stitch & Antigravity MCP (디자인 시스템 추출 및 UI 스캐폴딩)
- **Architecture Note**: 향후 앱 내부에 **온디바이스(On-device) SLM(소형 언어 모델)**을 탑재할 예정입니다. 크로스 플랫폼이 아닌 Swift 네이티브 구성을 통해 Apple의 Neural Engine(NPU)을 100% 활용하고, 자연어 처리(NLP) 추론 레이턴시를 최소화하여 매끄러운 UX를 제공하기 위함입니다.

## 6. Team Collaboration (협업 컨벤션)
빠르고 애자일한 개발을 위해 **GitHub Flow** 방식을 채택합니다.

- `main` 브랜치는 항상 실행 가능한 배포 상태를 유지합니다. (Direct Push 금지)
- 새로운 기능 개발이나 버그 수정 시 `main`에서 새로운 브랜치를 생성합니다. (예: `feature/home-ui`, `fix/routine-bug`)
- 작업 완료 시 Pull Request(PR)를 생성하여 팀원 간 코드 리뷰 진행 후 `main`에 병합(Merge)합니다.
