import AppKit
import Foundation
import Network

struct OnShapeOAuthToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    /// Unix timestamp (seconds).
    let expiresAt: Double?

    static func load(from url: URL) -> OnShapeOAuthToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OnShapeOAuthToken.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

enum OnShapeOAuthError: Error, LocalizedError {
    case invalidOAuthURL
    case callbackFailed(String)
    case invalidTokenResponse
    case missingClientConfig
    case listenerFailed

    var errorDescription: String? {
        switch self {
        case .invalidOAuthURL:
            return "Invalid OAuth URL"
        case .callbackFailed(let detail):
            return detail
        case .invalidTokenResponse:
            return "Invalid OAuth token response"
        case .missingClientConfig:
            return "Missing OAuth client id/secret"
        case .listenerFailed:
            return "Failed to start OAuth callback listener"
        }
    }
}

actor OnShapeOAuthService {
    static let shared = OnShapeOAuthService()

    private var listener: NWListener?
    private var expectedState: String?

    static func defaultTokenFileURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("BetterSiri", isDirectory: true)
            .appendingPathComponent("OnShape", isDirectory: true)
            .appendingPathComponent("oauth_token.json", isDirectory: false)
    }

    func clearTokenFile() throws {
        let url = Self.defaultTokenFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func authorize(
        oauthBaseURL: String,
        clientId: String,
        clientSecret: String,
        redirectPort: Int,
        scopes: [String],
        tokenFileURL: URL
    ) async throws {
        let trimmedId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedId.isEmpty || trimmedSecret.isEmpty {
            throw OnShapeOAuthError.missingClientConfig
        }

        let state = UUID().uuidString
        expectedState = state

        let redirectURI = "http://localhost:\(redirectPort)/token"
        let scope = scopes.joined(separator: " ")

        guard let base = URL(string: oauthBaseURL) else { throw OnShapeOAuthError.invalidOAuthURL }
        let authorizeURL = base.appendingPathComponent("oauth/authorize")

        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: trimmedId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = comps?.url else { throw OnShapeOAuthError.invalidOAuthURL }

        async let waitCode: String = startCallbackListenerAndWait(port: redirectPort, expectedState: state)

        defer {
            stopListener()
        }

        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }

        let code = try await waitCode

        try await exchangeAuthorizationCode(
            oauthBaseURL: oauthBaseURL,
            clientId: trimmedId,
            clientSecret: trimmedSecret,
            code: code,
            redirectURI: redirectURI,
            tokenFileURL: tokenFileURL
        )
    }

    private func startCallbackListenerAndWait(port: Int, expectedState: String) async throws -> String {
        stopListener()

        AppLog.shared.log("Starting OAuth callback listener on port \(port)", level: .info)
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        guard let nwPort else { throw OnShapeOAuthError.listenerFailed }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            AppLog.shared.log("Failed to create NWListener on port \(port): \(error)", level: .error)
            throw error
        }
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            final class ContinuationState: @unchecked Sendable {
                private var continuation: CheckedContinuation<String, Error>?
                private let lock = NSLock()

                init(continuation: CheckedContinuation<String, Error>) {
                    self.continuation = continuation
                }

                func resume(returning value: String) {
                    lock.lock()
                    defer { lock.unlock() }
                    continuation?.resume(returning: value)
                    continuation = nil
                }

                func resume(throwing error: Error) {
                    lock.lock()
                    defer { lock.unlock() }
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }

            let state = ContinuationState(continuation: cont)

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                    if let error {
                        state.resume(throwing: error)
                        return
                    }
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        state.resume(throwing: OnShapeOAuthError.callbackFailed("Empty callback request"))
                        return
                    }
                    let (code, stateCode, errorText) = Self.parseOAuthCallbackRequest(request)

                    let body: String
                    let status: String
                    if let code, let stateCode, stateCode == expectedState {
                        status = "HTTP/1.1 200 OK"
                        body = "<html><body><h3>OnShape authorized</h3><p>You can close this window.</p></body></html>"
                        let response = "\(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        state.resume(returning: code)
                    } else {
                        status = "HTTP/1.1 400 Bad Request"
                        let msg = errorText ?? "Invalid callback"
                        body = "<html><body><h3>OnShape authorization failed</h3><pre>\(msg)</pre></body></html>"
                        let response = "\(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        state.resume(throwing: OnShapeOAuthError.callbackFailed(msg))
                    }
                }
            }

            listener.stateUpdateHandler = { newState in
                switch newState {
                case .failed(let err):
                    state.resume(throwing: err)
                case .cancelled:
                    state.resume(throwing: OnShapeOAuthError.listenerFailed)
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    nonisolated private static func parseOAuthCallbackRequest(_ request: String) -> (String?, String?, String?) {
        // Expect: GET /token?code=...&state=... HTTP/1.1
        guard let firstLine = request.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return (nil, nil, "Missing request line")
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return (nil, nil, "Invalid request line") }
        let pathPart = String(parts[1])
        guard let url = URL(string: "http://localhost\(pathPart)"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil, "Invalid callback URL")
        }

        if comps.path != "/token" {
            return (nil, nil, "Unexpected callback path: \(comps.path)")
        }

        let items = comps.queryItems ?? []
        let code = items.first(where: { $0.name == "code" })?.value
        let state = items.first(where: { $0.name == "state" })?.value
        let error = items.first(where: { $0.name == "error" })?.value
        let errorDesc = items.first(where: { $0.name == "error_description" })?.value

        if let error {
            return (nil, nil, "\(error): \(errorDesc ?? "")")
        }
        return (code, state, nil)
    }

    private func exchangeAuthorizationCode(
        oauthBaseURL: String,
        clientId: String,
        clientSecret: String,
        code: String,
        redirectURI: String,
        tokenFileURL: URL
    ) async throws {
        func exchange(at tokenURL: URL) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var comps = URLComponents()
            comps.queryItems = [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "client_secret", value: clientSecret),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
            ]
            req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OnShapeOAuthError.invalidTokenResponse }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw OnShapeOAuthError.callbackFailed("Token exchange failed at \(tokenURL.absoluteString) (\(http.statusCode)): \(text)")
            }
            return (data, http)
        }

        guard let base = URL(string: oauthBaseURL) else { throw OnShapeOAuthError.invalidOAuthURL }
        let primaryTokenURL = base.appendingPathComponent("oauth/token")
        let fallbackTokenURL = URL(string: "https://oauth.onshape.com/oauth/token")

        let data: Data
        do {
            (data, _) = try await exchange(at: primaryTokenURL)
        } catch {
            if let fallbackTokenURL, fallbackTokenURL != primaryTokenURL {
                (data, _) = try await exchange(at: fallbackTokenURL)
            } else {
                throw error
            }
        }

        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = json as? [String: Any] else { throw OnShapeOAuthError.invalidTokenResponse }
        guard let accessToken = obj["access_token"] as? String else { throw OnShapeOAuthError.invalidTokenResponse }
        let refreshToken = obj["refresh_token"] as? String
        let tokenType = obj["token_type"] as? String
        let scope = obj["scope"] as? String

        var expiresAt: Double? = nil
        if let expiresIn = obj["expires_in"] as? Double {
            expiresAt = Date().timeIntervalSince1970 + expiresIn
        }

        let token = OnShapeOAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            scope: scope,
            expiresAt: expiresAt
        )

        try token.save(to: tokenFileURL)
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        expectedState = nil
    }
}
