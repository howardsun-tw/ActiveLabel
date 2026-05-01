//
//  MarkdownParser.swift
//  ActiveLabel
//

import Foundation
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
        var links: [MarkdownLink] = []
        var currentBlockIdentity: Int?
        var currentListItemIdentity: Int?

        for run in parsed.runs {
            let runText = String(parsed.characters[run.range])
            guard !runText.isEmpty else { continue }

            let block = blockDescriptor(for: run.presentationIntent)
            if currentBlockIdentity != block.identity {
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

            if let url = run.link {
                links.append(MarkdownLink(
                    range: NSRange(location: location, length: (runText as NSString).length),
                    url: url
                ))
            }
        }

        if output.length == 0, !markdown.isEmpty {
            return MarkdownParseResult(
                attributedString: NSMutableAttributedString(string: markdown, attributes: [.font: baseFont]),
                links: []
            )
        }

        return MarkdownParseResult(attributedString: output, links: links)
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
