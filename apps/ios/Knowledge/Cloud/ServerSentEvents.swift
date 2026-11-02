import Foundation

nonisolated enum ServerSentEventError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "OpenAI returned an unexpected response. Completion could not be confirmed." }
}

nonisolated struct ServerSentEvent: Equatable, Sendable { let name: String?; let data: String }

/// Preserves blank lines and split UTF-8 characters; CR, LF and CRLF all delimit SSE lines.
nonisolated struct ServerSentEventParser {
    private let maximumEventBytes: Int
    private var line = Data()
    private var dataLines: [String] = []
    private var name: String?
    private var eventBytes = 0
    private var skipLF = false
    init(maximumEventBytes: Int = 524_288) { self.maximumEventBytes = maximumEventBytes }
    mutating func append(_ chunk: Data) throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in chunk {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                if let event = try consumeLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventBytes <= maximumEventBytes else { throw ServerSentEventError.invalidResponse }
            }
        }
        return events
    }
    mutating func finish() throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !line.isEmpty, let event = try consumeLine() { events.append(event) }
        if let event = emit() { events.append(event) }
        return events
    }
    private mutating func consumeLine() throws -> ServerSentEvent? {
        guard let value = String(data: line, encoding: .utf8) else { throw ServerSentEventError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return emit() }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var contents = parts.count == 2 ? String(parts[1]) : ""
        if contents.hasPrefix(" ") { contents.removeFirst() }
        if field == "data" { dataLines.append(contents); eventBytes += contents.utf8.count }
        if field == "event" { name = contents }
        guard eventBytes <= maximumEventBytes else { throw ServerSentEventError.invalidResponse }
        return nil
    }
    private mutating func emit() -> ServerSentEvent? {
        defer { dataLines.removeAll(keepingCapacity: true); name = nil; eventBytes = 0 }
        return dataLines.isEmpty ? nil : ServerSentEvent(name: name, data: dataLines.joined(separator: "\n"))
    }
}
