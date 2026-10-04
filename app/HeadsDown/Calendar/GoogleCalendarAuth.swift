import AppKit
import CryptoKit
import Foundation
import Network

enum CalendarAuthError: LocalizedError, Equatable {
    case notConfigured
    case timedOut
    case denied(String)
    case scopeNotGranted
    case noRefreshToken
    case exchangeFailed(Int)
    case invalidGrant
    case notConnected
    case network

    /// Category text only: no codes, tokens, or response bodies.
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "add GOOGLE_OAUTH_CLIENT_ID to .env (see README)"
        case .timedOut: return "sign-in wasn't completed in time"
        case .denied(let reason): return "Google sign-in was not completed (\(reason))"
        case .scopeNotGranted: return "calendar read access wasn't granted"
        case .noRefreshToken: return "Google didn't return a long-lived grant; disconnect and connect again"
        case .exchangeFailed(let status): return "Google rejected the sign-in (HTTP \(status))"
        case .invalidGrant: return "access was revoked or expired; connect again"
        case .notConnected: return "not connected"
        case .network: return "network unavailable"
        }
    }
}

/// Google OAuth for an installed desktop app: authorization code + PKCE (S256) in the system
/// browser, received on a short-lived loopback listener bound to 127.0.0.1 only.
///
/// Read-only Calendar scope. The refresh token lives in the Keychain; access tokens stay in memory.
/// Refreshes are serialized (one in flight). The client secret Google issues to desktop clients is
/// sent when configured, but it isn't a secret in a distributed app and isn't treated as one.
actor GoogleCalendarAuth {
    static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"
    static let authorizationTimeout: TimeInterval = 180
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    private static let grantAccount = "refresh-grant"

    private struct StoredGrant: Codable {
        var refreshToken: String
        var scope: String
        var grantedAt: Date
    }

    private struct TokenResponse {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
        let scope: String?
    }

    static var clientID: String? { EnvFile.value("GOOGLE_OAUTH_CLIENT_ID") }
    private static var clientSecret: String? { EnvFile.value("GOOGLE_OAUTH_CLIENT_SECRET") }

    nonisolated static var hasStoredGrant: Bool { KeychainStore.read(grantAccount) != nil }

    private var accessToken: (value: String, expires: Date)?
    private var refreshTask: Task<String, Error>?
    private var receiver: LoopbackReceiver?

    // MARK: - Authorization

    /// Opens the system browser and waits for the loopback callback, then stores the grant.
    func authorize() async throws {
        guard let clientID = Self.clientID else { throw CalendarAuthError.notConfigured }
        receiver?.stop()
        let verifier = Self.randomURLSafe(bytes: 48)
        let state = Self.randomURLSafe(bytes: 24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded

        let receiver = try LoopbackReceiver(expectedState: state)
        self.receiver = receiver
        defer {
            receiver.stop()
            if self.receiver === receiver { self.receiver = nil }
        }
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: Self.authEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw CalendarAuthError.notConfigured }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }

        let params = try await receiver.waitForCallback(timeout: Self.authorizationTimeout)
        if let error = params["error"] { throw CalendarAuthError.denied(error == "access_denied" ? "declined" : "error") }
        guard let code = params["code"] else { throw CalendarAuthError.denied("no code") }

        // Same redirect URI as the authorization request.
        var form = [
            "code": code, "client_id": clientID, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ]
        if let secret = Self.clientSecret { form["client_secret"] = secret }
        let response = try await postToken(form)
        if let granted = response.scope, !granted.split(separator: " ").contains(Substring(Self.scope)) {
            throw CalendarAuthError.scopeNotGranted
        }
        // A response without a refresh token must not erase an earlier valid one.
        guard let refresh = response.refreshToken ?? storedGrant()?.refreshToken else {
            throw CalendarAuthError.noRefreshToken
        }
        saveGrant(StoredGrant(refreshToken: refresh, scope: response.scope ?? Self.scope, grantedAt: Date()))
        accessToken = (response.accessToken, Date().addingTimeInterval(response.expiresIn))
    }

    func cancelAuthorization() {
        receiver?.stop()
        receiver = nil
    }

    // MARK: - Tokens

    /// A valid access token, refreshing at most once at a time.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = accessToken, token.expires > Date().addingTimeInterval(60) {
            return token.value
        }
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let clientID = Self.clientID else { throw CalendarAuthError.notConfigured }
        guard let grant = storedGrant() else { throw CalendarAuthError.notConnected }
        var form = ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": grant.refreshToken]
        if let secret = Self.clientSecret { form["client_secret"] = secret }
        let response: TokenResponse
        do {
            response = try await postToken(form)
        } catch CalendarAuthError.invalidGrant {
            // Revoked or expired (e.g. 7-day limit while the consent screen is in Testing): useless now.
            KeychainStore.delete(Self.grantAccount)
            accessToken = nil
            throw CalendarAuthError.invalidGrant
        }
        if let rotated = response.refreshToken {
            saveGrant(StoredGrant(refreshToken: rotated, scope: grant.scope, grantedAt: grant.grantedAt))
        }
        accessToken = (response.accessToken, Date().addingTimeInterval(response.expiresIn))
        return response.accessToken
    }

    /// Removes local authorization first, then asks Google to revoke it (best effort). A failed
    /// revocation never leaves the token stored.
    func disconnect() async {
        receiver?.stop()
        receiver = nil
        refreshTask?.cancel()
        refreshTask = nil
        let token = storedGrant()?.refreshToken
        KeychainStore.delete(Self.grantAccount)
        accessToken = nil
        guard let token, let url = URL(string: Self.revokeEndpoint) else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

    private func postToken(_ form: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else { throw CalendarAuthError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CalendarAuthError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            if json["error"] as? String == "invalid_grant" { throw CalendarAuthError.invalidGrant }
            throw CalendarAuthError.exchangeFailed(status)
        }
        guard let access = json["access_token"] as? String else { throw CalendarAuthError.exchangeFailed(status) }
        return TokenResponse(
            accessToken: access, expiresIn: (json["expires_in"] as? Double) ?? 3000,
            refreshToken: json["refresh_token"] as? String, scope: json["scope"] as? String)
    }

    private func storedGrant() -> StoredGrant? {
        KeychainStore.read(Self.grantAccount).flatMap { try? JSONDecoder().decode(StoredGrant.self, from: $0) }
    }

    private func saveGrant(_ grant: StoredGrant) {
        if let data = try? JSONEncoder().encode(grant) { KeychainStore.write(data, account: Self.grantAccount) }
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Secure random bytes unavailable")
        return Data(bytes).base64URLEncoded
    }

    private static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 (OS-chosen port) for the OAuth redirect. Accepts only
/// `GET /?…` with the expected state; anything else gets an error page and is ignored. Times out
/// and shuts down after the first valid callback.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HeadsDown.oauth-loopback")
    private let expectedState: String
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var stopped = false

    init(expectedState: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        self.expectedState = expectedState
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result {
                    continuation.resume(with: result)
                    return
                }
                waiter = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(CalendarAuthError.timedOut))
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            finish(.failure(CalendarAuthError.denied("cancelled")))
            ready?.resume(throwing: CalendarAuthError.denied("cancelled"))
            ready = nil
            stopped = true
            listener.cancel()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                ready?.resume(returning: port)
                ready = nil
            }
        case .failed:
            ready?.resume(throwing: CalendarAuthError.network)
            ready = nil
            finish(.failure(CalendarAuthError.network))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let components = URLComponents(string: "http://127.0.0.1\(parts[1])"), components.path == "/"
            else {
                self.respond(connection, status: "404 Not Found", body: "Not found.")
                return
            }
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
            guard params["state"] == self.expectedState else {
                self.respond(connection, status: "400 Bad Request", body: "Unexpected request.")
                return
            }
            let ok = params["code"] != nil
            self.respond(connection, status: "200 OK", body: ok
                ? "Heads Down is connected to Google Calendar. You can close this tab."
                : "Google Calendar was not connected. You can close this tab.")
            self.finish(.success(params))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Heads Down</title><p>\(body)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
        if case .success = outcome {
            stopped = true
            listener.cancel()
        }
    }
}
