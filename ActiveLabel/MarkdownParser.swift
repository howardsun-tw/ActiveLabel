//
//  MarkdownParser.swift
//  ActiveLabel
//

import Foundation

#if canImport(UIKit)
import UIKit

struct MarkdownParseResult {
    let attributedString: NSMutableAttributedString
    let links: [MarkdownLink]
}

struct MarkdownLink {
    let range: NSRange
    let url: URL
}

enum MarkdownParser {

    static func parse(_ markdown: String, baseFont: UIFont) -> MarkdownParseResult {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return MarkdownParseResult(
                attributedString: NSMutableAttributedString(string: markdown, attributes: [.font: baseFont]),
                links: []
            )
        }

        let output = NSMutableAttributedString(string: "")
        let sourceLinkEvents = sourceLinkEvents(in: markdown)
        var linkGroups: [ParsedLinkGroup] = []
        var currentLinkGroup: ParsedLinkGroup?
        var currentBlockIdentity: Int?
        var currentListItemIdentity: Int?

        func finishCurrentLinkGroup() {
            if let group = currentLinkGroup {
                linkGroups.append(group)
                currentLinkGroup = nil
            }
        }

        for run in parsed.runs {
            let runText = String(parsed.characters[run.range])
            guard !runText.isEmpty else { continue }

            let block = blockDescriptor(for: run.presentationIntent)
            if currentBlockIdentity != block.identity {
                finishCurrentLinkGroup()
                if output.length > 0 {
                    output.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
                }
                let prefix = block.prefix(isContinuingListItem: block.listItemIdentity == currentListItemIdentity)
                if !prefix.isEmpty {
                    output.append(NSAttributedString(string: prefix, attributes: [.font: baseFont]))
                }
                currentBlockIdentity = block.identity
                currentListItemIdentity = block.listItemIdentity
            }

            let location = output.length
            let attributes = attributes(
                baseFont: baseFont,
                inlineIntent: run.inlinePresentationIntent,
                presentationIntent: run.presentationIntent,
                link: run.link
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
                attributedString: NSMutableAttributedString(string: markdown, attributes: [.font: baseFont]),
                links: []
            )
        }

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

    private struct BlockDescriptor {
        let identity: Int
        let primaryPrefix: String
        let continuationPrefix: String
        let listItemIdentity: Int?

        func prefix(isContinuingListItem: Bool) -> String {
            isContinuingListItem ? continuationPrefix : primaryPrefix
        }
    }

    private static func blockDescriptor(for intent: PresentationIntent?) -> BlockDescriptor {
        guard let intent else {
            return BlockDescriptor(identity: -1, primaryPrefix: "", continuationPrefix: "", listItemIdentity: nil)
        }

        var paragraphIdentity: Int?
        var blockQuoteIdentity: Int?
        var listItemIdentity: Int?
        var orderedList = false
        var unorderedList = false
        var ordinal: Int?

        for component in intent.components {
            switch component.kind {
            case .header:
                return BlockDescriptor(
                    identity: component.identity,
                    primaryPrefix: "",
                    continuationPrefix: "",
                    listItemIdentity: nil
                )
            case .paragraph:
                paragraphIdentity = component.identity
            case .blockQuote:
                blockQuoteIdentity = component.identity
            case .orderedList:
                orderedList = true
            case .unorderedList:
                unorderedList = true
            case .listItem(let number):
                listItemIdentity = component.identity
                ordinal = number
            default:
                break
            }
        }

        if let listItemIdentity {
            if unorderedList {
                return BlockDescriptor(
                    identity: paragraphIdentity ?? listItemIdentity,
                    primaryPrefix: "• ",
                    continuationPrefix: "  ",
                    listItemIdentity: listItemIdentity
                )
            }
            if orderedList, let ordinal {
                let prefix = "\(ordinal). "
                return BlockDescriptor(
                    identity: paragraphIdentity ?? listItemIdentity,
                    primaryPrefix: prefix,
                    continuationPrefix: String(repeating: " ", count: prefix.count),
                    listItemIdentity: listItemIdentity
                )
            }
        }

        if let blockQuoteIdentity {
            return BlockDescriptor(
                identity: paragraphIdentity ?? blockQuoteIdentity,
                primaryPrefix: "> ",
                continuationPrefix: "> ",
                listItemIdentity: nil
            )
        }

        return BlockDescriptor(
            identity: paragraphIdentity ?? -1,
            primaryPrefix: "",
            continuationPrefix: "",
            listItemIdentity: nil
        )
    }

    private static func attributes(baseFont: UIFont,
                                   inlineIntent: InlinePresentationIntent?,
                                   presentationIntent: PresentationIntent?,
                                   link: URL?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(baseFont: baseFont, inlineIntent: inlineIntent, presentationIntent: presentationIntent)
        ]

        if inlineIntent?.contains(.strikethrough) == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if let link {
            attributes[.link] = link
        }

        return attributes
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

#endif
