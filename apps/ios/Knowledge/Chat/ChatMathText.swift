import MathJaxSwift
import SwiftDraw
import SwiftUI
import UIKit

/// Keeps Markdown in native selectable text, including literal math inside code.
struct ChatMathText: View {
    let source: String
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var images: [String: RenderedEquation] = [:]
    @State private var imageSize: DynamicTypeSize?
    @State private var imageScale: CGFloat?

    var body: some View {
        let document = MathDocument(source)
        let citations = citationNumbers(in: document)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let markdown):
                    inlineText(markdown, equations: document.equations, citations: citations)
                case .display(let equation):
                    displayEquation(equation)
                }
            }
        }
        .task(id: RenderKey(source: source, size: dynamicTypeSize, scale: displayScale)) {
            // A new streamed fragment cancels obsolete work. Completed equations
            // remain cached locally, so only newly closed formulas need rendering.
            let xHeight = UIFont.preferredFont(
                forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .init(dynamicTypeSize))
            ).xHeight
            var updated: [String: RenderedEquation] = [:]
            for equation in document.allEquations {
                guard !Task.isCancelled else { return }
                if imageSize == dynamicTypeSize, imageScale == displayScale, let image = images[equation] {
                    updated[equation] = image
                    continue
                }
                let rendered = await ChatMathRenderer.shared.render(equation, xHeight: xHeight, scale: displayScale)
                guard !Task.isCancelled else { return }
                if let rendered, let image = UIImage(data: rendered.data, scale: displayScale) {
                    updated[equation] = RenderedEquation(image: image, baseline: rendered.baseline)
                }
            }
            images = updated
            imageSize = dynamicTypeSize
            imageScale = displayScale
        }
    }

    @ViewBuilder private func displayEquation(_ equation: String) -> some View {
        if let rendered = images[equation] {
            // The vertical conversation scroll view supplies the available
            // width; only equations wider than that width need to scroll.
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    Image(uiImage: rendered.image)
                        .renderingMode(.template)
                        .frame(minWidth: geometry.size.width)
                        .accessibilityLabel(equation)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: rendered.image.size.height)
        } else {
            Text(equation)
        }
    }

    private func markdownText(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private func citationNumbers(in document: MathDocument) -> [URL: Int] {
        var numbers: [URL: Int] = [:]
        for block in document.blocks {
            guard case .text(let markdown) = block else { continue }
            for run in markdownText(markdown).runs[\.link] {
                guard let url = run.0, isSourceCitation(url), numbers[url] == nil else { continue }
                numbers[url] = numbers.count + 1
            }
        }
        return numbers
    }

    private func isSourceCitation(_ url: URL) -> Bool {
        url.scheme == "knowledge" && url.host == "source"
    }

    private func inlineText(_ markdown: String, equations: [String: String], citations: [URL: Int]) -> Text {
        var attributed = markdownText(markdown)
        var result = Text("")
        // Parse Markdown before substitution so emphasis and links can span
        // equations. Source citations keep their exact URL and native link behavior.
        while !attributed.characters.isEmpty {
            let equation = equations.compactMap { marker, equation in
                attributed.range(of: marker).map { (range: $0, equation: equation) }
            }.min(by: { $0.range.lowerBound < $1.range.lowerBound })
            let citation = attributed.runs[\.link].first { run in
                run.0.map { citations[$0] != nil } ?? false
            }

            if let citation, let url = citation.0, let number = citations[url],
               equation.map({ citation.1.lowerBound <= $0.range.lowerBound }) ?? true {
                let prefix = Text(AttributedString(attributed[attributed.startIndex..<citation.1.lowerBound]))
                var label = AttributedString("[\(number)]")
                label.link = url
                let reference = Text(label)
                    .font(.caption.weight(.semibold))
                    .baselineOffset(4)
                    .accessibilityLabel("Source \(number)")
                result = Text("\(result)\(prefix)\(reference)")
                attributed = AttributedString(attributed[citation.1.upperBound...])
            } else if let equation {
                let prefix = Text(AttributedString(attributed[attributed.startIndex..<equation.range.lowerBound]))
                result = Text("\(result)\(prefix)")
                if let rendered = images[equation.equation] {
                    let formula = Text(Image(uiImage: rendered.image).renderingMode(.template))
                        .baselineOffset(rendered.baseline)
                        .accessibilityLabel(equation.equation)
                    result = Text("\(result)\(formula)")
                } else {
                    result = Text("\(result)\(equation.equation)")
                }
                attributed = AttributedString(attributed[equation.range.upperBound...])
            } else {
                result = Text("\(result)\(Text(attributed))")
                break
            }
        }
        return result
    }

    private struct RenderKey: Hashable {
        let source: String
        let size: DynamicTypeSize
        let scale: CGFloat
    }

    private struct RenderedEquation {
        let image: UIImage
        let baseline: CGFloat
    }
}

/// Owns the JavaScript engine outside the main actor. Only encoded images cross
/// into SwiftUI; malformed formulas keep their original, selectable source.
private actor ChatMathRenderer {
    static let shared = ChatMathRenderer()
    private var mathJax: MathJax?

    struct Result: Sendable {
        let data: Data
        let baseline: CGFloat
    }

    func render(_ equation: String, xHeight: CGFloat, scale: CGFloat) -> Result? {
        guard !Task.isCancelled else { return nil }
        if mathJax == nil { mathJax = try? MathJax(preferredOutputFormats: [.svg]) }
        guard let mathJax else { return nil }
        let display = equation.hasPrefix("\\[") || equation.hasPrefix("$$")
        let delimiterLength = equation.hasPrefix("\\") || display ? 2 : 1
        let body = String(equation.dropFirst(delimiterLength).dropLast(delimiterLength))
        do {
            // MathJaxSwift 3.5.0 leaves decimal dots unescaped in its default
            // number pattern. That consumes operators/braces as decimal points
            // and rejects valid expressions such as x^{n-1}.
            let inputOptions = TeXInputProcessorOptions(
                digits: #"^(?:[0-9]+(?:{,}[0-9]{3})*(?:\.[0-9]*)?|\.[0-9]+)"#
            )
            let markup = try mathJax.tex2svg(
                body,
                styles: false,
                conversionOptions: .init(display: display),
                inputOptions: inputOptions
            )
            // MathJax reports dimensions in ex units. Resolve them against the
            // current body font before passing the SVG to the rasterizer.
            let regex = try NSRegularExpression(pattern: #"(width|height)="([0-9.]+)ex""#)
            var sized = markup
            for match in regex.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)).reversed() {
                guard let range = Range(match.range, in: sized),
                      let name = Range(match.range(at: 1), in: markup),
                      let value = Range(match.range(at: 2), in: markup),
                      let units = Double(markup[value]) else { continue }
                sized.replaceSubrange(range, with: "\(markup[name])=\"\(units * xHeight)px\"")
            }
            guard !Task.isCancelled, let svg = SVG(data: Data(sized.utf8)),
                  svg.size.width > 0, svg.size.height > 0,
                  svg.size.width * scale <= 8192, svg.size.height * scale <= 8192 else { return nil }
            guard let data = svg.rasterize(scale: scale).pngData() else { return nil }
            let alignment = try NSRegularExpression(pattern: #"vertical-align:\s*(-?[0-9.]+)ex"#)
            let match = alignment.firstMatch(in: markup, range: NSRange(markup.startIndex..., in: markup))
            let baseline = match.flatMap { Range($0.range(at: 1), in: markup) }
                .flatMap { Double(markup[$0]) } ?? 0
            return Result(data: data, baseline: baseline * xHeight)
        } catch {
            return nil
        }
    }
}

private struct MathDocument {
    enum Block {
        case text(String)
        case display(String)
    }

    var blocks: [Block] = []
    var equations: [String: String] = [:]

    var allEquations: Set<String> {
        Set(equations.values).union(blocks.compactMap { block in
            if case .display(let equation) = block { return equation }
            return nil
        })
    }

    // Code takes precedence over math. An unfinished code span protects the
    // remainder of a streaming reply until its closing backticks arrive.
    private static let code = try? NSRegularExpression(
        pattern: #"(`+)[\s\S]*?(?:\1(?!`)|$)|(?m:^ {0,3}(~{3,})[^\n]*\n)[\s\S]*?(?:(?m:^ {0,3}\2~*\s*$)|\z)"#
    )
    private static let math = try? NSRegularExpression(
        pattern: #"(?<escape>\\\\|\\\$)|(?<display>\\\[[\s\S]*?\\\]|\$\$[\s\S]*?(?<!\\)\$\$)|(?<inline>\\\([\s\S]*?\\\)|(?<![\w$])\$(?!\s|\$)(?:\\.|[^$\n\\])*?(?<!\s|\\)\$(?![\w$]))"#
    )

    init(_ source: String) {
        let fullRange = NSRange(source.startIndex..., in: source)
        let codeRanges = Self.code?.matches(in: source, range: fullRange).map(\.range) ?? []
        let matches = Self.math?.matches(in: source, range: fullRange) ?? []
        var cursor = source.startIndex
        var text = ""
        var markerPrefix = "\u{E000}knowledgeMath"
        while source.contains(markerPrefix) { markerPrefix += "x" }

        for match in matches {
            guard match.range(withName: "escape").location == NSNotFound,
                  !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: source) else { continue }
            text += source[cursor..<range.lowerBound]
            let equation = String(source[range])
            if match.range(withName: "display").location != NSNotFound {
                if !text.isEmpty { blocks.append(.text(text)); text = "" }
                blocks.append(.display(equation))
            } else {
                let marker = "\(markerPrefix)\(equations.count)\u{E001}"
                equations[marker] = equation
                text += marker
            }
            cursor = range.upperBound
        }
        text += source[cursor...]
        if !text.isEmpty { blocks.append(.text(text)) }
    }
}
