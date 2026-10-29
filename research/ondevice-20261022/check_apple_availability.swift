// Read-only capability check on the executing host. Does not enable Apple
// Intelligence, request a download, or prove availability on any other device.
import Foundation
import FoundationModels

let model = SystemLanguageModel.default
print("availability: \(model.availability)")
for code in ["ko", "en", "ja"] {
    print("\(code): \(model.supportsLocale(Locale(identifier: code)))")
}
