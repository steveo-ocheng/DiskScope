import Foundation
import Security
import Testing
@testable import DiskScope

// MARK: - Test doubles

/// Serves canned HTTP replies to URLSessions made by `session(_:)`; no real network is ever used.
/// Replies are routed by a per-session header so tests can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["content-type": "text/event-stream"]
        var chunks: [Data] = []
        var failure: URLError?
    }
    struct Seen { let request: URLRequest; let body: Data }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]
    static let routeHeader = "X-Stub-Route"

    static func session(_ replies: [Reply]) -> (URLSession, String) {
        let id = UUID().uuidString
        lock.withLock { self.replies[id] = replies }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [routeHeader: id]
        return (URLSession(configuration: config), id)
    }

    static func requests(_ id: String) -> [Seen] { lock.withLock { seen[id] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.routeHeader) ?? ""
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        let reply: Reply? = Self.lock.withLock {
            Self.seen[id, default: []].append(Seen(request: request, body: body))
            guard var queue = Self.replies[id], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            Self.replies[id] = queue
            return next
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

/// SSE text for a sequence of (event, JSON object) pairs.
private func sse(_ events: [(String, [String: Any])], extraLines: [String] = []) -> String {
    var out = extraLines.map { $0 + "\n" }.joined()
    for (name, object) in events {
        let json = String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        out += "event: \(name)\ndata: \(json)\n\n"
    }
    return out
}

private func textEvents(_ parts: [String], stop: String = "end_turn", stopDetails: [String: Any]? = nil) -> [(String, [String: Any])] {
    var events: [(String, [String: Any])] = [
        ("message_start", ["type": "message_start", "message": ["id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": []]]),
        ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]),
    ]
    for p in parts {
        events.append(("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": p]]))
    }
    events.append(("content_block_stop", ["type": "content_block_stop", "index": 0]))
    var delta: [String: Any] = ["stop_reason": stop]
    if let stopDetails { delta["stop_details"] = stopDetails }
    events.append(("message_delta", ["type": "message_delta", "delta": delta, "usage": ["output_tokens": 12]]))
    events.append(("message_stop", ["type": "message_stop"]))
    return events
}

private func ok(_ body: String, chunkSize: Int? = nil) -> StubURLProtocol.Reply {
    let data = Data(body.utf8)
    guard let chunkSize else { return .init(chunks: [data]) }
    let chunks = stride(from: 0, to: data.count, by: chunkSize).map { data.subdata(in: $0..<min($0 + chunkSize, data.count)) }
    return .init(chunks: chunks)
}

private func errorReply(_ status: Int, type: String, message: String = "x", headers: [String: String] = [:],
                        details: [String: Any]? = nil) -> StubURLProtocol.Reply {
    var error: [String: Any] = ["type": type, "message": message]
    if let details { error["details"] = details }
    let body = try! JSONSerialization.data(withJSONObject: ["type": "error", "error": error])
    return .init(status: status, headers: headers.merging(["content-type": "application/json"]) { a, _ in a }, chunks: [body])
}

/// Records retry waits instead of sleeping.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [TimeInterval] = []
    var all: [TimeInterval] { lock.withLock { waits } }
    var sleeper: @Sendable (TimeInterval) async throws -> Void { { [self] t in lock.withLock { waits.append(t) } } }
}

private let testKey = "sk-ant-api03-TESTKEY_abcdefghijklmnopqrstuvwxyz0123456789"

private func client(_ replies: [StubURLProtocol.Reply]) -> (ClaudeClient, String, SleepLog) {
    let (session, id) = StubURLProtocol.session(replies)
    var c = ClaudeClient(apiKey: testKey, session: session)
    let log = SleepLog()
    c.sleep = log.sleeper
    return (c, id, log)
}

private func collect(_ c: ClaudeClient, _ messages: [ChatTurn] = [ChatTurn(.user, "hi")]) async throws -> [ClaudeEvent] {
    var events: [ClaudeEvent] = []
    for try await e in c.stream(system: "sys", messages: messages) { events.append(e) }
    return events
}

private func text(_ events: [ClaudeEvent]) -> String {
    events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
}

// MARK: - Client

@Suite("Ask Claude · API client")
struct ClaudeClientTests {
    @Test func requestMatchesTheMessagesAPI() throws {
        let c = ClaudeClient(apiKey: testKey)
        let req = try c.makeRequest(system: "You help.", messages: [ChatTurn(.user, "Q1"), ChatTurn(.assistant, "A1"), ChatTurn(.user, "Q2")])
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == testKey)
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(req.timeoutInterval > 0)

        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["max_tokens"] as? Int == 16_000)
        #expect(json["stream"] as? Bool == true)
        #expect(json["system"] as? String == "You help.")
        #expect(json["fallbacks"] as? String == "default")
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(messages.map { $0["content"] as? String } == ["Q1", "A1", "Q2"])
        // Thinking is left to the model's default; no sampling parameters.
        for absent in ["thinking", "temperature", "top_p", "top_k"] { #expect(json[absent] == nil) }
        // The key travels only in its header.
        #expect(!String(decoding: body, as: UTF8.self).contains("sk-ant"))
        #expect(!(req.url?.absoluteString.contains("sk-ant") ?? true))
        let otherHeaders = (req.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != "x-api-key" }
        #expect(!otherHeaders.values.contains { $0.contains("sk-ant") })
    }

    @Test func streamsTextIncludingCharactersSplitAcrossChunks() async throws {
        let answer = "Größe: 4,2 GB 🚀 — „Café“ 日本語"
        let words = answer.split(separator: " ", omittingEmptySubsequences: false).map { String($0) + " " }
        let body = sse(textEvents(words), extraLines: [": comment", "event: ping", "data: {\"type\": \"ping\"}", ""])
        // 3-byte chunks split nearly every multi-byte character.
        let (c, id, _) = client([ok(body, chunkSize: 3)])
        let events = try await collect(c)
        #expect(text(events) == words.joined())
        #expect(events.last == .done(stopReason: "end_turn"))
        let seen = try #require(StubURLProtocol.requests(id).first)
        #expect(seen.request.value(forHTTPHeaderField: "x-api-key") == testKey)
        #expect(!String(decoding: seen.body, as: UTF8.self).contains(testKey))
    }

    @Test func refusalIsReportedWithItsCategory() async throws {
        let body = sse(textEvents(["Partial "], stop: "refusal",
                                  stopDetails: ["type": "refusal", "category": "cyber", "explanation": "nope"]))
        let (c, _, _) = client([ok(body)])
        let events = try await collect(c)
        #expect(events.contains(.refusal(category: "cyber", explanation: "nope")))
        #expect(events.last == .done(stopReason: "refusal"))
    }

    @Test func fallbackBlockIsSurfaced() async throws {
        var events = textEvents(["Hello"])
        events.insert(("content_block_start", ["type": "content_block_start", "index": 0,
                                               "content_block": ["type": "fallback", "from": ["model": "claude-opus-5-5"],
                                                                 "to": ["model": "claude-opus-4-8"]]]), at: 1)
        let (c, _, _) = client([ok(sse(events))])
        let got = try await collect(c)
        #expect(got.contains(.fallback(from: "claude-opus-5-5", to: "claude-opus-4-8")))
        #expect(text(got) == "Hello")
    }

    @Test func badKeyFailsWithoutRetrying() async throws {
        let (c, id, log) = client([errorReply(401, type: "authentication_error", message: "invalid x-api-key"), ok("")])
        await #expect(throws: ClaudeError.invalidKey) { try await collect(c) }
        #expect(StubURLProtocol.requests(id).count == 1)
        #expect(log.all.isEmpty)
        #expect(!(ClaudeError.invalidKey.errorDescription ?? "").contains(testKey))
    }

    @Test func rateLimitIsRetriedOnceAfterRetryAfter() async throws {
        let (c, id, log) = client([errorReply(429, type: "rate_limit_error", headers: ["retry-after": "3"]),
                                   ok(sse(textEvents(["ok"])))])
        let events = try await collect(c)
        #expect(text(events) == "ok")
        #expect(StubURLProtocol.requests(id).count == 2)
        #expect(log.all == [3])
    }

    @Test func serverErrorsGiveUpAfterOneRetry() async throws {
        let (c, id, log) = client([errorReply(500, type: "api_error"), errorReply(529, type: "overloaded_error")])
        await #expect(throws: ClaudeError.overloaded) { try await collect(c) }
        #expect(StubURLProtocol.requests(id).count == 2)
        #expect(log.all.count == 1)
    }

    @Test func spendLimitIsNotRetried() async throws {
        let (c, id, _) = client([errorReply(429, type: "rate_limit_error",
                                            details: ["error_code": "enforced_spend_limit_reached"])])
        await #expect(throws: ClaudeError.spendLimit) { try await collect(c) }
        #expect(StubURLProtocol.requests(id).count == 1)
    }

    @Test func overloadErrorEventBeforeAnyTextIsRetried() async throws {
        let overloaded = sse([("message_start", ["type": "message_start", "message": ["id": "m"]]),
                              ("error", ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])])
        let (c, id, _) = client([ok(overloaded), ok(sse(textEvents(["second try"])))])
        let events = try await collect(c)
        #expect(text(events) == "second try")
        #expect(StubURLProtocol.requests(id).count == 2)
    }

    @Test func errorAfterTextIsNotRetried() async throws {
        var events = textEvents(["partial"])
        events.removeLast(2) // no message_delta / message_stop
        events.append(("error", ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]))
        let (c, id, _) = client([ok(sse(events)), ok(sse(textEvents(["never"])))])
        var got: [ClaudeEvent] = []
        await #expect(throws: ClaudeError.overloaded) {
            for try await e in c.stream(system: "s", messages: [ChatTurn(.user, "q")]) { got.append(e) }
        }
        #expect(text(got) == "partial")
        #expect(StubURLProtocol.requests(id).count == 1)
    }

    @Test func truncatedStreamIsAnError() async throws {
        var events = textEvents(["cut"])
        events.removeLast(2)
        let (c, _, _) = client([ok(sse(events))])
        await #expect(throws: ClaudeError.malformedResponse) { try await collect(c) }
    }

    @Test func offlineIsReportedAndDroppedConnectionsRetried() async throws {
        let (offline, offlineID, _) = client([.init(failure: URLError(.notConnectedToInternet))])
        await #expect(throws: ClaudeError.offline) { try await collect(offline) }
        #expect(StubURLProtocol.requests(offlineID).count == 1)

        let (lost, lostID, _) = client([.init(failure: URLError(.networkConnectionLost)), ok(sse(textEvents(["back"])))])
        #expect(text(try await collect(lost)) == "back")
        #expect(StubURLProtocol.requests(lostID).count == 2)
    }

    @Test func statusMapping() {
        #expect(ClaudeClient.mapStatus(402, body: Data(), retryAfter: nil) == .billing)
        #expect(ClaudeClient.mapStatus(403, body: Data(), retryAfter: nil) == .permission(""))
        #expect(ClaudeClient.mapStatus(429, body: Data(), retryAfter: " 7 ") == .rateLimited(retryAfter: 7))
        #expect(ClaudeClient.mapStatus(503, body: Data(), retryAfter: nil) == .server(503))
        let bad = try! JSONSerialization.data(withJSONObject: ["error": ["type": "invalid_request_error", "message": "messages: empty"]])
        #expect(ClaudeClient.mapStatus(400, body: bad, retryAfter: nil) == .badRequest("messages: empty"))
        #expect(ClaudeClient.mapStatus(404, body: Data(), retryAfter: nil) == .badRequest("HTTP 404"))
        #expect(ClaudeClient.retryDelay(for: .rateLimited(retryAfter: 300), attempt: 1) == 20)
        #expect(ClaudeClient.retryDelay(for: .server(500), attempt: 1) == 1.5)
        #expect(ClaudeError.rateLimited(retryAfter: 2.2).errorDescription?.contains("3 seconds") == true)
        for e: ClaudeError in [.invalidKey, .billing, .spendLimit, .overloaded, .offline, .timedOut, .malformedResponse,
                               .network("x"), .badRequest("y"), .server(500), .permission("p"), .rateLimited(retryAfter: nil)] {
            #expect(!(e.errorDescription ?? "").isEmpty)
        }
    }

    @Test func parserHandlesMultiLineDataAndCRLF() throws {
        var parser = SSEParser()
        var events: [ClaudeEvent] = []
        let lines = ["event: content_block_delta",
                     "data: {\"type\":\"content_block_delta\",",
                     "data: \"delta\":{\"type\":\"text_delta\",\"text\":\"joined\"}}",
                     "",
                     "id: 7", "retry: 100",
                     "data:{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}",
                     ClaudeClient.decodeLine(Array("data: {\"type\":\"message_stop\"}\r".utf8))]
        for line in lines { try parser.consume(line: line) { events.append($0) } }
        #expect(events == [.textDelta("joined"), .done(stopReason: "max_tokens")])
        // A second finish is a no-op.
        try parser.finish { events.append($0) }
        #expect(events.count == 2)
    }
}

// MARK: - Key storage

@Suite("Ask Claude · API key")
struct APIKeyTests {
    @Test func validationTrimsAndChecksShape() throws {
        #expect(try APIKeyValidation.normalize("  \(testKey)\n") == testKey)
        #expect(throws: APIKeyValidation.Problem.empty) { try APIKeyValidation.normalize(" \n ") }
        #expect(throws: APIKeyValidation.Problem.wrongPrefix) { try APIKeyValidation.normalize("sk-proj-abcdefghijklmnopqrstuvwxyz") }
        #expect(throws: APIKeyValidation.Problem.badCharacters) { try APIKeyValidation.normalize("sk-ant-abc def ghijklmnopqrstuvwxyz") }
        #expect(throws: APIKeyValidation.Problem.badCharacters) { try APIKeyValidation.normalize("sk-ant-abcdéfghijklmnopqrstuvwxyz") }
        #expect(throws: APIKeyValidation.Problem.wrongLength) { try APIKeyValidation.normalize("sk-ant-abc") }
    }

    @Test func keychainRoundTrip() throws {
        let store = KeychainStore(service: "com.diskscope.tests.anthropic-api-key.\(UUID().uuidString)")
        defer { try? store.delete() }
        do {
            try store.save("sk-ant-first-value-0000000000")
        } catch let error as KeychainError
            where [errSecNotAvailable, errSecInteractionNotAllowed, errSecNoSuchKeychain, errSecAuthFailed].contains(error.status) {
            return // no usable keychain in this environment (e.g. a locked CI session)
        }
        #expect(store.read() == "sk-ant-first-value-0000000000")
        try store.save("sk-ant-second-value-000000000")         // update in place
        #expect(store.read() == "sk-ant-second-value-000000000")
        try store.delete()
        #expect(store.read() == nil)
        try store.delete()                                       // deleting nothing is fine
        #expect(KeychainStore.apiKey.service == "com.diskscope.app.anthropic-api-key")
    }
}

// MARK: - Summary

@Suite("Ask Claude · disk summary")
struct DiskSummaryTests {
    @Test func summaryListsTotalsLargestItemsAndCurrentFolder() throws {
        let home = "/Users/tester"
        let root = makeTree(rootName: home + "/Work", [
            "Library/Containers/big.db:9000", "Library/small.txt:10",
            "Movies/trip.mov:5000", "Movies/clip.mov:700",
            "notes.txt:3", "empty/",
        ])
        root.errorCount = 2
        let movies = try #require(root["Movies"])
        let text = DiskSummary.make(root: root, current: movies, hidden: nil,
                                    volume: VolumeSummary(name: "Macintosh HD", total: 1_000_000, available: 400_000),
                                    showApparent: false, home: home)
        #expect(text.contains("Scanned: ~/Work (folder)"))
        #expect(text.contains("in 10 items") || text.contains("items"))
        #expect(text.contains("Unreadable: 2 items"))
        #expect(text.contains("Volume “Macintosh HD”"))
        #expect(text.contains("Library/Containers/big.db"))
        #expect(text.contains("Movies/trip.mov"))
        #expect(text.contains("(9000 bytes)"))
        #expect(text.contains("## Folder the user is looking at: Movies"))
        #expect(text.contains("trip.mov (file)"))
        #expect(!text.contains("/Users/tester"))
        #expect(!text.contains("Used space not found"))
        // "Library" is 99.9% "Library/Containers", so only the more specific folder is listed.
        let folderLines = section(text, "## Largest folders")
        #expect(folderLines.contains { $0.contains("Library/Containers") })
        #expect(!folderLines.contains { $0.hasSuffix("· Library · 2 items") || $0.contains("· Library ·") })
        // Largest files are biggest first.
        let fileLines = section(text, "## Largest files")
        #expect(fileLines.first?.contains("big.db") == true)
        #expect(fileLines.count == 5)
    }

    @Test func wholeDiskSummaryExplainsHiddenSpace() {
        let root = makeTree(rootName: "/", ["Users/a.bin:100"])
        let hidden = HiddenSpace(volumeName: "Macintosh HD", used: 1_000, scanned: 100,
                                 otherVolumes: [.init(name: "VM (swap and sleep image)", mountPoint: "/System/Volumes/VM", bytes: 300)],
                                 purgeable: 50, snapshots: 3, unreadable: 4)
        let text = DiskSummary.make(root: root, current: root, hidden: hidden, volume: nil, showApparent: true, home: "/Users/x")
        #expect(text.contains("Scanned: / (whole disk)"))
        #expect(text.contains("apparent file sizes"))
        #expect(text.contains("VM (swap and sleep image) (/System/Volumes/VM)"))
        #expect(text.contains("3 Time Machine local snapshots"))
        #expect(text.contains("4 unreadable items"))
        #expect(text.contains("Purgeable"))
        #expect(text.contains("## Top items in the scanned folder"))
    }

    @Test func namesAreSanitizedAndLongPathsClipped() {
        let evil = "invoice\u{202E}gpj.app"
        let long = String(repeating: "x", count: 400)
        let root = makeTree(rootName: "/scan", ["\(evil):50", "\(long)/f.bin:10"])
        let text = DiskSummary.make(root: root, current: root, hidden: nil, volume: nil, showApparent: false, home: "/Users/x")
        #expect(!text.contains("\u{202E}"))
        #expect(text.contains("invoice\u{FFFD}gpj.app"))
        #expect(!text.contains(long))
        #expect(text.contains("…"))
        #expect(DiskSummary.displayPath("/Users/x", home: "/Users/x") == "~")
        #expect(DiskSummary.displayPath("/Users/xy/z", home: "/Users/x") == "/Users/xy/z")
    }

    @Test func bigTreesStayBounded() {
        let root = FileNode(name: "/big", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
        for d in 0..<400 {
            let dir = FileNode(name: "dir\(d)", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0, mtime: 0, parent: root)
            var kids: [FileNode] = []
            kids.reserveCapacity(500)
            for f in 0..<500 {
                let size = Int64((d * 500 + f) % 9973 + 1) * 4096
                kids.append(FileNode(name: "file\(f).dat", isDirectory: false, isSymlink: false, diskSize: size,
                                     apparentSize: size, mtime: 1_700_000_000, parent: dir))
            }
            dir.children = kids
            root.children.append(dir)
        }
        FileNode.aggregateTotals(from: root)
        let start = Date()
        let text = DiskSummary.make(root: root, current: root, hidden: nil, volume: nil, showApparent: false, home: "/Users/x")
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(text.count < DiskSummary.maxCharacters)
        #expect(section(text, "## Largest files").count == DiskSummary.largestFiles)
        #expect(section(text, "## Largest folders").count == DiskSummary.largestFolders)
        #expect(section(text, "## Top items").count == DiskSummary.currentChildren + 1) // + "…and N smaller items"
        #expect(text.utf8.count / 4 < 6_000) // rough token estimate
        // The biggest file overall (size 9973 × 4096) is listed first.
        #expect(section(text, "## Largest files").first?.contains("(\(9973 * 4096) bytes)") == true)
    }

    @Test func duplicatesSectionIsCapped() {
        #expect(DiskSummary.duplicatesSection(lines: []) == "")
        let lines = (0..<50).map { "set \($0): 2 copies of a.jpg, 1 MB each" }
        let text = DiskSummary.duplicatesSection(lines: lines)
        #expect(text.hasPrefix("## Duplicate files found"))
        #expect(text.contains("…and 20 more sets"))
        #expect(text.split(separator: "\n").count == 32)
    }

    /// Bullet lines under the heading that starts with `heading`.
    private func section(_ text: String, _ heading: String) -> [String] {
        var lines: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("##") { inside = line.hasPrefix(heading); continue }
            if inside, line.hasPrefix("- ") { lines.append(line) }
        }
        return lines
    }
}

// MARK: - Panel model

private final class MemoryKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    init(_ key: String? = nil) { self.key = key }
    func read() -> String? { lock.withLock { key } }
    func save(_ key: String) throws { lock.withLock { self.key = key } }
    func delete() throws { lock.withLock { key = nil } }
}

/// Fake Claude: replays scripted events per call (or waits until cancelled) and records requests.
private final class FakeClaude: ClaudeStreaming, @unchecked Sendable {
    enum Script { case events([ClaudeEvent]), fail(Error), hang(after: [ClaudeEvent]) }
    private let lock = NSLock()
    private var scripts: [Script]
    private(set) var calls: [(system: String, messages: [ChatTurn])] = []
    init(_ scripts: [Script]) { self.scripts = scripts }

    var recorded: [(system: String, messages: [ChatTurn])] { lock.withLock { calls } }

    func stream(system: String, messages: [ChatTurn]) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let script: Script = lock.withLock {
            calls.append((system, messages))
            return scripts.isEmpty ? .events([.done(stopReason: "end_turn")]) : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch script {
            case .events(let events):
                for e in events { continuation.yield(e) }
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .hang(let events):
                for e in events { continuation.yield(e) } // then never finishes until cancelled
            }
        }
    }
}

@MainActor
private func makeModel(_ fake: FakeClaude, key: String? = testKey, enabled: Bool = true) -> (AskClaudeModel, UserDefaults) {
    let defaults = UserDefaults(suiteName: "DiskScopeTests-ask-\(UUID().uuidString)")!
    defaults.set(enabled, forKey: AskClaudeModel.enabledKey)
    let model = AskClaudeModel(keyStore: MemoryKeyStore(key), defaults: defaults, makeClient: { k in
        #expect(k == testKey)
        return fake
    })
    return (model, defaults)
}

@Suite("Ask Claude · panel model")
@MainActor
struct AskClaudeModelTests {
    @Test func firstQuestionCarriesTheSummaryLaterOnesDont() async throws {
        let fake = FakeClaude([.events([.textDelta("Your "), .textDelta("Library."), .done(stopReason: "end_turn")]),
                               .events([.textDelta("Yes."), .done(stopReason: "end_turn")])])
        let (model, _) = makeModel(fake)
        var contextCalls = 0
        func context() -> String { contextCalls += 1; return "SUMMARY-\(contextCalls)" }

        model.ask("What's big?", context: context())
        #expect(model.isStreaming)
        try await waitUntil { !model.isStreaming }
        #expect(model.transcript.map(\.text) == ["What's big?", "Your Library."])
        #expect(model.sentContext == "SUMMARY-1")

        model.ask("  Safe to delete?  ", context: context())
        try await waitUntil { !model.isStreaming }
        #expect(contextCalls == 1)                       // only built for the first question
        #expect(model.transcript.map(\.text) == ["What's big?", "Your Library.", "Safe to delete?", "Yes."])

        let calls = fake.recorded
        #expect(calls.count == 2)
        #expect(calls[0].system == AskClaudeModel.systemPrompt)
        #expect(calls[0].messages.count == 1)
        #expect(calls[0].messages[0].text == "<disk_summary>\nSUMMARY-1\n</disk_summary>\n\nWhat's big?")
        let second = calls[1].messages
        #expect(second.map(\.role) == [.user, .assistant, .user])
        #expect(second[0].text.contains("<disk_summary>"))     // history is resent as-is
        #expect(second[2].text == "Safe to delete?")
        #expect(!second[2].text.contains("<disk_summary>"))
    }

    @Test func nothingIsSentUntilEnabledWithAKey() async throws {
        let fake = FakeClaude([])
        let (off, defaults) = makeModel(fake, enabled: false)
        #expect(!off.isReady)
        off.ask("hello", context: "S")
        #expect(fake.recorded.isEmpty && off.transcript.isEmpty)
        off.enabled = true
        #expect(defaults.bool(forKey: AskClaudeModel.enabledKey))

        let (noKey, _) = makeModel(fake, key: nil)
        #expect(!noKey.hasKey && !noKey.isReady)
        noKey.ask("hello", context: "S")
        #expect(fake.recorded.isEmpty)
        #expect(throws: APIKeyValidation.Problem.wrongPrefix) { try noKey.saveKey("not-a-key") }
        try noKey.saveKey(" \(testKey) ")
        #expect(noKey.isReady)
        try noKey.removeKey()
        #expect(!noKey.hasKey)
    }

    @Test func refusalDiscardsThePartialAnswer() async throws {
        let fake = FakeClaude([.events([.textDelta("Partial"), .refusal(category: "cyber", explanation: nil), .done(stopReason: "refusal")])])
        let (model, _) = makeModel(fake)
        model.ask("question", context: "S")
        try await waitUntil { !model.isStreaming }
        #expect(model.transcript.isEmpty)
        #expect(model.sentContext == nil)
        #expect(model.errorMessage?.contains("declined") == true)
        #expect(model.errorMessage?.contains("cyber") == true)
        #expect(model.returnedQuestion == "question")
    }

    @Test func failuresShowAFriendlyMessage() async throws {
        let fake = FakeClaude([.fail(ClaudeError.invalidKey)])
        let (model, _) = makeModel(fake)
        model.ask("question", context: "S")
        try await waitUntil { !model.isStreaming }
        #expect(model.transcript.isEmpty)
        #expect(model.errorMessage == ClaudeError.invalidKey.errorDescription)
        #expect(model.returnedQuestion == "question")
    }

    @Test func fallbackNoticeIsShown() async throws {
        let fake = FakeClaude([.events([.fallback(from: "claude-opus-5-5", to: "claude-opus-4-8"), .textDelta("Hi"), .done(stopReason: "end_turn")])])
        let (model, _) = makeModel(fake)
        model.ask("q", context: "S")
        try await waitUntil { !model.isStreaming }
        #expect(model.notice == "Answered by claude-opus-4-8.")
        #expect(model.transcript.last?.text == "Hi")
    }

    @Test func stoppingKeepsPartialTextOrDropsAnEmptyExchange() async throws {
        let fake = FakeClaude([.hang(after: [.textDelta("Half an ans")]), .hang(after: [])])
        let (model, _) = makeModel(fake)
        model.ask("first", context: "S")
        try await waitUntil { model.transcript.last?.text == "Half an ans" }
        model.cancel()
        #expect(!model.isStreaming)
        #expect(model.transcript.map(\.text) == ["first", "Half an ans …"])

        model.ask("second", context: "S")
        #expect(model.isStreaming)
        model.cancel()
        #expect(!model.isStreaming)
        #expect(model.transcript.map(\.text) == ["first", "Half an ans …"])
        #expect(model.returnedQuestion == "second")
        try await Task.sleep(for: .milliseconds(50)) // the cancelled task finishing later changes nothing
        #expect(model.transcript.count == 2)

        model.clear()
        #expect(model.transcript.isEmpty && model.sentContext == nil)
    }

    @Test func disablingStopsAnAnswerInProgress() async throws {
        let fake = FakeClaude([.hang(after: [.textDelta("x")])])
        let (model, _) = makeModel(fake)
        model.ask("q", context: "S")
        try await waitUntil { model.transcript.last?.text == "x" }
        model.enabled = false
        #expect(!model.isStreaming)
    }

    @Test func answersRenderWithoutLinks() {
        let rendered = AnswerFormatting.render("See [this](https://evil.example/x) and **bold** `code` <https://a.example>")
        #expect(!rendered.runs.contains { $0.link != nil })
        #expect(String(rendered.characters).contains("this"))
        #expect(String(rendered.characters).contains("bold"))
        #expect(AskClaudePanel.sizeEstimate(String(repeating: "a", count: 4000)).contains("1,000 tokens"))
    }
}
