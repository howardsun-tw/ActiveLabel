//
//  ActiveLabel.swift
//  ActiveLabel
//
//  Created by Johannes Schickling on 9/4/15.
//  Copyright © 2015 Optonaut. All rights reserved.
//

import Foundation
import UIKit

public protocol ActiveLabelDelegate: AnyObject {
    func didSelect(_ text: String, type: ActiveType)
}

public typealias ConfigureLinkAttribute = (ActiveType, [NSAttributedString.Key : Any], Bool) -> ([NSAttributedString.Key : Any])
typealias ElementTuple = (range: NSRange, element: ActiveElement, type: ActiveType)

open class ActiveLabel: UILabel {
    
    // MARK: - public properties
    open weak var delegate: ActiveLabelDelegate?
    
    open var enabledTypes: [ActiveType] = [.mention, .hashtag, .url, .email]

    open var markdownText: String? {
        get { storedMarkdownText }
        set { applyMarkdownText(newValue) }
    }
    
    open var urlMaximumLength: Int?
    
    open var configureLinkAttribute: ConfigureLinkAttribute?
    
    open var mentionColor: UIColor = .blue {
        didSet { updateTextStorage(parseText: false) }
    }
    open var mentionSelectedColor: UIColor? {
        didSet { updateTextStorage(parseText: false) }
    }
    open var hashtagColor: UIColor = .blue {
        didSet { updateTextStorage(parseText: false) }
    }
    open var hashtagSelectedColor: UIColor? {
        didSet { updateTextStorage(parseText: false) }
    }
    open var URLColor: UIColor = .blue {
        didSet { updateTextStorage(parseText: false) }
    }
    open var URLSelectedColor: UIColor? {
        didSet { updateTextStorage(parseText: false) }
    }
    open var customColor: [ActiveType : UIColor] = [:] {
        didSet { updateTextStorage(parseText: false) }
    }
    open var customSelectedColor: [ActiveType : UIColor] = [:] {
        didSet { updateTextStorage(parseText: false) }
    }
    public var lineSpacing: CGFloat = 0 {
        didSet { updateTextStorage(parseText: false) }
    }
    public var minimumLineHeight: CGFloat = 0 {
        didSet { updateTextStorage(parseText: false) }
    }
    public var highlightFontName: String? = nil {
        didSet { updateTextStorage(parseText: false) }
    }
    public var highlightFontSize: CGFloat? = nil {
        didSet { updateTextStorage(parseText: false) }
    }
    
    // MARK: - Computed Properties
    private var hightlightFont: UIFont? {
        guard let highlightFontName = highlightFontName, let highlightFontSize = highlightFontSize else { return nil }
        return UIFont(name: highlightFontName, size: highlightFontSize)
    }
    
    // MARK: - public methods
    open func handleMentionTap(_ handler: @escaping (String) -> ()) {
        mentionTapHandler = handler
    }
    
    open func handleHashtagTap(_ handler: @escaping (String) -> ()) {
        hashtagTapHandler = handler
    }
    
    open func handleURLTap(_ handler: @escaping (URL) -> ()) {
        urlTapHandler = handler
    }
    
    open func handleCustomTap(for type: ActiveType, handler: @escaping (String) -> ()) {
        customTapHandlers[type] = handler
    }
    
    open func handleEmailTap(_ handler: @escaping (String) -> ()) {
        emailTapHandler = handler
    }
    
    open func removeHandle(for type: ActiveType) {
        switch type {
        case .hashtag:
            hashtagTapHandler = nil
        case .mention:
            mentionTapHandler = nil
        case .url:
            urlTapHandler = nil
        case .custom:
            customTapHandlers[type] = nil
        case .email:
            emailTapHandler = nil
        }
    }
    
    open func filterMention(_ predicate: @escaping (String) -> Bool) {
        mentionFilterPredicate = predicate
        updateTextStorage()
    }
    
    open func filterHashtag(_ predicate: @escaping (String) -> Bool) {
        hashtagFilterPredicate = predicate
        updateTextStorage()
    }
    
    // MARK: - override UILabel properties
    override open var text: String? {
        didSet {
            clearMarkdownStateForNonMarkdownAssignment()
            if !syncingTextStorageText {
                cancelPendingDeselectTask()
            }
            updateTextStorage()
        }
    }

    override open var attributedText: NSAttributedString? {
        didSet {
            clearMarkdownStateForNonMarkdownAssignment()
            cancelPendingDeselectTask()
            updateTextStorage()
        }
    }
    
    override open var font: UIFont! {
        didSet {
            if storedMarkdownText != nil, !applyingMarkdownText, !syncingTextStorageText {
                markdownBaseFont = font
            }
            updateTextStorage(parseText: false)
        }
    }
    
    override open var textColor: UIColor! {
        didSet { updateTextStorage(parseText: false) }
    }
    
    override open var textAlignment: NSTextAlignment {
        didSet { updateTextStorage(parseText: false)}
    }
    
    open override var numberOfLines: Int {
        didSet { textContainer.maximumNumberOfLines = numberOfLines }
    }
    
    open override var lineBreakMode: NSLineBreakMode {
        didSet { textContainer.lineBreakMode = lineBreakMode }
    }
    
    // MARK: - init functions
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupLabel()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupLabel()
    }
    
    open override func awakeFromNib() {
        super.awakeFromNib()
        updateTextStorage()
    }
    
    open override func drawText(in rect: CGRect) {
        let range = NSRange(location: 0, length: textStorage.length)
        
        textContainer.size = rect.size
        let newOrigin = textOrigin(inRect: rect)
        
        layoutManager.drawBackground(forGlyphRange: range, at: newOrigin)
        layoutManager.drawGlyphs(forGlyphRange: range, at: newOrigin)
    }
    
    
    // MARK: - customzation
    @discardableResult
    open func customize(_ block: (_ label: ActiveLabel) -> ()) -> ActiveLabel {
        _customizing = true
        block(self)
        _customizing = false
        updateTextStorage()
        return self
    }

    /// Test seam: synthesize the bookkeeping of a tap-end on the Nth active
    /// element across all types. Bypasses real touch routing for unit tests.
    internal func simulateTapEnded(onElementAt globalIndex: Int) {
        let flat = activeElements.flatMap { (type, elems) in elems.map { ($0, type) } }
        guard globalIndex < flat.count else { return }
        let (tuple, _) = flat[globalIndex]
        selectedElement = tuple
        updateAttributesWhenSelected(true)

        // Mirror the .ended branch deselect scheduling.
        scheduleDeselectTask()
    }

    /// Test seam: mirror the .began/.moved branch for selecting the Nth
    /// active element without constructing a UITouch.
    internal func simulateSelectionBegan(onElementAt globalIndex: Int) {
        let flat = activeElements.flatMap { (type, elems) in elems.map { ($0, type) } }
        guard globalIndex < flat.count else { return }
        let (tuple, _) = flat[globalIndex]
        cancelPendingDeselectTask()
        if tuple.range.location != selectedElement?.range.location || tuple.range.length != selectedElement?.range.length {
            updateAttributesWhenSelected(false)
            selectedElement = tuple
            updateAttributesWhenSelected(true)
        }
    }

    // MARK: - Auto layout
    
    open override var intrinsicContentSize: CGSize {
        guard let text = text, !text.isEmpty else {
            return .zero
        }

        textContainer.size = CGSize(width: self.preferredMaxLayoutWidth, height: CGFloat.greatestFiniteMagnitude)
        let size = layoutManager.usedRect(for: textContainer)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
    
    // MARK: - touch events
    func onTouch(_ touch: UITouch) -> Bool {
        let location = touch.location(in: self)
        var avoidSuperCall = false
        
        switch touch.phase {
        case .began, .moved, .regionEntered, .regionMoved:
            cancelPendingDeselectTask()
            if let element = element(at: location) {
                if element.range.location != selectedElement?.range.location || element.range.length != selectedElement?.range.length {
                    updateAttributesWhenSelected(false)
                    selectedElement = element
                    updateAttributesWhenSelected(true)
                }
                avoidSuperCall = true
            } else {
                updateAttributesWhenSelected(false)
                selectedElement = nil
            }
        case .ended, .regionExited:
            guard let selectedElement = selectedElement else { return avoidSuperCall }

            switch selectedElement.element {
            case .mention(let userHandle): didTapMention(userHandle)
            case .hashtag(let hashtag): didTapHashtag(hashtag)
            case .url(let originalURL, _): didTapStringURL(originalURL)
            case .custom(let element): didTap(element, for: selectedElement.type)
            case .email(let element): didTapStringEmail(element)
            }

            scheduleDeselectTask()
            avoidSuperCall = true
        case .cancelled:
            cancelPendingDeselectTask()
            updateAttributesWhenSelected(false)
            selectedElement = nil
        case .stationary:
            break
        @unknown default:
            break
        }
        
        return avoidSuperCall
    }
    
    // MARK: - private properties
    private var _customizing: Bool = false
    private var storedMarkdownText: String?
    private var applyingMarkdownText: Bool = false
    private var syncingTextStorageText: Bool = false
    private var markdownBaseFont: UIFont?
    private var markdownLinkElements: [ElementTuple] = []
    private var defaultCustomColor: UIColor = .black
    
    internal var mentionTapHandler: ((String) -> ())?
    internal var hashtagTapHandler: ((String) -> ())?
    internal var urlTapHandler: ((URL) -> ())?
    internal var emailTapHandler: ((String) -> ())?
    internal var customTapHandlers: [ActiveType : ((String) -> ())] = [:]

    internal var pendingDeselectTask: Task<Void, Never>?
    internal var onDeselectForTest: (() -> Void)?
    internal var updateTextStorageCallCount: Int = 0

    private var mentionFilterPredicate: ((String) -> Bool)?
    private var hashtagFilterPredicate: ((String) -> Bool)?

    private var selectedElement: ElementTuple?
    private var selectedElementOriginalAttributes: [(NSRange, [NSAttributedString.Key: Any])] = []
    private var heightCorrection: CGFloat = 0
    internal lazy var textStorage = NSTextStorage()
    private lazy var layoutManager = NSLayoutManager()
    private lazy var textContainer = NSTextContainer()
    lazy var activeElements = [ActiveType: [ElementTuple]]()
    
    // MARK: - helper functions

    private func applyMarkdownText(_ markdown: String?) {
        storedMarkdownText = markdown
        markdownBaseFont = markdown == nil ? nil : font
        markdownLinkElements.removeAll()
        cancelPendingDeselectTask()

        applyingMarkdownText = true
        defer { applyingMarkdownText = false }

        guard let markdown else {
            attributedText = nil
            return
        }

        attributedText = markdownAttributedString(from: markdown)
    }

    private func markdownAttributedString(from markdown: String) -> NSAttributedString {
        let result = MarkdownParser.parse(markdown, baseFont: markdownBaseFont ?? font)
        markdownLinkElements = result.links.map { link in
            let visibleText = result.attributedString.attributedSubstring(from: link.range).string
            return (link.range, ActiveElement.url(original: link.url.absoluteString, trimmed: visibleText), .url)
        }
        return result.attributedString
    }

    private func clearMarkdownStateForNonMarkdownAssignment() {
        guard !applyingMarkdownText, !syncingTextStorageText else { return }
        storedMarkdownText = nil
        markdownBaseFont = nil
        markdownLinkElements.removeAll()
    }
    
    private func setupLabel() {
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = lineBreakMode
        textContainer.maximumNumberOfLines = numberOfLines
        isUserInteractionEnabled = true
    }
    
    private func updateTextStorage(parseText: Bool = true) {
        updateTextStorageCallCount += 1
        if _customizing { return }
        resetSelectionState()

        let sourceAttributedText: NSAttributedString?
        let shouldParseText: Bool
        if let markdown = storedMarkdownText {
            markdownLinkElements.removeAll()
            sourceAttributedText = markdownAttributedString(from: markdown)
            shouldParseText = true
        } else {
            sourceAttributedText = attributedText
            shouldParseText = parseText
        }

        // clean up previous active elements
        guard let sourceAttributedText = sourceAttributedText, sourceAttributedText.length > 0 else {
            clearActiveElements()
            textStorage.setAttributedString(NSAttributedString())
            setNeedsDisplay()
            return
        }
        
        let mutAttrString = addLineBreak(sourceAttributedText)
        
        if shouldParseText {
            clearActiveElements()
            parseTextAndExtractActiveElements(mutAttrString)
        }
        
        addLinkAttribute(mutAttrString)
        textStorage.setAttributedString(mutAttrString)
        _customizing = true
        syncingTextStorageText = true
        text = mutAttrString.string
        syncingTextStorageText = false
        _customizing = false
        setNeedsDisplay()
    }
    
    private func clearActiveElements() {
        selectedElement = nil
        selectedElementOriginalAttributes.removeAll()
        for (type, _) in activeElements {
            activeElements[type]?.removeAll()
        }
    }

    private func cancelPendingDeselectTask() {
        pendingDeselectTask?.cancel()
        pendingDeselectTask = nil
    }

    private func resetSelectionState() {
        selectedElement = nil
        selectedElementOriginalAttributes.removeAll()
    }

    private func scheduleDeselectTask() {
        cancelPendingDeselectTask()
        pendingDeselectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.updateAttributesWhenSelected(false)
            self.resetSelectionState()
            self.pendingDeselectTask = nil
            self.onDeselectForTest?()
        }
    }
    
    private func textOrigin(inRect rect: CGRect) -> CGPoint {
        let usedRect = layoutManager.usedRect(for: textContainer)
        heightCorrection = (rect.height - usedRect.height)/2
        let glyphOriginY = heightCorrection > 0 ? rect.origin.y + heightCorrection : rect.origin.y
        return CGPoint(x: rect.origin.x, y: glyphOriginY)
    }
    
    /// add link attribute
    private func addLinkAttribute(_ mutAttrString: NSMutableAttributedString) {
        applyBaseAttributes(to: mutAttrString)
        var pendingAttributes: [(NSRange, [NSAttributedString.Key: Any])] = []

        for (type, elements) in activeElements {
            for element in elements where isValidRange(element.range, in: mutAttrString) {
                mutAttrString.enumerateAttributes(in: element.range, options: []) { attributes, range, _ in
                    pendingAttributes.append((range, activeAttributes(for: type, baseAttributes: attributes, isSelected: false)))
                }
            }
        }

        for (range, attributes) in pendingAttributes {
            mutAttrString.setAttributes(attributes, range: range)
        }
    }

    private func activeAttributes(
        for type: ActiveType,
        baseAttributes: [NSAttributedString.Key: Any],
        isSelected: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes

        if isSelected {
            switch type {
            case .mention:
                attributes[.foregroundColor] = mentionSelectedColor ?? mentionColor
            case .hashtag:
                attributes[.foregroundColor] = hashtagSelectedColor ?? hashtagColor
            case .url:
                attributes[.foregroundColor] = URLSelectedColor ?? URLColor
            case .custom:
                let possibleSelectedColor = customSelectedColor[type] ?? customColor[type]
                attributes[.foregroundColor] = possibleSelectedColor ?? defaultCustomColor
            case .email:
                attributes[.foregroundColor] = URLSelectedColor ?? URLColor
            }
        } else {
            switch type {
            case .mention:
                attributes[.foregroundColor] = mentionColor
            case .hashtag:
                attributes[.foregroundColor] = hashtagColor
            case .url:
                attributes[.foregroundColor] = URLColor
            case .custom:
                attributes[.foregroundColor] = customColor[type] ?? defaultCustomColor
            case .email:
                attributes[.foregroundColor] = URLColor
            }
        }

        if let highlightFont = hightlightFont {
            attributes[.font] = highlightFont
        }

        if let configureLinkAttribute = configureLinkAttribute {
            attributes = configureLinkAttribute(type, attributes, isSelected)
        }

        return attributes
    }

    private func applyBaseAttributes(to mutAttrString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: mutAttrString.length)
        var pendingAttributes: [(NSRange, [NSAttributedString.Key: Any])] = []

        mutAttrString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var additions: [NSAttributedString.Key: Any] = [:]
            if attributes[.font] == nil {
                additions[.font] = font!
            }
            if attributes[.foregroundColor] == nil {
                additions[.foregroundColor] = textColor
            }
            if !additions.isEmpty {
                pendingAttributes.append((range, additions))
            }
        }

        for (range, attributes) in pendingAttributes {
            mutAttrString.addAttributes(attributes, range: range)
        }
    }

    /// use regex check all link ranges
    private func parseTextAndExtractActiveElements(_ attrString: NSMutableAttributedString) {
        var textString = attrString.string
        var textLength = textString.utf16.count
        var textRange = NSRange(location: 0, length: textLength)
        let markdownURLs = markdownLinkElements.filter { isValidRange($0.range, in: attrString) }
        var protectedRanges = markdownURLs.map { $0.range }

        if enabledTypes.contains(.url) {
            let result = ActiveBuilder.createURLElements(
                from: textString,
                range: textRange,
                maximumLength: urlMaximumLength,
                excluding: protectedRanges
            )
            apply(result.replacements, to: attrString)

            let adjustedMarkdownURLs = adjust(markdownURLs, for: result.replacements)
            activeElements[.url] = adjustedMarkdownURLs + result.elements
            protectedRanges = adjustedMarkdownURLs.map { $0.range }

            textString = attrString.string
            textLength = textString.utf16.count
            textRange = NSRange(location: 0, length: textLength)
        }

        for type in enabledTypes where type != .url {
            var filter: ((String) -> Bool)? = nil
            if type == .mention {
                filter = mentionFilterPredicate
            } else if type == .hashtag {
                filter = hashtagFilterPredicate
            }

            let elements = ActiveBuilder.createElements(
                type: type,
                from: textString,
                range: textRange,
                filterPredicate: filter
            ).filter { element in
                !protectedRanges.contains { ActiveBuilder.rangesOverlap($0, element.range) }
            }
            activeElements[type] = elements
        }
    }

    private func apply(_ replacements: [TextReplacement], to attrString: NSMutableAttributedString) {
        for replacement in replacements.reversed() {
            attrString.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
    }

    private func adjust(_ elements: [ElementTuple], for replacements: [TextReplacement]) -> [ElementTuple] {
        return elements.compactMap { element in
            var adjustedRange = element.range

            for replacement in replacements {
                if ActiveBuilder.rangesOverlap(element.range, replacement.range) {
                    return nil
                }

                if replacement.range.location < element.range.location {
                    adjustedRange.location += replacement.delta
                }
            }

            return (adjustedRange, element.element, element.type)
        }
    }

    private func isValidRange(_ range: NSRange, in attrString: NSAttributedString) -> Bool {
        return range.location >= 0 && range.length >= 0 && range.location + range.length <= attrString.length
    }
    
    /// add line break mode
    private func addLineBreak(_ attrString: NSAttributedString) -> NSMutableAttributedString {
        let mutAttrString = NSMutableAttributedString(attributedString: attrString)
        let fullRange = NSRange(location: 0, length: mutAttrString.length)
        var pendingParagraphStyles: [(NSRange, NSMutableParagraphStyle)] = []

        mutAttrString.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            let paragraphStyle = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = NSLineBreakMode.byWordWrapping
            paragraphStyle.alignment = textAlignment
            paragraphStyle.lineSpacing = lineSpacing
            paragraphStyle.minimumLineHeight = minimumLineHeight > 0 ? minimumLineHeight: self.font.pointSize * 1.14
            pendingParagraphStyles.append((range, paragraphStyle))
        }

        for (range, paragraphStyle) in pendingParagraphStyles {
            mutAttrString.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        }
        
        return mutAttrString
    }
    
    private func updateAttributesWhenSelected(_ isSelected: Bool) {
        guard let selectedElement = selectedElement else {
            return
        }

        guard isValidRange(selectedElement.range, in: textStorage) else {
            return
        }

        let type = selectedElement.type
        var pendingAttributes: [(NSRange, [NSAttributedString.Key: Any])] = []

        if isSelected {
            selectedElementOriginalAttributes.removeAll()
            textStorage.enumerateAttributes(in: selectedElement.range, options: []) { attributes, range, _ in
                selectedElementOriginalAttributes.append((range, attributes))
                pendingAttributes.append((range, activeAttributes(for: type, baseAttributes: attributes, isSelected: true)))
            }
        } else if !selectedElementOriginalAttributes.isEmpty {
            pendingAttributes = selectedElementOriginalAttributes
            selectedElementOriginalAttributes.removeAll()
        } else {
            textStorage.enumerateAttributes(in: selectedElement.range, options: []) { attributes, range, _ in
                pendingAttributes.append((range, activeAttributes(for: type, baseAttributes: attributes, isSelected: false)))
            }
        }

        for (range, attributes) in pendingAttributes {
            textStorage.setAttributes(attributes, range: range)
        }
        
        setNeedsDisplay()
    }
    
    internal func element(at location: CGPoint) -> ElementTuple? {
        guard textStorage.length > 0 else {
            return nil
        }
        
        var correctLocation = location
        correctLocation.y -= heightCorrection
        let boundingRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: textStorage.length), in: textContainer)
        guard boundingRect.contains(correctLocation) else {
            return nil
        }
        
        let index = layoutManager.glyphIndex(for: correctLocation, in: textContainer)
        
        for element in activeElements.map({ $0.1 }).joined() {
            if index >= element.range.location && index < element.range.location + element.range.length {
                return element
            }
        }
        
        return nil
    }
    
    
    //MARK: - Handle UI Responder touches
    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if onTouch(touch) { return }
        super.touchesBegan(touches, with: event)
    }
    
    open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if onTouch(touch) { return }
        super.touchesMoved(touches, with: event)
    }
    
    open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        _ = onTouch(touch)
        super.touchesCancelled(touches, with: event)
    }
    
    open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if onTouch(touch) { return }
        super.touchesEnded(touches, with: event)
    }
    
    //MARK: - ActiveLabel handler
    private func didTapMention(_ username: String) {
        guard let mentionHandler = mentionTapHandler else {
            delegate?.didSelect(username, type: .mention)
            return
        }
        mentionHandler(username)
    }
    
    private func didTapHashtag(_ hashtag: String) {
        guard let hashtagHandler = hashtagTapHandler else {
            delegate?.didSelect(hashtag, type: .hashtag)
            return
        }
        hashtagHandler(hashtag)
    }
    
    private func didTapStringURL(_ stringURL: String) {
        guard let urlHandler = urlTapHandler, let url = URL(string: stringURL) else {
            delegate?.didSelect(stringURL, type: .url)
            return
        }
        urlHandler(url)
    }
    
    private func didTapStringEmail(_ stringEmail: String) {
        guard let emailHandler = emailTapHandler else {
            delegate?.didSelect(stringEmail, type: .email)
            return
        }
        emailHandler(stringEmail)
    }
    
    private func didTap(_ element: String, for type: ActiveType) {
        guard let elementHandler = customTapHandlers[type] else {
            delegate?.didSelect(element, type: type)
            return
        }
        elementHandler(element)
    }

    deinit {
        pendingDeselectTask?.cancel()
    }
}

extension ActiveLabel: UIGestureRecognizerDelegate {
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
