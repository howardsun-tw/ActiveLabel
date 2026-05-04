//
//  MarkdownParser.swift
//  ActiveLabel
//

import Foundation

#if canImport(UIKit)
import UIKit

public struct MarkdownParseResult {
    public let attributedString: NSMutableAttributedString
    public let links: [MarkdownLink]

    init(attributedString: NSMutableAttributedString, links: [MarkdownLink]) {
        self.attributedString = attributedString
        self.links = links
    }
}

public struct MarkdownLink {
    public let range: NSRange
    public let url: URL

    init(range: NSRange, url: URL) {
        self.range = range
        self.url = url
    }
}

/// Caller-supplied styling for the inline `code` span (single backticks).
/// Triple-backtick fenced code blocks are unaffected — they always render
/// with a flat `.backgroundColor` and the body font.
///
/// The parser is generic; callers (e.g. IMKit's vue-sdk-flavored chat
/// bubbles) decide whether inline code should keep the legacy flat
/// `.backgroundColor` or be tagged with a marker attribute that a custom
/// `NSLayoutManager` paints as a rounded pill.
public struct MarkdownInlineCodeStyle: Sendable {

    /// How the parser annotates inline `code` runs for background painting.
    public enum BackgroundMode: Sendable {
        /// Legacy: parser writes `.backgroundColor = codeBackgroundColor` on
        /// the inline run. UILabel paints a flat rect with no corner radius.
        case stockBackgroundColor
        /// Parser writes the named attribute key (with `NSNumber(true)`) on
        /// the inline run instead of `.backgroundColor`. A custom layout
        /// manager owned by the caller is responsible for the actual paint.
        case markerAttribute(NSAttributedString.Key)
    }

    /// Foreground color for inline-code runs. `nil` means "inherit the
    /// surrounding `textColor`" (legacy behavior).
    public var foregroundColor: UIColor?

    /// Font size relative to the surrounding body font. `1.0` keeps the
    /// existing body size; a chat client mirroring vue-sdk would pass `0.85`.
    public var fontScale: CGFloat

    /// Whether the parser writes `.backgroundColor` directly or tags a
    /// custom marker attribute for the caller to paint.
    public var backgroundMode: BackgroundMode

    /// Extra advance (in em of the inline-code run's font) inserted
    /// immediately before and after each inline `code` run via `.kern`.
    /// Used by callers whose pill has its own internal padding extending
    /// past the glyph bounds — without this, the pill bg overlaps the
    /// adjacent glyph's leading edge or sits flush against it. Default
    /// `0` (no extra kerning).
    public var outerKerningEm: CGFloat

    public init(foregroundColor: UIColor? = nil,
                fontScale: CGFloat = 1.0,
                backgroundMode: BackgroundMode = .stockBackgroundColor,
                outerKerningEm: CGFloat = 0) {
        self.foregroundColor = foregroundColor
        self.fontScale = fontScale
        self.backgroundMode = backgroundMode
        self.outerKerningEm = outerKerningEm
    }

    /// Default — backwards-compatible flat `.backgroundColor` paint, no
    /// foreground override, body-size monospaced glyphs.
    public static let `default` = MarkdownInlineCodeStyle()

    /// Stamps `.kern` around every marker run so the caller's pill paint
    /// (which extends past the glyph bounds) gets a visible gap from
    /// adjacent text. No-op when `outerKerningEm == 0` or when the caller
    /// uses `.stockBackgroundColor` (no marker → nothing to find).
    /// Exposed so render paths that don't go through `MarkdownParser.parse`
    /// (e.g. streaming token-by-token assembly) can apply the same post-pass.
    public func applyOuterKerning(
        to output: NSMutableAttributedString,
        baseFont: UIFont
    ) {
        guard outerKerningEm > 0,
              case .markerAttribute(let markerKey) = backgroundMode
        else { return }

        let kernPoints = baseFont.pointSize * fontScale * outerKerningEm
        let fullRange = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(markerKey, in: fullRange, options: []) { value, range, _ in
            guard let flag = value as? NSNumber, flag.boolValue, range.length > 0 else { return }
            let last = NSRange(location: range.location + range.length - 1, length: 1)
            output.addAttribute(.kern, value: NSNumber(value: Double(kernPoints)), range: last)
            if range.location > 0 {
                let prev = NSRange(location: range.location - 1, length: 1)
                output.addAttribute(.kern, value: NSNumber(value: Double(kernPoints)), range: prev)
            }
        }
    }

    /// Stable string used to discriminate cache entries that disagree only
    /// on inline-code styling (the parser memoizes its output).
    fileprivate var cacheKey: String {
        let mode: String
        switch backgroundMode {
        case .stockBackgroundColor: mode = "stock"
        case .markerAttribute(let key): mode = "marker(\(key.rawValue))"
        }
        let fg = foregroundColor?.activeLabelMarkdownCacheKey ?? "nil"
        return "fg=\(fg)|scale=\(fontScale)|mode=\(mode)|kern=\(outerKerningEm)"
    }
}

public enum MarkdownParser {

    /// Width (in points) used as the head indent for a single blockquote
    /// nesting level and for the hanging indent of list items. Exposed so
    /// callers can mirror the same indent in measurement tooling.
    public static let blockQuoteIndent: CGFloat = 12
    public static let listHangingIndent: CGFloat = 16

    // MARK: - Cache

    private final class CachedResult {
        let attributedString: NSAttributedString
        let links: [MarkdownLink]
        init(attributedString: NSAttributedString, links: [MarkdownLink]) {
            self.attributedString = attributedString
            self.links = links
        }
    }

    private static let cache: NSCache<NSString, CachedResult> = {
        let cache = NSCache<NSString, CachedResult>()
        cache.countLimit = 256
        return cache
    }()

    /// Drop all memoized parse results. Test seam plus a manual purge
    /// for callers that mutate global styling at runtime.
    public static func clearCache() {
        cache.removeAllObjects()
    }

    private static func cacheKey(
        text: String,
        baseFont: UIFont,
        textColor: UIColor,
        codeBackgroundColor: UIColor,
        inlineCodeStyle: MarkdownInlineCodeStyle
    ) -> NSString {
        let fontKey = "\(baseFont.familyName)|\(baseFont.pointSize)|\(baseFont.fontDescriptor.symbolicTraits.rawValue)"
        let textColorKey = textColor.activeLabelMarkdownCacheKey
        let codeBgKey = codeBackgroundColor.activeLabelMarkdownCacheKey
        return "\(textColorKey)|\(codeBgKey)|\(inlineCodeStyle.cacheKey)|\(fontKey)|\(text)" as NSString
    }

    /// Parse `markdown` into a styled `NSMutableAttributedString`.
    ///
    /// - Parameters:
    ///   - markdown: Source text.
    ///   - baseFont: Body font; headers / inline traits scale off this.
    ///   - textColor: Default foreground for runs.
    ///   - codeBackgroundColor: Background for fenced (triple-backtick)
    ///     code blocks. Also applied to inline `code` *only* when
    ///     `inlineCodeStyle.backgroundMode == .stockBackgroundColor`
    ///     (the default). When the caller picks `.markerAttribute(...)`
    ///     this color is no longer applied to inline code — the caller's
    ///     layout manager paints the inline pill instead.
    ///   - inlineCodeStyle: How inline `code` runs are annotated. See
    ///     `MarkdownInlineCodeStyle`. Default = legacy flat `.backgroundColor`.
    public static func parse(
        _ markdown: String,
        baseFont: UIFont,
        textColor: UIColor = .label,
        codeBackgroundColor: UIColor = .systemGray6,
        inlineCodeStyle: MarkdownInlineCodeStyle = .default
    ) -> MarkdownParseResult {
        let key = cacheKey(
            text: markdown,
            baseFont: baseFont,
            textColor: textColor,
            codeBackgroundColor: codeBackgroundColor,
            inlineCodeStyle: inlineCodeStyle
        )
        if let cached = cache.object(forKey: key) {
            return MarkdownParseResult(
                attributedString: NSMutableAttributedString(attributedString: cached.attributedString),
                links: cached.links
            )
        }

        let result = parseUncached(
            markdown,
            baseFont: baseFont,
            textColor: textColor,
            codeBackgroundColor: codeBackgroundColor,
            inlineCodeStyle: inlineCodeStyle
        )
        cache.setObject(
            CachedResult(
                attributedString: NSAttributedString(attributedString: result.attributedString),
                links: result.links
            ),
            forKey: key
        )
        return result
    }

    private static func parseUncached(
        _ markdown: String,
        baseFont: UIFont,
        textColor: UIColor,
        codeBackgroundColor: UIColor,
        inlineCodeStyle: MarkdownInlineCodeStyle
    ) -> MarkdownParseResult {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return MarkdownParseResult(
                attributedString: NSMutableAttributedString(
                    string: markdown,
                    attributes: bodyAttributes(baseFont: baseFont, textColor: textColor)
                ),
                links: []
            )
        }

        let output = NSMutableAttributedString(string: "")
        let sourceLinkEvents = sourceLinkEvents(in: markdown)
        var linkGroups: [ParsedLinkGroup] = []
        var currentLinkGroup: ParsedLinkGroup?
        var currentBlockIdentity: Int?
        var currentListItemIdentity: Int?
        var previousBlock: BlockDescriptor?

        func finishCurrentLinkGroup() {
            if let group = currentLinkGroup {
                linkGroups.append(group)
                currentLinkGroup = nil
            }
        }

        for run in parsed.runs {
            let runText = String(parsed.characters[run.range])
            let block = blockDescriptor(for: run.presentationIntent)

            if currentBlockIdentity != block.identity {
                finishCurrentLinkGroup()
                if output.length > 0 {
                    let trailingStyle = previousBlock?.paragraphStyle(baseFont: baseFont) ?? bodyParagraphStyle(baseFont: baseFont)
                    output.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: baseFont,
                            .paragraphStyle: trailingStyle
                        ]
                    ))
                }

                if block.kind == .thematicBreak {
                    let dashes = String(repeating: "\u{2014}", count: 8)
                    output.append(NSAttributedString(
                        string: dashes,
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: textColor.withAlphaComponent(0.3),
                            .paragraphStyle: block.paragraphStyle(baseFont: baseFont)
                        ]
                    ))
                    currentBlockIdentity = block.identity
                    currentListItemIdentity = nil
                    previousBlock = block
                    continue
                }

                let prefix = block.prefix(isContinuingListItem: block.listItemIdentity == currentListItemIdentity)
                if !prefix.isEmpty {
                    output.append(NSAttributedString(
                        string: prefix,
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: textColor,
                            .paragraphStyle: block.paragraphStyle(baseFont: baseFont)
                        ]
                    ))
                }
                currentBlockIdentity = block.identity
                currentListItemIdentity = block.listItemIdentity
                previousBlock = block
            }

            guard !runText.isEmpty else { continue }

            let location = output.length
            let attributes = attributes(
                baseFont: baseFont,
                textColor: textColor,
                codeBackgroundColor: codeBackgroundColor,
                inlineCodeStyle: inlineCodeStyle,
                inlineIntent: run.inlinePresentationIntent,
                presentationIntent: run.presentationIntent,
                link: run.link,
                block: block
            )
            output.append(NSAttributedString(string: runText, attributes: attributes))

            let runRange = NSRange(location: location, length: (runText as NSString).length)
            if let url = run.link {
                if var group = currentLinkGroup,
                   group.url == url,
                   group.range.location + group.range.length == runRange.location {
                    group.range.length += runRange.length
                    group.visibleText += runText
                    currentLinkGroup = group
                } else {
                    finishCurrentLinkGroup()
                    currentLinkGroup = ParsedLinkGroup(range: runRange, url: url, visibleText: runText)
                }
            } else {
                finishCurrentLinkGroup()
            }
        }
        finishCurrentLinkGroup()

        if output.length == 0, !markdown.isEmpty {
            return MarkdownParseResult(
                attributedString: NSMutableAttributedString(
                    string: markdown,
                    attributes: bodyAttributes(baseFont: baseFont, textColor: textColor)
                ),
                links: []
            )
        }

        inlineCodeStyle.applyOuterKerning(to: output, baseFont: baseFont)

        let links = markdownLinks(from: linkGroups, sourceEvents: sourceLinkEvents)
        return MarkdownParseResult(attributedString: output, links: links)
    }

    private struct ParsedLinkGroup {
        var range: NSRange
        let url: URL
        var visibleText: String
    }

    private enum SourceLinkKind {
        case explicit
        case bare
    }

    private struct SourceLinkEvent {
        let sourceRange: NSRange
        let kind: SourceLinkKind
        let visibleText: String
        let url: URL
    }

    private static func markdownLinks(from linkGroups: [ParsedLinkGroup], sourceEvents: [SourceLinkEvent]) -> [MarkdownLink] {
        var links: [MarkdownLink] = []
        var eventIndex = 0

        // Walk source and output link events together. Bare source events may
        // be detected even when Foundation emits no link run for them, so skip
        // unmatched bare events without looking past mismatching explicit ones.
        for group in linkGroups {
            var matchedEvent: SourceLinkEvent?

            while eventIndex < sourceEvents.count {
                let event = sourceEvents[eventIndex]
                eventIndex += 1

                if event.url == group.url, event.visibleText == group.visibleText {
                    matchedEvent = event
                    break
                }

                if event.kind == .explicit {
                    break
                }
            }

            if let event = matchedEvent, event.kind == .explicit {
                links.append(MarkdownLink(range: group.range, url: event.url))
            }
        }

        return links
    }

    private static func sourceLinkEvents(in markdown: String) -> [SourceLinkEvent] {
        let explicitEvents = explicitLinkEvents(in: markdown)
        let bareEvents = bareLinkEvents(in: markdown, excluding: explicitEvents.map { $0.sourceRange })
        return (explicitEvents + bareEvents).sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    private static func explicitLinkEvents(in markdown: String) -> [SourceLinkEvent] {
        var events: [SourceLinkEvent] = []
        var searchIndex = markdown.startIndex

        while let linkStart = markdown[searchIndex...].firstIndex(of: "[") {
            let nextSearchIndex = markdown.index(after: linkStart)

            guard !isEscaped(linkStart, in: markdown), !isImageLinkStart(linkStart, in: markdown) else {
                searchIndex = nextSearchIndex
                continue
            }

            let labelStart = markdown.index(after: linkStart)
            guard let labelEnd = closingBracket(in: markdown, from: labelStart) else {
                searchIndex = nextSearchIndex
                continue
            }

            let destinationStart = markdown.index(after: labelEnd)
            guard destinationStart < markdown.endIndex, markdown[destinationStart] == "(" else {
                searchIndex = nextSearchIndex
                continue
            }

            let destinationContentStart = markdown.index(after: destinationStart)
            guard let destinationEnd = closingParen(in: markdown, from: destinationContentStart) else {
                searchIndex = nextSearchIndex
                continue
            }

            let labelMarkdown = String(markdown[labelStart..<labelEnd])
            let destinationContent = String(markdown[destinationContentStart..<destinationEnd])
            guard let urlString = linkDestination(from: destinationContent),
                  let url = URL(string: urlString) else {
                searchIndex = nextSearchIndex
                continue
            }

            let sourceRange = NSRange(linkStart...destinationEnd, in: markdown)
            events.append(SourceLinkEvent(
                sourceRange: sourceRange,
                kind: .explicit,
                visibleText: renderedInlineText(from: labelMarkdown),
                url: url
            ))
            searchIndex = markdown.index(after: destinationEnd)
        }

        return events
    }

    private static func bareLinkEvents(in markdown: String, excluding excludedRanges: [NSRange]) -> [SourceLinkEvent] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        return detector.matches(in: markdown, options: [], range: fullRange).compactMap { match in
            guard let url = match.url,
                  url.scheme?.lowercased() != "mailto",
                  match.range.length > 2,
                  !isInsideBracketedText(match.range, in: markdown),
                  !excludedRanges.contains(where: { ActiveBuilder.rangesOverlap($0, match.range) }) else {
                return nil
            }

            let visibleText = nsMarkdown.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return SourceLinkEvent(
                sourceRange: match.range,
                kind: .bare,
                visibleText: visibleText,
                url: url
            )
        }
    }

    private static func renderedInlineText(from markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown
        }

        return String(parsed.characters)
    }

    private static func isInsideBracketedText(_ range: NSRange, in markdown: String) -> Bool {
        guard let stringRange = Range(range, in: markdown) else { return false }

        var index = stringRange.lowerBound
        var foundOpeningBracket = false
        while index > markdown.startIndex {
            let previous = markdown.index(before: index)
            if !isEscaped(previous, in: markdown) {
                if markdown[previous] == "]" || markdown[previous].isNewline {
                    return false
                }
                if markdown[previous] == "[" {
                    foundOpeningBracket = true
                    break
                }
            }
            index = previous
        }

        guard foundOpeningBracket else { return false }

        index = stringRange.upperBound
        while index < markdown.endIndex {
            if !isEscaped(index, in: markdown) {
                if markdown[index] == "[" || markdown[index].isNewline {
                    return false
                }
                if markdown[index] == "]" {
                    return true
                }
            }
            index = markdown.index(after: index)
        }

        return false
    }

    private static func isImageLinkStart(_ index: String.Index, in markdown: String) -> Bool {
        guard index > markdown.startIndex else { return false }
        let previous = markdown.index(before: index)
        return markdown[previous] == "!" && !isEscaped(previous, in: markdown)
    }

    private static func isEscaped(_ index: String.Index, in markdown: String) -> Bool {
        var cursor = index
        var slashCount = 0

        while cursor > markdown.startIndex {
            let previous = markdown.index(before: cursor)
            guard markdown[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }

        return slashCount % 2 == 1
    }

    private static func closingBracket(in markdown: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0

        while index < markdown.endIndex {
            if isEscaped(index, in: markdown) {
                index = markdown.index(after: index)
                continue
            }

            switch markdown[index] {
            case "[":
                depth += 1
            case "]":
                if depth == 0 {
                    return index
                }
                depth -= 1
            default:
                break
            }

            index = markdown.index(after: index)
        }

        return nil
    }

    private static func closingParen(in markdown: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0

        while index < markdown.endIndex {
            if isEscaped(index, in: markdown) {
                index = markdown.index(after: index)
                continue
            }

            switch markdown[index] {
            case "(":
                depth += 1
            case ")":
                if depth == 0 {
                    return index
                }
                depth -= 1
            default:
                break
            }

            index = markdown.index(after: index)
        }

        return nil
    }

    private static func linkDestination(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawDestination: String
        let destinationEnd: String.Index

        if trimmed.first == "<", let closingIndex = closingAngleBracket(in: trimmed, from: trimmed.index(after: trimmed.startIndex)) {
            let destinationStart = trimmed.index(after: trimmed.startIndex)
            guard destinationStart <= closingIndex else { return nil }
            rawDestination = String(trimmed[destinationStart..<closingIndex])
            destinationEnd = trimmed.index(after: closingIndex)
        } else {
            var index = trimmed.startIndex
            var depth = 0

            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character == "\\" {
                    let nextIndex = trimmed.index(after: index)
                    index = nextIndex < trimmed.endIndex ? trimmed.index(after: nextIndex) : nextIndex
                    continue
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if depth == 0, isWhitespace(character) {
                    break
                }

                index = trimmed.index(after: index)
            }

            guard index > trimmed.startIndex else { return nil }
            rawDestination = String(trimmed[..<index])
            destinationEnd = index
        }

        let title = String(trimmed[destinationEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty || isValidLinkTitle(title) else { return nil }

        return unescapedMarkdownEscapes(in: rawDestination)
    }

    private static func closingAngleBracket(in markdown: String, from start: String.Index) -> String.Index? {
        var index = start

        while index < markdown.endIndex {
            if markdown[index] == ">", !isEscaped(index, in: markdown) {
                return index
            }

            index = markdown.index(after: index)
        }

        return nil
    }

    private static func isValidLinkTitle(_ title: String) -> Bool {
        guard let first = title.first else { return true }

        let closingCharacter: Character
        switch first {
        case "\"":
            closingCharacter = "\""
        case "'":
            closingCharacter = "'"
        case "(":
            closingCharacter = ")"
        default:
            return false
        }

        var index = title.index(after: title.startIndex)
        while index < title.endIndex {
            if isEscaped(index, in: title) {
                index = title.index(after: index)
                continue
            }

            if title[index] == closingCharacter {
                let restStart = title.index(after: index)
                let rest = String(title[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.isEmpty
            }

            index = title.index(after: index)
        }

        return false
    }

    private static let markdownEscapablePunctuation = Set<Character>("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    private static func unescapedMarkdownEscapes(in text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "\\" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex, markdownEscapablePunctuation.contains(text[nextIndex]) {
                    output.append(text[nextIndex])
                    index = text.index(after: nextIndex)
                    continue
                }
            }

            output.append(text[index])
            index = text.index(after: index)
        }

        return output
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        return character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    enum BlockKind: Equatable {
        case body
        case header(level: Int)
        case codeBlock
        case orderedList
        case unorderedList
        case blockQuote
        case thematicBreak
    }

    struct BlockDescriptor {
        let identity: Int
        let kind: BlockKind
        let primaryPrefix: String
        let continuationPrefix: String
        let listItemIdentity: Int?
        let blockQuoteDepth: Int

        func prefix(isContinuingListItem: Bool) -> String {
            isContinuingListItem ? continuationPrefix : primaryPrefix
        }

        func paragraphStyle(baseFont: UIFont) -> NSParagraphStyle {
            let style: NSMutableParagraphStyle
            switch kind {
            case .header:
                style = MarkdownParser.headerParagraphStyle()
            case .codeBlock:
                style = MarkdownParser.codeParagraphStyle()
            case .orderedList, .unorderedList:
                style = MarkdownParser.listParagraphStyle()
            case .blockQuote:
                style = MarkdownParser.blockQuoteParagraphStyle()
            case .thematicBreak, .body:
                style = MarkdownParser.bodyParagraphStyle(baseFont: baseFont)
            }
            // Layer blockquote indent on top of any other block kind that
            // happens to be nested inside `> ...`.
            if blockQuoteDepth > 0, kind != .blockQuote {
                let extra = CGFloat(blockQuoteDepth) * MarkdownParser.blockQuoteIndent
                style.firstLineHeadIndent += extra
                style.headIndent += extra
            }
            return style
        }
    }

    private static func blockDescriptor(for intent: PresentationIntent?) -> BlockDescriptor {
        guard let intent else {
            return BlockDescriptor(
                identity: -1,
                kind: .body,
                primaryPrefix: "",
                continuationPrefix: "",
                listItemIdentity: nil,
                blockQuoteDepth: 0
            )
        }

        var paragraphIdentity: Int?
        var blockQuoteIdentity: Int?
        var listItemIdentity: Int?
        var blockQuoteDepth = 0
        var hasCodeBlock = false
        var hasThematicBreak = false
        var headerLevel: Int?
        var orderedList = false
        var unorderedList = false
        var ordinal: Int?

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                headerLevel = level
            case .paragraph:
                paragraphIdentity = component.identity
            case .blockQuote:
                blockQuoteIdentity = component.identity
                blockQuoteDepth += 1
            case .orderedList:
                orderedList = true
            case .unorderedList:
                unorderedList = true
            case .listItem(let number):
                listItemIdentity = component.identity
                ordinal = number
            case .codeBlock:
                hasCodeBlock = true
            case .thematicBreak:
                hasThematicBreak = true
            default:
                break
            }
        }

        if hasThematicBreak {
            return BlockDescriptor(
                identity: paragraphIdentity ?? -1,
                kind: .thematicBreak,
                primaryPrefix: "",
                continuationPrefix: "",
                listItemIdentity: nil,
                blockQuoteDepth: blockQuoteDepth
            )
        }

        if let level = headerLevel {
            return BlockDescriptor(
                identity: paragraphIdentity ?? -1,
                kind: .header(level: level),
                primaryPrefix: "",
                continuationPrefix: "",
                listItemIdentity: nil,
                blockQuoteDepth: blockQuoteDepth
            )
        }

        if hasCodeBlock {
            return BlockDescriptor(
                identity: paragraphIdentity ?? -1,
                kind: .codeBlock,
                primaryPrefix: "",
                continuationPrefix: "",
                listItemIdentity: nil,
                blockQuoteDepth: blockQuoteDepth
            )
        }

        if let listItemIdentity {
            if unorderedList {
                return BlockDescriptor(
                    identity: paragraphIdentity ?? listItemIdentity,
                    kind: .unorderedList,
                    primaryPrefix: "• ",
                    continuationPrefix: "  ",
                    listItemIdentity: listItemIdentity,
                    blockQuoteDepth: blockQuoteDepth
                )
            }
            if orderedList, let ordinal {
                let prefix = "\(ordinal). "
                return BlockDescriptor(
                    identity: paragraphIdentity ?? listItemIdentity,
                    kind: .orderedList,
                    primaryPrefix: prefix,
                    continuationPrefix: String(repeating: " ", count: prefix.count),
                    listItemIdentity: listItemIdentity,
                    blockQuoteDepth: blockQuoteDepth
                )
            }
        }

        if let blockQuoteIdentity {
            return BlockDescriptor(
                identity: paragraphIdentity ?? blockQuoteIdentity,
                kind: .blockQuote,
                primaryPrefix: "",
                continuationPrefix: "",
                listItemIdentity: nil,
                blockQuoteDepth: blockQuoteDepth
            )
        }

        return BlockDescriptor(
            identity: paragraphIdentity ?? -1,
            kind: .body,
            primaryPrefix: "",
            continuationPrefix: "",
            listItemIdentity: nil,
            blockQuoteDepth: blockQuoteDepth
        )
    }

    private static func attributes(baseFont: UIFont,
                                   textColor: UIColor,
                                   codeBackgroundColor: UIColor,
                                   inlineCodeStyle: MarkdownInlineCodeStyle,
                                   inlineIntent: InlinePresentationIntent?,
                                   presentationIntent: PresentationIntent?,
                                   link: URL?,
                                   block: BlockDescriptor) -> [NSAttributedString.Key: Any] {
        let isCodeBlock = block.kind == .codeBlock
        let isInlineCodeOnly = !isCodeBlock && inlineIntent?.contains(.code) == true

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(baseFont: baseFont, inlineIntent: inlineIntent, presentationIntent: presentationIntent),
            .paragraphStyle: block.paragraphStyle(baseFont: baseFont)
        ]

        if isInlineCodeOnly {
            // Apply caller's font scale on top of the monospaced face the
            // base `font(...)` already chose. Bold inside ** ** is layered
            // back in via the weight.
            if inlineCodeStyle.fontScale != 1.0 {
                let weight: UIFont.Weight = inlineIntent?.contains(.stronglyEmphasized) == true ? .bold : .regular
                attributes[.font] = UIFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize * inlineCodeStyle.fontScale,
                    weight: weight
                )
            }

            attributes[.foregroundColor] = inlineCodeStyle.foregroundColor ?? textColor

            switch inlineCodeStyle.backgroundMode {
            case .stockBackgroundColor:
                attributes[.backgroundColor] = codeBackgroundColor
            case .markerAttribute(let key):
                attributes[key] = true
            }
        } else {
            switch block.kind {
            case .blockQuote:
                attributes[.foregroundColor] = textColor.withAlphaComponent(0.8)
            default:
                attributes[.foregroundColor] = textColor
            }
            if isCodeBlock {
                attributes[.backgroundColor] = codeBackgroundColor
            }
        }

        if inlineIntent?.contains(.strikethrough) == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if let link {
            attributes[.link] = link
        }

        return attributes
    }

    private static func bodyAttributes(baseFont: UIFont, textColor: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: textColor,
            .paragraphStyle: bodyParagraphStyle(baseFont: baseFont)
        ]
    }

    // MARK: - Paragraph styles

    private static func headerParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 4
        style.baseWritingDirection = .natural
        return style
    }

    private static func bodyParagraphStyle(baseFont: UIFont) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        style.paragraphSpacingBefore = 2
        style.baseWritingDirection = .natural
        return style
    }

    private static func codeParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 4
        style.baseWritingDirection = .natural
        return style
    }

    private static func blockQuoteParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        style.paragraphSpacingBefore = 2
        style.firstLineHeadIndent = blockQuoteIndent
        style.headIndent = blockQuoteIndent
        style.baseWritingDirection = .natural
        return style
    }

    private static func listParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 2
        style.headIndent = listHangingIndent
        style.baseWritingDirection = .natural
        return style
    }

    private static func font(baseFont: UIFont,
                             inlineIntent: InlinePresentationIntent?,
                             presentationIntent: PresentationIntent?) -> UIFont {
        let headingLevel = headingLevel(in: presentationIntent)
        let scaledSize = baseFont.pointSize * headingScale(for: headingLevel)

        if inlineIntent?.contains(.code) == true {
            let weight: UIFont.Weight = inlineIntent?.contains(.stronglyEmphasized) == true || headingLevel != nil ? .bold : .regular
            return UIFont.monospacedSystemFont(ofSize: scaledSize, weight: weight)
        }

        var traits = baseFont.fontDescriptor.symbolicTraits
        if inlineIntent?.contains(.stronglyEmphasized) == true || headingLevel != nil {
            traits.insert(.traitBold)
        }
        if inlineIntent?.contains(.emphasized) == true {
            traits.insert(.traitItalic)
        }

        let sizedDescriptor = baseFont.fontDescriptor.withSize(scaledSize)
        if let descriptor = sizedDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: scaledSize)
        }

        let fallback = UIFont.systemFont(ofSize: scaledSize).fontDescriptor
        if let descriptor = fallback.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: scaledSize)
        }

        return UIFont.systemFont(ofSize: scaledSize)
    }

    private static func headingLevel(in intent: PresentationIntent?) -> Int? {
        guard let intent else { return nil }

        for component in intent.components {
            if case .header(let level) = component.kind {
                return level
            }
        }

        return nil
    }

    private static func headingScale(for level: Int?) -> CGFloat {
        switch level {
        case 1: return 1.6
        case 2: return 1.4
        case 3: return 1.25
        case 4: return 1.15
        case 5: return 1.1
        case 6: return 1.05
        default: return 1.0
        }
    }
}

private extension UIColor {
    /// Stable across appearance changes: keys both light and dark
    /// resolutions so dynamic colors hash the same in either trait.
    var activeLabelMarkdownCacheKey: String {
        let lightKey = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).activeLabelMarkdownRGBAString
        let darkKey = resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).activeLabelMarkdownRGBAString
        if lightKey == darkKey { return "fixed:\(lightKey)" }
        return "dyn:\(lightKey)|\(darkKey)"
    }

    private var activeLabelMarkdownRGBAString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(format: "%.4f:%.4f:%.4f:%.4f", red, green, blue, alpha)
        }
        return String(describing: self)
    }
}

#endif
