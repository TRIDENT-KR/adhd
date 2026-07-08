## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken" → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design review, visual audit, design polish → invoke plan-design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health

Only route to a skill that actually appears in the available-skills list. If a
routed skill does not exist, say so briefly and handle the task directly instead
of failing or guessing.

## Build & Run

- This is a native iOS Swift/SwiftUI app (NOT React Native). Main app code lives in
  `ADHD/`, the widget in `ADHD/ADHDWidget/`, and Supabase Edge Functions in `supabase/`.
- When asked to build or run, execute directly without refusing. Standard build:
  `xcodebuild -project ADHD/ADHD.xcodeproj -scheme ADHD -destination 'platform=iOS Simulator,name=iPhone 17' build`
  If the named simulator doesn't exist, check `xcrun simctl list devices available`
  and pick a current one rather than failing.
- Install and launch on the simulator with `xcrun simctl`.
- Only pause for destructive steps or steps requiring credentials (provisioning
  profiles, App Store Connect, Supabase deploy secrets).

## Git & PR Workflow

- A guard protects main: NEVER attempt a programmatic force-push or merge to main.
  Finish the work, open the PR with `gh pr create`, then hand the merge back to the
  user with the exact command to run (e.g. `gh pr merge <N> --squash --delete-branch`).
- Do not poll CI in a loop. Push, report the PR link once, and stop — the user
  checks CI on GitHub themselves.
- Branches are named `feat/...` or `fix/...`. Commit messages are written in Korean.
- Never commit `*.xcuserstate` or other Xcode user-state files.

## Design Work

- `DESIGN.md` is the design source of truth ("Soft Minimalism for Cognitive Ease").
  Read and apply it BEFORE any design or redesign work — especially the No-Line rule
  (no 1px borders), the terracotta/warm-paper palette, and the single-focus-point
  hierarchy.
- Legibility comes first: readable type sizes, sufficient contrast, one clear focus
  point per screen. A structurally correct but hard-to-read screen is a failed result.
- All user-facing copy is Korean. Write natural, human-sounding Korean — never
  translated-sounding or AI-sounding phrasing. Match the calm, non-pressuring tone
  of an ADHD support app.
- Mockups and production code are separate deliverables: only modify production
  Swift code when explicitly told to; otherwise present the design as a mockup first.

## Estimates & Audits

- Base all measurements, estimates, and audits on the actual local codebase — not on
  Notion documents, which may be outdated.
- If given placeholder or template values, ask for the real data before producing
  any numbers. Never fabricate figures.
