#!/usr/bin/env python3
"""Run the production Foundation analysis core on macOS without CoreSimulator.

Copies verbatim, anchored sections (no reimplemented parser/validator/router) and
the same Swift Testing suites into a temporary package, including the AlarmKit
registration queue (without calling AlarmKit). Does not test SwiftUI,
SwiftData execution, Speech hardware, or the Supabase transport. Xcode remains
the integration check. All generated files stay in the supplied scratch folder.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
scratch = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/mora-analysis-core-tests")
scratch.mkdir(parents=True, exist_ok=True)
sources = {}


def read(path):
    value = (root / path).read_text()
    sources[path] = hashlib.sha256(value.encode()).hexdigest()
    return value


def section(value, start, end):
    assert value.count(start) == 1, start
    assert value.count(end) == 1, end
    return value.split(start, 1)[1].split(end, 1)[0]


calls = read("ADHD/Functions/LLMFunctionCall.swift")
preferences = read("ADHD/NotificationManager.swift")
cloud = read("ADHD/CloudLLMManager.swift")
subscription = read("ADHD/SubscriptionManager.swift")
router = read("ADHD/TaskAnalysisRouter.swift")
tests = read("ADHD/ADHDTests/TaskAnalysisTests.swift")
alarm = read("ADHD/SystemAlarmScheduler.swift")
queue_tests = read("ADHD/ADHDTests/SaveAndRetryContractTests.swift")
limit = next(line.strip() for line in subscription.splitlines() if "static let freeAILimit =" in line)
core = "import Foundation\nimport CryptoKit\n"
core += section(calls, "// MARK: - Parameter Structs", "// MARK: - UI Helpers for Confirmation Card")
core += "enum AccountPreferenceKey" + section(preferences, "enum AccountPreferenceKey", "// MARK: - NotificationManager")
core += preferences[preferences.index("enum AIDataConsent {"):]
core += "struct ServerAIQuotaSnapshot" + section(cloud, "struct ServerAIQuotaSnapshot", "private struct AnalyzeTaskResponse")
core += "enum CloudLLMError" + section(cloud, "enum CloudLLMError", "class CloudLLMManager")
core += "enum SubscriptionManager { " + limit + " }\n"
core += "enum CloudLLMManager {\n    static func makeAnalyzePayload" + section(cloud, "    static func makeAnalyzePayload", "    func shouldRetry") + "}\n"
core += router
core += "@MainActor\nfinal class AlarmRegistrationQueue" + section(alarm, "@MainActor\nfinal class AlarmRegistrationQueue", "// MARK: - System Alarm Scheduler")
pure_tests = tests.split("@MainActor\nstruct AnalysisExecutionBoundaryTests", 1)[0]
pure_tests = pure_tests.replace("import SwiftData\n", "").replace("@testable import ADHD", "@testable import AnalysisCore")
validation_start = '    @Test(arguments: ["25:00"'
validation_end = "    @Test func duplicateTargetsRequireSelectionAndSelectedSnapshotCanBecomeStale"
assert tests.count(validation_start) == tests.count(validation_end) == 1
pure_tests += "\n@MainActor\nstruct AnalysisValidationTests {\n"
pure_tests += tests[tests.index(validation_start):tests.index(validation_end)] + "}\n"

pure_tests += "\n@MainActor\nstruct AlarmRegistrationQueueTests" + queue_tests.split("@MainActor\nstruct AlarmRegistrationQueueTests", 1)[1]

(scratch / "Sources/AnalysisCore").mkdir(parents=True, exist_ok=True)
(scratch / "Tests/AnalysisCoreTests").mkdir(parents=True, exist_ok=True)
(scratch / "Sources/AnalysisCore/Core.swift").write_text(core)
(scratch / "Tests/AnalysisCoreTests/CoreTests.swift").write_text(pure_tests)
(scratch / "source-hashes.json").write_text(json.dumps(sources, indent=2) + "\n")
(scratch / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MoraAnalysisCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "AnalysisCore", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "AnalysisCoreTests", dependencies: ["AnalysisCore"])
], swiftLanguageModes: [.v5])
''')
print("Testing production source hashes:", json.dumps(sources), flush=True)
sys.exit(subprocess.call(["swift", "test", "--jobs", "1", "--package-path", str(scratch), "--scratch-path", str(scratch / ".build")]))
