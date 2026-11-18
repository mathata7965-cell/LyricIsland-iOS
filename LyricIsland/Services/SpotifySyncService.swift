import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct SpotifyPlaybackSnapshot: Equatable {
    let trackId: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let progress: TimeInterval
    let isPlaying: Bool
    let artworkURL: URL?
    let capturedAt: Date
}

enum SpotifyPollResult {
    case playing(SpotifyPlaybackSnapshot)
    case nothingPlaying
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case failed(String)
}

struct SpotifyShareMetadata {
    let title: String
    let artist: String
    let artworkURL: URL?
}

@MainActor
private final class SpotifyAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        if let firstWindow = scenes.flatMap({ $0.windows }).first {
            return firstWindow
        }
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
    }
}

@MainActor
final class SpotifySyncService: ObservableObject {
    static let shared = SpotifySyncService()
    static let redirectURI = "lyricisland://spotify-callback"
    static let callbackScheme = "lyricisland"

    @Published var clientId: String = ""
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var accountDisplayName: String = ""
    @Published private(set) var lastStatusNote: String?

    private var accessToken: String = ""
    private var refreshToken: String = ""
    private var expiresAt: Date = .distantPast
    private var activeAuthSession: ASWebAuthenticationSession?
    private let authContextProvider = SpotifyAuthContextProvider()
    private var pendingCodeVerifier: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private enum Keys {
        static let clientId = "lyricisland.spotify.clientId"
        static let accessToken = "lyricisland.spotify.accessToken"
        static let refreshToken = "lyricisland.spotify.refreshToken"
        static let expiresAt = "lyricisland.spotify.expiresAt"
        static let displayName = "lyricisland.spotify.displayName"
    }

    private init() {
        let d = UserDefaults.standard
        clientId = d.string(forKey: Keys.clientId) ?? ""
        accessToken = d.string(forKey: Keys.accessToken) ?? ""
        refreshToken = d.string(forKey: Keys.refreshToken) ?? ""
        let exp = d.double(forKey: Keys.expiresAt)
        expiresAt = exp > 0 ? Date(timeIntervalSince1970: exp) : .distantPast
        accountDisplayName = d.string(forKey: Keys.displayName) ?? ""
        isConnected = !accessToken.isEmpty || !refreshToken.isEmpty
    }

    func updateClientId(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        clientId = trimmed
        UserDefaults.standard.set(trimmed, forKey: Keys.clientId)
    }

    func disconnect() {
        accessToken = ""
        refreshToken = ""
        expiresAt = .distantPast
        accountDisplayName = ""
        isConnected = false
        lastStatusNote = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.accessToken)
        d.removeObject(forKey: Keys.refreshToken)
        d.removeObject(forKey: Keys.expiresAt)
        d.removeObject(forKey: Keys.displayName)
    }

    // MARK: - PKCE OAuth Flow

    func authorize(clientId rawClientId: String) async throws {
        let cleanId = rawClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw NSError(domain: "SpotifySync", code: -1, userInfo: [NSLocalizedDescriptionKey: "請先填入 Spotify Client ID"])
        }
        updateClientId(cleanId)

        let verifier = Self.generateCodeVerifier()
        pendingCodeVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: cleanId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: "user-read-currently-playing user-read-playback-state user-modify-playback-state"),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        guard let authURL = comps.url else {
            throw NSError(domain: "SpotifySync", code: -2, userInfo: [NSLocalizedDescriptionKey: "無法建立 Spotify 授權網址"])
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] url, error in
                Task { @MainActor in
                    self?.activeAuthSession = nil
                }
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SpotifySync",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "授權流程未回傳憑證"]
                    ))
                }
            }
            authSession.presentationContextProvider = authContextProvider
            authSession.prefersEphemeralWebBrowserSession = false
            self.activeAuthSession = authSession
            authSession.start()
        }

        try await handleCallbackURL(callbackURL)
    }

    func handleCallbackURL(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            throw NSError(domain: "SpotifySync", code: -4, userInfo: [NSLocalizedDescriptionKey: "Spotify 拒絕授權：\(err)"])
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let verifier = pendingCodeVerifier else {
            throw NSError(domain: "SpotifySync", code: -5, userInfo: [NSLocalizedDescriptionKey: "缺少授權碼或驗證參數"])
        }
        pendingCodeVerifier = nil
        try await exchangeCodeForToken(code: code, verifier: verifier)
        await fetchUserProfile()
    }

    private func exchangeCodeForToken(code: String, verifier: String) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        var bodyComps = URLComponents()
        bodyComps.queryItems = bodyItems
        req.httpBody = bodyComps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Token 交換失敗"
            throw NSError(domain: "SpotifySync", code: -6, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        persistTokens(decoded)
    }

    private func refreshTokenIfNeeded(force: Bool = false) async -> Bool {
        if !force && !accessToken.isEmpty && expiresAt.timeIntervalSinceNow > 60 {
            return true
        }
        guard !refreshToken.isEmpty, !clientId.isEmpty else {
            return !accessToken.isEmpty
        }

        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var bodyComps = URLComponents()
        bodyComps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        req.httpBody = bodyComps.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if (response as? HTTPURLResponse)?.statusCode == 400 {
                    disconnect()
                }
                return false
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            persistTokens(decoded)
            return true
        } catch {
            return false
        }
    }

    private func persistTokens(_ resp: TokenResponse) {
        accessToken = resp.access_token
        if let newRefresh = resp.refresh_token, !newRefresh.isEmpty {
            refreshToken = newRefresh
        }
        expiresAt = Date().addingTimeInterval(TimeInterval(resp.expires_in))
        isConnected = true
        lastStatusNote = nil

        let d = UserDefaults.standard
        d.set(accessToken, forKey: Keys.accessToken)
        d.set(refreshToken, forKey: Keys.refreshToken)
        d.set(expiresAt.timeIntervalSince1970, forKey: Keys.expiresAt)
    }

    private func fetchUserProfile() async {
        guard await refreshTokenIfNeeded() else { return }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, response) = try? await session.data(for: req),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let profile = try? JSONDecoder().decode(SpotifyProfileResponse.self, from: data) {
            let name = profile.display_name ?? profile.id ?? "Spotify 用戶"
            accountDisplayName = name
            UserDefaults.standard.set(name, forKey: Keys.displayName)
        }
    }

    // MARK: - Playback Polling & Remote Control

    func pollCurrentlyPlaying() async -> SpotifyPollResult {
        guard isConnected else { return .unauthorized }
        guard await refreshTokenIfNeeded() else { return .unauthorized }

        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let requestStart = Date()
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("無效回應")
            }
            switch http.statusCode {
            case 204:
                return .nothingPlaying
            case 401:
                if await refreshTokenIfNeeded(force: true) {
                    return await pollCurrentlyPlayingOnce()
                }
                return .unauthorized
            case 429:
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5.0
                return .rateLimited(retryAfter: retryAfter)
            case 200:
                let decoded = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
                guard let item = decoded.item else { return .nothingPlaying }
                let rttHalf = Date().timeIntervalSince(requestStart) * 0.5
                let artists = item.artists.map(\.name).joined(separator: ", ")
                let artURL = item.album.images.first.flatMap { URL(string: $0.url) }
                let progressSec = TimeInterval(decoded.progress_ms ?? 0) / 1000.0 + (decoded.is_playing ? rttHalf : 0)
                let durationSec = max(TimeInterval(item.duration_ms) / 1000.0, 1)

                let snapshot = SpotifyPlaybackSnapshot(
                    trackId: item.id,
                    title: item.name,
                    artist: artists,
                    album: item.album.name,
                    duration: durationSec,
                    progress: min(max(progressSec, 0), durationSec),
                    isPlaying: decoded.is_playing,
                    artworkURL: artURL,
                    capturedAt: Date()
                )
                return .playing(snapshot)
            default:
                return .failed("HTTP \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func pollCurrentlyPlayingOnce() async -> SpotifyPollResult {
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failed("無效回應") }
            if http.statusCode == 204 { return .nothingPlaying }
            if http.statusCode == 401 { return .unauthorized }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            let decoded = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
            guard let item = decoded.item else { return .nothingPlaying }
            let artists = item.artists.map(\.name).joined(separator: ", ")
            let artURL = item.album.images.first.flatMap { URL(string: $0.url) }
            let durationSec = max(TimeInterval(item.duration_ms) / 1000.0, 1)
            let progressSec = TimeInterval(decoded.progress_ms ?? 0) / 1000.0
            return .playing(SpotifyPlaybackSnapshot(
                trackId: item.id,
                title: item.name,
                artist: artists,
                album: item.album.name,
                duration: durationSec,
                progress: min(max(progressSec, 0), durationSec),
                isPlaying: decoded.is_playing,
                artworkURL: artURL,
                capturedAt: Date()
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func sendPlaybackAction(_ action: String, method: String = "PUT", queryItems: [URLQueryItem] = []) async -> Bool {
        guard isConnected, await refreshTokenIfNeeded() else { return false }
        guard var comps = URLComponents(string: "https://api.spotify.com/v1/me/player/\(action)") else { return false }
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        guard let url = comps.url else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Zero-Login Spotify Share Link Resolver

    static func looksLikeSpotifyLink(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("open.spotify.com/track/")
            || lower.contains("spotify.link/")
            || lower.hasPrefix("spotify:track:")
    }

    func resolveShareLink(_ rawInput: String) async -> SpotifyShareMetadata? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetURLString: String
        if trimmed.lowercased().hasPrefix("spotify:track:") {
            let id = String(trimmed.dropFirst("spotify:track:".count))
            targetURLString = "https://open.spotify.com/track/\(id)"
        } else if let detected = Self.extractFirstURL(in: trimmed) {
            targetURLString = detected
        } else {
            return nil
        }

        guard let url = URL(string: targetURLString) else { return nil }

        // 1. Fetch open.spotify.com page (follows spotify.link redirects automatically)
        var resolvedURL = url
        var htmlTitle = ""
        var ogArtURL: URL?

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await session.data(for: req),
           let html = String(data: data, encoding: .utf8) {
            if let finalURL = response.url { resolvedURL = finalURL }
            htmlTitle = Self.extractHTMLMeta(html, pattern: #"<title>([^<]+)</title>"#) ?? ""
            if let imgStr = Self.extractHTMLMeta(html, pattern: #"<meta\s+property="og:image"\s+content="([^"]+)""#) {
                ogArtURL = URL(string: imgStr)
            }
        }

        // Parse "<Title> - song and lyrics by <Artist> | Spotify" or "<Title> - song by <Artist> | Spotify"
        if !htmlTitle.isEmpty {
            let cleanHTMLTitle = Self.decodeHTML(htmlTitle)
                .replacingOccurrences(of: " | Spotify", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let markers = [" - song and lyrics by ", " - song by ", " - Single by "]
            for marker in markers {
                if let range = cleanHTMLTitle.range(of: marker, options: .caseInsensitive) {
                    let song = String(cleanHTMLTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = String(cleanHTMLTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !song.isEmpty {
                        return SpotifyShareMetadata(title: song, artist: artist, artworkURL: ogArtURL)
                    }
                }
            }
        }

        // 2. Fallback to Spotify oEmbed JSON
        var oembedComps = URLComponents(string: "https://open.spotify.com/oembed")!
        oembedComps.queryItems = [URLQueryItem(name: "url", value: resolvedURL.absoluteString)]
        if let oembedURL = oembedComps.url,
           let (data, response) = try? await session.data(from: oembedURL),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let oembed = try? JSONDecoder().decode(SpotifyOEmbedResponse.self, from: data),
           let title = oembed.title, !title.isEmpty {
            return SpotifyShareMetadata(
                title: title,
                artist: "",
                artworkURL: oembed.thumbnail_url.flatMap { URL(string: $0) } ?? ogArtURL
            )
        }

        return nil
    }

    // MARK: - Helpers

    private static func generateCodeVerifier() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func extractFirstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.firstMatch(in: text, range: range)?.url?.absoluteString
    }

    private static func extractHTMLMeta(_ html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func decodeHTML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
}

private struct SpotifyProfileResponse: Decodable {
    let id: String?
    let display_name: String?
}

private struct CurrentlyPlayingResponse: Decodable {
    let is_playing: Bool
    let progress_ms: Int?
    let item: SpotifyTrackItem?
}

private struct SpotifyTrackItem: Decodable {
    let id: String
    let name: String
    let duration_ms: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
}

private struct SpotifyArtist: Decodable {
    let name: String
}

private struct SpotifyAlbum: Decodable {
    let name: String
    let images: [SpotifyImage]
}

private struct SpotifyImage: Decodable {
    let url: String
}

private struct SpotifyOEmbedResponse: Decodable {
    let title: String?
    let thumbnail_url: String?
}
