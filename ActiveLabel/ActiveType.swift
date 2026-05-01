//
//  ActiveType.swift
//  ActiveLabel
//
//  Created by Johannes Schickling on 9/4/15.
//  Copyright © 2015 Optonaut. All rights reserved.
//

import Foundation

enum ActiveElement {
    case mention(String)
    case hashtag(String)
    case email(String)
    case url(original: String, trimmed: String)
    case custom(String)
    
    static func create(with activeType: ActiveType, text: String) -> ActiveElement {
        switch activeType {
        case .mention: return mention(text)
        case .hashtag: return hashtag(text)
        case .email: return email(text)
        case .url: return url(original: text, trimmed: text)
        case .custom: return custom(text)
        }
    }
}

public enum ActiveType: Hashable {
    case mention
    case hashtag
    case url
    case email
    case custom(pattern: String)

    var pattern: String {
        switch self {
        case .mention: return RegexParser.mentionPattern
        case .hashtag: return RegexParser.hashtagPattern
        case .url: return ""  // unused: URL detection runs through NSDataDetector
        case .email: return RegexParser.emailPattern
        case .custom(let regex): return regex
        }
    }
}
