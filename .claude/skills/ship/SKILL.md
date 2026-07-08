---
name: ship
description: Verify the build, commit, push, and open a review-ready PR, then hand the merge command to the user. Use when the user says ship, deploy, push, or create a PR.
---

# Ship

Take the current work from "done coding" to a review-ready PR. Never merge — the
user always merges manually (a guard protects main).

## Steps

1. **Verify the build.** Run:
   `xcodebuild -project ADHD/ADHD.xcodeproj -scheme ADHD -destination 'platform=iOS Simulator,name=iPhone 17' build`
   If it fails, fix the errors and rebuild before proceeding. Report failures
   honestly with the actual error output.
2. **Review the diff.** Check `git status` and `git diff` — confirm only intended
   changes are included. Never stage `*.xcuserstate`, `.DS_Store`, or scratch files.
3. **Branch check.** If on main, create a `feat/...` or `fix/...` branch first.
4. **Commit** with a Korean imperative message describing what changed and why.
5. **Push and open the PR** against main with `gh pr create`. PR body covers: what
   changed, why, and how it was verified (build result, tests run).
6. **Stop.** Print the PR link and the exact merge command for the user:
   `gh pr merge <N> --squash --delete-branch`
   Do NOT run the merge. Do NOT poll CI — report the link once and end the turn.
