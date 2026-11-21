import Foundation

/// One text turn of a conversation with Claude.
struct ChatTurn: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String

    init(_ role: Role, _ text: String, id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// What a streamed answer produces, in order.
enum ClaudeEvent: Equatable, Sendable {
    /// More answer text.
    case textDelta(String)
    /// The requested model declined and the API continued on another model (informational).
    case fallback(from: String, to: String)
    /// Claude declined to answer. Any text already streamed must be discarded.
    case refusal(category: String?, explanation: String?)
    /// The answer is complete.
    case done(stopReason: String?)
}

/// Failures, with messages fit to show the user. Never contains the API key.
enum ClaudeError: LocalizedError, Equatable {
    case invalidKey
    case billing
    case permission(String)
    case rateLimited(retryAfter: TimeInterval?)
    case spendLimit
    case overloaded
    case server(Int)
    case badRequest(String)
    case offline
    case timedOut
    case network(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Anthropic didn't accept the API key. Check it in Settings › Ask Claude (keys start with “sk-ant-”)."
        case .billing:
            return "Anthropic reported a billing problem for this API key. Check the account's plan and credits in the Claude Console."
        case .permission(let message):
            return "This API key isn't allowed to make that request." + (message.isEmpty ? "" : " (\(message))")
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Too many requests right now. Try again in about \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "Too many requests right now. Try again in a moment."
        case .spendLimit:
            return "This API key's account has reached its monthly spend limit. Raise it in the Claude Console to keep asking."
        case .overloaded:
            return "Claude is busy right now (overloaded). Try again in a moment."
        case .server(let code):
            return "Anthropic's service had a problem (HTTP \(code)). Try again in a moment."
        case .badRequest(let message):
            return "The request was rejected: \(message)"
        case .offline:
            return "You're offline. Ask Claude needs an internet connection."
        case .timedOut:
            return "Claude took too long to respond. Try again."
        case .network(let message):
            return "Couldn't reach Anthropic: \(message)"
        case .malformedResponse:
            return "The answer from Claude ended unexpectedly. Try again."
        }
    }

    /// Worth one automatic retry (rate limits, overloads, server errors, dropped connections).
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .timedOut, .network: return true
        default: return false
        }
    }
}

/// Minimal client for the Claude Messages API over HTTPS (Swift has no official Anthropic SDK).
/// Streams one answer at a time. The API key is sent only in the `x-api-key` header.
struct ClaudeClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-opus-5-5"
    static let apiVersion = "2026-10-21"
    /// Opts in to server-side fallbacks: if the model declines on policy grounds, the API retries
    /// on Anthropic's recommended model for that refusal category instead of just stopping.
    static let betaHeader = "server-side-fallback-2026-07-01"
    static let maxTokens = 16_000

    private let apiKey: String
    private let session: URLSession
    var maxRetries = 1
    var timeout: TimeInterval = 90
    /// Waits before a retry; replaced in tests.
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Request

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct OutputConfig: Encodable { let effort: String }
        let model: String
        let maxTokens: Int
        let stream: Bool
        let system: String
        let messages: [Message]
        let outputConfig: OutputConfig
        let fallbacks: String

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    /// Thinking is left out on purpose: Claude Opus 5.5 always thinks adaptively, and effort
    /// "low" keeps chat answers quick. No sampling parameters (rejected on this API version).
    func makeRequest(system: String, messages: [ChatTurn]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let body = Body(model: Self.model, maxTokens: Self.maxTokens, stream: true, system: system,
                        messages: messages.map { .init(role: $0.role.rawValue, content: $0.text) },
                        outputConfig: .init(effort: "low"), fallbacks: "default")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: Streaming

    func stream(system: String, messages: [ChatTurn]) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages)
                    var attempt = 0
                    while true {
                        var yielded = false
                        do {
                            try await run(request) { event in
                                yielded = true
                                continuation.yield(event)
                            }
                            continuation.finish()
                            return
                        } catch let error as ClaudeError where error.isRetryable && !yielded && attempt < maxRetries {
                            attempt += 1
                            try await sleep(Self.retryDelay(for: error, attempt: attempt))
                        }
                    }
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func retryDelay(for error: ClaudeError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter?) = error { return min(max(retryAfter, 0), 20) }
        return min(1.5 * pow(2, Double(attempt - 1)), 10)
    }

    private func run(_ request: URLRequest, emit: (ClaudeEvent) -> Void) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.mapTransport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.malformedResponse }
        guard http.statusCode == 200 else {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 64 * 1024 { break }
                }
            } catch {
                // Status code is enough to classify the failure.
            }
            throw Self.mapStatus(http.statusCode, body: body,
                                 retryAfter: http.value(forHTTPHeaderField: "retry-after"))
        }
        var parser = SSEParser()
        var line: [UInt8] = []
        line.reserveCapacity(512)
        do {
            for try await byte in bytes {
                if byte == 0x0A {
                    try parser.consume(line: Self.decodeLine(line), emit: emit)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw Self.mapTransport(error)
        }
        if !line.isEmpty { try parser.consume(line: Self.decodeLine(line), emit: emit) }
        try parser.finish(emit: emit)
    }

    /// Lines are collected as bytes and decoded once complete, so a multi-byte character split
    /// across network chunks is never mangled.
    static func decodeLine(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        if slice.last == 0x0D { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }

    static func mapTransport(_ error: Error) -> Error {
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else { return ClaudeError.network(error.localizedDescription) }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return ClaudeError.offline
        case .timedOut: return ClaudeError.timedOut
        default: return ClaudeError.network(urlError.localizedDescription)
        }
    }

    static func mapStatus(_ status: Int, body: Data, retryAfter: String?) -> ClaudeError {
        let info = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = info?["error"] as? [String: Any]
        let message = (error?["message"] as? String) ?? ""
        let details = error?["details"] as? [String: Any]
        switch status {
        case 401: return .invalidKey
        case 402: return .billing
        case 403: return .permission(message)
        case 429:
            if details?["error_code"] as? String == "enforced_spend_limit_reached" { return .spendLimit }
            return .rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 529: return .overloaded
        case 500...599: return .server(status)
        default: return .badRequest(message.isEmpty ? "HTTP \(status)" : message)
        }
    }
}

/// Parses the Messages API's server-sent events. Each `data:` line carries one JSON event
/// whose `type` says what it is; `event:` lines, comments and pings carry nothing extra.
struct SSEParser {
    private var pendingData = ""
    private(set) var stopReason: String?
    private var refusalCategory: String?
    private var refusalExplanation: String?
    private(set) var finished = false

    mutating func consume(line: String, emit: (ClaudeEvent) -> Void) throws {
        if line.isEmpty { pendingData = ""; return }           // event boundary
        guard line.hasPrefix("data:") else { return }          // event:, id:, retry:, ": comment"
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        // Tolerate an event split over several data: lines (allowed by SSE, unusual here).
        let candidate = pendingData.isEmpty ? String(payload) : pendingData + "\n" + payload
        guard let data = candidate.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            pendingData = candidate
            if pendingData.utf8.count > 1_000_000 { throw ClaudeError.malformedResponse }
            return
        }
        pendingData = ""
        try handle(object, emit: emit)
    }

    private mutating func handle(_ event: [String: Any], emit: (ClaudeEvent) -> Void) throws {
        switch event["type"] as? String {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { return }
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { emit(.textDelta(text)) }
            case "fallback":
                let from = (block["from"] as? [String: Any])?["model"] as? String ?? ""
                let to = (block["to"] as? [String: Any])?["model"] as? String ?? ""
                emit(.fallback(from: from, to: to))
            default:
                break // thinking blocks and anything newer are not shown
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                emit(.textDelta(text))
            }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            if let reason = delta?["stop_reason"] as? String { stopReason = reason }
            if let details = (delta?["stop_details"] ?? event["stop_details"]) as? [String: Any] {
                refusalCategory = details["category"] as? String
                refusalExplanation = details["explanation"] as? String
            }
        case "message_stop":
            try finish(emit: emit)
        case "error":
            let error = event["error"] as? [String: Any]
            let type = error?["type"] as? String ?? ""
            let message = error?["message"] as? String ?? ""
            switch type {
            case "overloaded_error": throw ClaudeError.overloaded
            case "rate_limit_error": throw ClaudeError.rateLimited(retryAfter: nil)
            case "api_error": throw ClaudeError.server(500)
            case "authentication_error": throw ClaudeError.invalidKey
            default: throw ClaudeError.badRequest(message.isEmpty ? type : message)
            }
        default:
            break // message_start, content_block_stop, ping
        }
    }

    /// Ends the answer. A stream that stops before `message_stop` and without a stop reason is truncated.
    mutating func finish(emit: (ClaudeEvent) -> Void) throws {
        guard !finished else { return }
        guard stopReason != nil else { throw ClaudeError.malformedResponse }
        finished = true
        if stopReason == "refusal" {
            emit(.refusal(category: refusalCategory, explanation: refusalExplanation))
        }
        emit(.done(stopReason: stopReason))
    }
}
