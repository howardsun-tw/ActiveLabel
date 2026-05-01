//
//  ActiveBuilder.swift
//  ActiveLabel
//
//  Created by Pol Quintana on 04/09/16.
//  Copyright © 2016 Optonaut. All rights reserved.
//

import Foundation

typealias ActiveFilterPredicate = ((String) -> Bool)

struct ActiveBuilder {

    static func createElements(type: ActiveType, from text: String, range: NSRange, filterPredicate: ActiveFilterPredicate?) -> [ElementTuple] {
        switch type {
        case .mention, .hashtag:
            return createElementsIgnoringFirstCharacter(from: text, for: type, range: range, filterPredicate: filterPredicate)
        case .url:
            return createElements(from: text, for: type, range: range, filterPredicate: filterPredicate)
        case .custom:
            return createElements(from: text, for: type, range: range, minLength: 1, filterPredicate: filterPredicate)
        case .email:
            return createElements(from: text, for: type, range: range, filterPredicate: filterPredicate)
        }
    }

    @MainActor private static let urlDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    @MainActor static func createURLElements(from text: String,
                                             range: NSRange,
                                             maximumLength: Int?) -> ([ElementTuple], String) {
        guard let detector = urlDetector else { return ([], text) }
        let originalNSString = text as NSString
        var working = text

        let matches = detector.matches(in: text, options: [], range: range)
            .filter { $0.url?.scheme?.lowercased() != "mailto" }
            .filter { $0.range.length > 2 }

        var elements: [ElementTuple] = []
        // Cumulative shift between original-text locations and `working`
        // locations after prior splices to the LEFT of the current match.
        var offset = 0

        // Walk left-to-right so each splice only shifts ranges that have
        // not yet been processed. Track a running offset to translate
        // each match's original location into its position in `working`.
        for match in matches {
            let word = originalNSString.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let liveLocation = match.range.location + offset
            let liveRange = NSRange(location: liveLocation, length: match.range.length)

            guard let maxLength = maximumLength, word.count > maxLength else {
                let element = ActiveElement.create(with: .url, text: word)
                elements.append((liveRange, element, .url))
                continue
            }

            let trimmed = String(word.prefix(maxLength)) + "..."
            let trimmedNSLength = (trimmed as NSString).length
            working = (working as NSString).replacingCharacters(in: liveRange, with: trimmed)
            offset += trimmedNSLength - liveRange.length

            let newRange = NSRange(location: liveLocation, length: trimmedNSLength)
            let element = ActiveElement.url(original: word, trimmed: trimmed)
            elements.append((newRange, element, .url))
        }
        return (elements, working)
    }

    private static func createElements(from text: String,
                                            for type: ActiveType,
                                                range: NSRange,
                                                minLength: Int = 2,
                                                filterPredicate: ActiveFilterPredicate?) -> [ElementTuple] {

        let matches = RegexParser.getElements(from: text, with: type.pattern, range: range)
        let nsstring = text as NSString
        var elements: [ElementTuple] = []

        for match in matches where match.range.length > minLength {
            let word = nsstring.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if filterPredicate?(word) ?? true {
                let element = ActiveElement.create(with: type, text: word)
                elements.append((match.range, element, type))
            }
        }
        return elements
    }

    private static func createElementsIgnoringFirstCharacter(from text: String,
                                                                  for type: ActiveType,
                                                                      range: NSRange,
                                                                      filterPredicate: ActiveFilterPredicate?) -> [ElementTuple] {
        let matches = RegexParser.getElements(from: text, with: type.pattern, range: range)
        let nsstring = text as NSString
        var elements: [ElementTuple] = []

        for match in matches where match.range.length > 2 {
            let range = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            var word = nsstring.substring(with: range)
            if word.hasPrefix("@") {
                word.remove(at: word.startIndex)
            }
            else if word.hasPrefix("#") {
                word.remove(at: word.startIndex)
            }

            if filterPredicate?(word) ?? true {
                let element = ActiveElement.create(with: type, text: word)
                elements.append((match.range, element, type))
            }
        }
        return elements
    }
}
