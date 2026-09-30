import Foundation
import Supabase

struct SupabaseConfig {
    /// Each request uses the initiating account's token, even if the shared auth session changes.
    static func requestClient(accessToken: String, session: URLSession = .shared) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storageKey: "mora-fixed-request-session",
                    autoRefreshToken: false,
                    accessToken: { accessToken }
                ),
                global: .init(session: session)
            )
        )
    }

    static let url: URL = {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let urlString = dict["SUPABASE_URL"] as? String,
              let url = URL(string: urlString) else {
            return URL(string: "https://example.supabase.co")!
        }
        return url
    }()
    
    static let anonKey: String = {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["SUPABASE_ANON_KEY"] as? String else {
            return ""
        }
        return key
    }()
}

let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.anonKey,
    options: SupabaseClientOptions(
        auth: .init(emitLocalSessionAsInitialSession: true)
    )
)
