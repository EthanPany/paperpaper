import SwiftUI

@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()
    private init() {}
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppEnvironment = .shared
}

extension EnvironmentValues {
    var app: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
