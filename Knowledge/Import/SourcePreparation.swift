import Foundation
import PDFKit
import CryptoKit

nonisolated enum SourcePreparation {
    static let maximumCharacters = 300_000
    static let maximumBytes = 25 * 1024 * 1024
    static let extractionContextCharacters = 4_000
    static let recoveryContextCharacters = [12_000, 36_000]

    static func directory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("KnowledgeSources", isDirectory: true)
    }

    @concurrent static func prepare(file url: URL, directory: URL? = nil) async throws -> PreparedSource {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let kind: SourceKind
        switch url.pathExtension.lowercased() {
        case "pdf": kind = .pdf
        case "txt": kind = .text
        case "md", "markdown": kind = .markdown
        default: throw ImportError.unsupportedFile
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw ImportError.sourceTooLarge }
        // Snapshot provider-owned bytes; a memory mapping could change underneath PDFKit if the original is replaced.
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw ImportError.sourceTooLarge }
        let pages: [String]
        if kind == .pdf {
            guard let pdf = PDFDocument(data: data) else { throw ImportError.unreadablePDF }
            guard !pdf.isLocked else { throw ImportError.lockedPDF }
            var text: [String] = []
            var missing: [Int] = []
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let page = pdf.page(at: index)?.string ?? ""
                if page.trimmed.isEmpty { missing.append(index + 1) }
                text.append(page)
            }
            guard missing.isEmpty else { throw ImportError.needsOCR(missing) }
            pages = text
        } else {
            let text: String?
            if data.starts(with: [0xff, 0xfe]) { text = String(data: data, encoding: .utf16LittleEndian) }
            else if data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16BigEndian) }
            else { text = String(data: data, encoding: .utf8) }
            guard let text, !text.contains("\0") else { throw ImportError.unreadableText }
            pages = [text.replacingOccurrences(of: "\u{feff}", with: "")]
        }
        return try store(data: data, pages: pages, title: url.deletingPathExtension().lastPathComponent,
                         kind: kind, directory: directory)
    }

    @concurrent static func prepare(text: String, title: String, directory: URL? = nil) async throws -> PreparedSource {
        try Task.checkCancellation()
        return try store(data: Data(text.utf8), pages: [text], title: title.trimmed.isEmpty ? "Pasted notes" : title.trimmed,
                         kind: .text, directory: directory)
    }

    static func segments(pages: [String], isPDF: Bool) throws -> [SourceSegment] {
        guard pages.reduce(0, { $0 + $1.count }) <= maximumCharacters else { throw ImportError.sourceTooLarge }
        var result: [SourceSegment] = []
        var section: String?
        for (pageIndex, page) in pages.enumerated() {
            let text = page.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            // Each line remains separately addressable, including headings and nested bullets.
            for line in text.components(separatedBy: "\n") where !line.trimmed.isEmpty {
                if isHeading(line) { section = line.trimmed }
                var rest = line[...]
                while !rest.isEmpty {
                    var end = rest.index(rest.startIndex, offsetBy: min(1800, rest.count))
                    if end != rest.endIndex, let space = rest[..<end].lastIndex(where: \.isWhitespace),
                       rest.distance(from: rest.startIndex, to: space) > 900 { end = rest.index(after: space) }
                    let part = String(rest[..<end])
                    result.append(SourceSegment(id: "p\(pageIndex + 1)-s\(result.count + 1)",
                        page: isPDF ? pageIndex + 1 : nil, section: section, text: part))
                    rest = rest[end...]
                }
            }
        }
        guard !result.isEmpty else { throw ImportError.emptySource }
        return result
    }

    static func chunks(for source: PreparedSource, maximumCharacters: Int = 4_000, maximumPassages: Int = 24) -> [SourceChunk] {
        var chunks: [SourceChunk] = []
        var pending: [SourceSegment] = []
        var length = 0
        var previous: SourceSegment?
        func emit() {
            guard !pending.isEmpty else { return }
            chunks.append(SourceChunk(index: chunks.count, segments: (previous.map { [$0] } ?? []) + pending,
                                      requiredSegmentIDs: pending.map(\.id)))
            previous = pending.last
            pending = []
            length = previous?.text.count ?? 0
        }
        for segment in source.segments {
            if !pending.isEmpty && (length + segment.text.count > maximumCharacters || pending.count >= maximumPassages) { emit() }
            pending.append(segment)
            length += segment.text.count
        }
        emit()
        return chunks
    }

    /// Keep coverage ownership stable while expanding reading context in both directions.
    /// The window follows source order and makes no assumptions about document formatting.
    static func contextWindow(for chunk: SourceChunk, source: PreparedSource, charactersPerSide: Int,
                              maximumEncodedBytes: Int) throws -> SourceChunk {
        let anchors = Set(chunk.segments.map(\.id) + chunk.requiredSegmentIDs)
        guard let first = source.segments.firstIndex(where: { anchors.contains($0.id) }),
              let last = source.segments.lastIndex(where: { anchors.contains($0.id) }) else {
            throw ImportValidator.invalid("The extraction passages are missing from the source.")
        }
        let encoder = JSONEncoder()
        var lower = first, upper = last + 1
        var bytes = try encoder.encode(Array(source.segments[lower..<upper])).count
        guard bytes <= maximumEncodedBytes else {
            throw ImportValidator.invalid("The source passages exceed the extraction request budget.")
        }
        var before = 0, after = 0
        var canReadBefore = true, canReadAfter = true
        while canReadBefore || canReadAfter {
            // Alternate directions so the encoded-byte budget does not favor earlier text.
            if canReadBefore {
                if lower > 0 && before < charactersPerSide {
                    let segment = source.segments[lower - 1]
                    let cost = try encoder.encode(segment).count + 1
                    if bytes + cost <= maximumEncodedBytes {
                        lower -= 1; before += segment.text.count; bytes += cost
                    } else { canReadBefore = false }
                } else { canReadBefore = false }
            }
            if canReadAfter {
                if upper < source.segments.count && after < charactersPerSide {
                    let segment = source.segments[upper]
                    let cost = try encoder.encode(segment).count + 1
                    if bytes + cost <= maximumEncodedBytes {
                        upper += 1; after += segment.text.count; bytes += cost
                    } else { canReadAfter = false }
                } else { canReadAfter = false }
            }
        }
        return .init(index: chunk.index, segments: Array(source.segments[lower..<upper]),
                     requiredSegmentIDs: chunk.requiredSegmentIDs)
    }

    private static func isHeading(_ line: String) -> Bool {
        let text = line.trimmed
        if text.hasPrefix("#") { return true }
        return text.count < 100 && text.range(of: "^(Module|Chapter|Unit|Section|Part)\\s+", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func store(data: Data, pages: [String], title: String, kind: SourceKind, directory: URL?) throws -> PreparedSource {
        let segments = try segments(pages: pages, isPDF: kind == .pdf)
        guard data.count <= maximumBytes else { throw ImportError.sourceTooLarge }
        try Task.checkCancellation()
        let id = UUID()
        let folder = try directory ?? self.directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = id.uuidString + (kind == .pdf ? ".pdf" : kind == .markdown ? ".md" : ".txt")
        try data.write(to: folder.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PreparedSource(id: id, title: title, kind: kind, storedFilename: filename, digest: digest, segments: segments)
    }
}
