# ActiveLabel iOS 17 Modernization — Design

Date: 2026-05-01
Status: Draft v2 (post-review)
Target baseline: iOS 17, macCatalyst 17, Swift 5.9+

## Revision Notes

v2 changes from v1, driven by parallel review (pr-review-toolkit code-reviewer + Codex rescue) and TextKit 2 web research:

- **Dropped Bucket C** (TextKit 2 port). See §9 for rationale.
- **Added Bucket A8**: TK1 hit-test off-by-one fix (`<=` → `<`).
- **Reordered**: A3 (`_customizing` flip) merged into the B3 commit (drop `@IBInspectable`) so the transient init-time path never exists in main.
- **Inlined** `trim(to:)` at both call sites (production + test) before deleting `StringTrimExtension.swift`.
- **Fixed** `ActiveType.swift:40` removal — the `.url` case in `var pattern` is deleted alongside `RegexParser.urlPattern`.
- **Enumerated** URL-detection test deltas (§5.1) instead of deferring.
- **Specified** test seams (call counter, deinit cancellation pattern, RTL fixture).
- **Added** `xcodebuild test` for CI; SPM `swift test` is not viable for a UIKit-only target.
- **Added** overlap/collision contract: URL detector matches emails — explicit handling in §5.2.
- **Added** scope items: podspec version, README iOS-version + email-default mismatch, Xcode `SWIFT_VERSION`, project.pbxproj membership updates.

## 1. Goal & Scope

Modernize ActiveLabel for the iOS 17 baseline. Two buckets in one effort:

- **Bucket A — Dead/redundant deletes + TK1 bug fix** (no behavior change beyond fixing the off-by-one)
- **Bucket B — Modern replacements** (NSDataDetector for URLs, Swift Concurrency for delayed deselect, drop `@IBDesignable`/`@IBInspectable`)

Out of scope:
- TextKit 2 port (see §9)
- SwiftUI wrapper
- Public API redesign beyond what bucket B forces
- New feature work

Public API impact:

- Major version bump required.
- Breaking: `@IBDesignable`/`@IBInspectable` removed (Storyboard live-preview consumers affected; runtime use of properties unaffected).
- Source-compatible: `ActiveLabelDelegate: class` → `AnyObject`.
- Behavior delta: NSDataDetector-based URL detection matches a different set than the existing regex (see §5.1). Tests intentionally rejecting bare-domain detection will be updated with rationale.

## 2. Target Architecture

### File layout (post-refactor)

```
ActiveLabel/
  ActiveLabel.swift          # UILabel subclass, public API, touch handling, TK1 stack
  ActiveType.swift           # public enum + ActiveElement (synthesized Hashable)
  ActiveBuilder.swift        # element extraction (regex + NSDataDetector for .url)
  RegexParser.swift          # hashtag / mention / email patterns only
```

Removed: `StringTrimExtension.swift` (single 2-line method inlined at its two call sites).

TextKit 1 stack (`NSTextStorage`, `NSLayoutManager`, `NSTextContainer`, `drawText(in:)`) preserved unchanged. Only the off-by-one in hit-test logic is fixed.

### Component responsibilities (unchanged)

| Component | Responsibility |
|-----------|----------------|
| `ActiveLabel` | UILabel subclass. Public properties, handler registration, touch routing, customization batching. Owns the TK1 stack. |
| `ActiveBuilder` | Element extraction. URL via `NSDataDetector(types: .link)`, post-filtered for email collisions. Hashtag/mention/email/custom via regex. |
| `ActiveType` / `ActiveElement` | Public enum (unchanged externally). `Hashable` synthesized. Manual `==` removed. |
| `RegexParser` | Hashtag, mention, email patterns + cached `NSRegularExpression`. URL pattern deleted. |

### Concurrency

- `ActiveLabel` annotated `@MainActor` (UIKit). All public methods (`handleMentionTap`, `handleHashtagTap`, etc.) inherit `@MainActor` isolation. Source-compatible: callers already on main.
- `ActiveBuilder` static funcs `@MainActor` (called from main during `updateTextStorage`).
- `RegexParser` cache `@MainActor`-isolated static dictionary. Resolves the actor-isolation contradiction noted in v1 review.
- `NSDataDetector` instance: cached `@MainActor` static like the regex cache.

## 3. Bucket A — Deletes & TK1 Fix

| # | Location | Action | Verified |
|---|----------|--------|----------|
| A1 | `ActiveType.swift:47-68` | Delete manual `Hashable` impl + manual `==`. Add `Hashable` to enum declaration. | Swift synthesizes `Hashable`/`Equatable` for enums whose payloads are all `Hashable`. `String` is `Hashable`. Equivalence classes preserved. |
| A2 | `ActiveLabel.swift:12` | `protocol ActiveLabelDelegate: class` → `: AnyObject`. | `class` is a deprecated synonym for `AnyObject` since Swift 4.2. Source-compatible. |
| A3 | `ActiveLabel.swift:151, 157, 247` | Drop `_customizing = false` from both inits AND change default to `false`. **Land in same commit as B3.** | Without `@IBInspectable`, no nib-decoded property setters fire after `super.init`, so the guard is redundant. Co-locating with B3 ensures no transient state exists. |
| A4 | `StringTrimExtension.swift` | Delete file. Inline at both call sites: `ActiveBuilder.swift:46` and `ActiveLabelTests/ActiveTypeTests.swift:421` as `String(s.prefix(maxLength)) + "..."`. Remove file references from `ActiveLabel.xcodeproj/project.pbxproj` (around lines 20, 308). | Confirmed only two call sites by grep. |
| A5 | `.travis.yml` | Delete. Replaced by GitHub Actions in §7. | |
| A6 | `.swift-version` | Delete (Carthage-only artifact). | |
| A7 | `fileprivate` keywords throughout `ActiveLabel.swift` | Replace with `private` where possible, `internal` for test seams (see §6). Style only. Land as last commit so it doesn't muddy review of behavior changes. | |
| A8 | `ActiveLabel.swift:461` | Hit-test off-by-one fix: `index >= e.range.location && index <= e.range.location + e.range.length` → `index >= e.range.location && index < e.range.location + e.range.length`. | A tap exactly one character past the last glyph in an element no longer false-hits. Bug fix; document in changelog. |
| A9 | `ActiveType.swift:40` | When `RegexParser.urlPattern` is deleted (B1), the `case .url:` branch in `var pattern` must also be removed. The `pattern` accessor is only consulted for non-URL types after B1 lands. | Compile-break guard: do A9 in the same commit as B1. |

## 4. Bucket B — Replacements

### B1 — `NSDataDetector` for URLs

`RegexParser.swift:16-18` (`urlPattern`) deleted. `ActiveBuilder.createURLElements` rewritten:

```swift
@MainActor private static let urlDetector: NSDataDetector? =
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

static func createURLElements(from text: String,
                              range: NSRange,
                              maximumLength: Int?) -> ([ElementTuple], String) {
    guard let detector = urlDetector else { return ([], text) }
    let nsstring = text as NSString
    var working = text
    var elements: [ElementTuple] = []
    var matches = detector.matches(in: working, options: [], range: range)
    // Filter: skip results whose URL.scheme == "mailto" — those are emails handled separately (§5.2).
    matches = matches.filter { $0.url?.scheme?.lowercased() != "mailto" }

    // Process matches RIGHT-TO-LEFT so that any string mutation (trim) doesn't shift earlier ranges.
    for match in matches.reversed() where match.range.length > 2 {
        let word = nsstring.substring(with: match.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let maxLength = maximumLength, word.count > maxLength else {
            elements.append((match.range, .create(with: .url, text: word), .url))
            continue
        }
        let trimmed = String(word.prefix(maxLength)) + "..."
        // Splice trimmed text into `working` at the matched range, not via global replace.
        working = (working as NSString).replacingCharacters(in: match.range, with: trimmed)
        let newRange = NSRange(location: match.range.location, length: (trimmed as NSString).length)
        elements.append((newRange, .url(original: word, trimmed: trimmed), .url))
    }
    return (elements.reversed(), working)
}
```

Notes:
- Detector is cached and reused (cheap to construct, but no reason to rebuild per parse).
- `mailto:` filter handles the URL-vs-email collision (§5.2).
- Right-to-left processing eliminates the duplicate-URL trim bug from the existing implementation (where `replacingOccurrences(of: word, with: trimmedWord)` could rewrite the wrong instance and `range(of: trimmedWord)` only finds the first).
- Email regex stays in `RegexParser` (B1 only swaps URL detection).

### B2 — Swift Concurrency for delayed deselect

Replace `DispatchQueue.main.asyncAfter` at `ActiveLabel.swift:228-232`:

```swift
internal var pendingDeselectTask: Task<Void, Never>?  // internal for test access via @testable import

case .ended, .regionExited:
    guard let selected = selectedElement else { return avoidSuperCall }
    fireHandler(for: selected)
    pendingDeselectTask?.cancel()
    pendingDeselectTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self else { return }
        self.updateAttributesWhenSelected(false)
        self.selectedElement = nil
        self.pendingDeselectTask = nil
    }
    avoidSuperCall = true
```

Cancellation points (must be wired):
- New touch begins on a different element (replaces selection).
- `text` / `attributedText` setter (text changed underneath the pending deselect).
- `deinit` (cancel task to break any retain on the closure body — though `[weak self]` already prevents retain cycle, cancel is for behavioral correctness, not memory).

Reviewer-flagged risk: original code used strong `self` capture. The Task version uses `[weak self]` to ensure dealloc isn't blocked. The fact that `pendingDeselectTask` lives on `self` means Task lifetime ≤ self lifetime; cancel-on-deinit is precautionary.

### B3 — Drop `@IBDesignable` / `@IBInspectable`

Sites: `ActiveLabel.swift:19` (`@IBDesignable open class`), and `@IBInspectable` on `mentionColor`, `mentionSelectedColor`, `hashtagColor`, `hashtagSelectedColor`, `URLColor`, `URLSelectedColor`, `lineSpacing`, `minimumLineHeight`, `highlightFontName` (lines 30, 33, 36, 39, 42, 45, 54, 57, 60).

Properties remain `open var`, runtime-settable. Only Storyboard live-preview / nib decoding loses live editing in IB. Major version bump signals this.

A3 lands here: with `@IBInspectable` gone, the nib post-init property-setter cascade no longer exists, so `_customizing` defaulting to `false` is provably safe.

## 5. Behavior Deltas

### 5.1 URL detection — explicit test diff list

Existing regex requires scheme prefix or `www.` / `pic.`. NSDataDetector(.link) matches bare domains, IP literals, and other forms.

Tests in `ActiveLabelTests/ActiveTypeTests.swift` impacted (verified by reading the file):

| Test (line) | Input | Old expected | New (NSDataDetector) | Action |
|---|---|---|---|---|
| `:175` | `"http://www.google.com"` | match `http://www.google.com` | match (same) | keep |
| `:181` | `"https://www.google.com"` | match `https://www.google.com` | match (same) | keep |
| `:186` | `"http://www.google.com."` | match `http://www.google.com` (no trailing dot) | NSDataDetector excludes trailing punctuation; expect same | keep, verify in CI |
| `:191` | `"www.google.com"` | match `www.google.com` | match (same) | keep |
| `:196` | `"pic.twitter.com/YUGdEbUx"` | match | match (same) | keep |
| `:201` | `"google.com"` | **count == 0** | **count == 1** | **update**: change to `count == 1`, add comment citing major-version migration |
| `:309-319` | `"picfoo"`, `"wwwbar"` | count == 0 | count == 0 | keep |
| `:402` | `"https://twitter.com/twicket_app/status/..."` | trim path | trim path same | keep |

Documented in CHANGELOG entry "BREAKING: URL detection now matches bare domains (e.g. `google.com`)."

### 5.2 URL/email collision handling

`NSDataDetector(.link)` will match `mailto:` URLs and **also** plain email-looking strings as `mailto:` links. Email is parsed separately by regex with priority. Resolution:

- URL builder filters out detector matches whose `result.url?.scheme?.lowercased() == "mailto"`.
- Parse order in `parseTextAndExtractActiveElements` (`ActiveLabel.swift:353`) stays URL-first, but the post-filter prevents URL elements overlapping email regex matches. Test added: `"contact me at foo@bar.com"` produces exactly one `.email` element and zero `.url` elements when both types enabled.
- Custom regex types still parsed last; can overlap any prior type. Pre-existing behavior, documented but not changed.

### 5.3 Off-by-one fix

`ActiveLabel.swift:461` `<=` → `<`. Tap at exactly `range.location + range.length` no longer false-positives. Bug fix; document in changelog. New test added: tap at last character of element hits; tap one past misses.

### 5.4 Pending deselect cancellation

Old code's 250ms `asyncAfter` could not be cancelled, so a fast re-tap during the window would re-color, then the unrelated pending block would deselect, causing a flicker. New cancellable Task eliminates this. New test asserts no late deselect when a second tap arrives within 250ms.

## 6. Testing Strategy

### Existing tests

`ActiveLabelTests/ActiveTypeTests.swift` (438 LOC) ports unchanged except:
- URL test at line 201 updated per §5.1.
- One reference to `trim(to:)` at line 421 inlined per A4.

### New tests (added by bucket)

**Bucket A**
- `Set<ActiveType>` membership across `.mention`, `.hashtag`, `.url`, `.email`, `.custom("a")`, `.custom("a")` (dedupe), `.custom("b")`. Validates synthesized `Hashable`.
- Off-by-one (A8): tap at last glyph index of an element hits; one past misses. Fixture: known fixed-font text with one `#tag` at the start.

**Bucket B1**
- Bare domain match (`google.com`).
- Trailing-dot exclusion (`http://www.google.com.`).
- Duplicate URL trim: `"see https://very-long-url.example.com/path1 and https://very-long-url.example.com/path2"` with `urlMaximumLength = 25`. Both URLs trimmed independently with correct ranges. Regression test for the right-to-left rewrite.
- Mailto filter: detector match with `mailto:foo@bar.com` excluded.

**Bucket B2**
- Pending deselect cancelled on second tap within 250ms (re-color stays).
- Pending deselect runs on solo tap after 300ms wait.
- Deinit cancellation: `XCTestExpectation(description: "deselect should not fire").isInverted = true`. Hold a `weak var label`, fire `.began`/`.ended`, set strong reference to nil within 50ms, wait 300ms, expect inverted expectation passes (i.e. closure didn't run on dealloc'd ref).

**Bucket B3**
- Set `mentionColor` post-init at runtime → triggers re-render. (Confirms property still works after `@IBInspectable` removal.)

**Cross-cutting**
- Email/URL collision (§5.2): `"contact foo@bar.com"` with both enabled produces 1 email element, 0 url elements.
- RTL fixture: `"مرحبا @user #تصنيف"` parses to 1 mention + 1 hashtag, hit-testing returns valid (non-negative) indices for points inside the mention range.
- Truncation: set `numberOfLines = 1` on text that wraps, tap on visible portion still hits its element. Tap on truncation indicator (`...`) does not crash and returns nil element.

### Test seams (new `internal` API for tests)

- `ActiveLabel.element(at:)` promoted from `fileprivate` to `internal` for direct tap-routing tests.
- `ActiveLabel.updateTextStorageCallCount: Int` — `internal` counter incremented at top of `updateTextStorage`. Used to assert that `customize(block:)` produces exactly one call.
- `ActiveLabel.pendingDeselectTask: Task<Void, Never>?` — `internal` for tests that need to await/cancel.

### Test infrastructure

- **CI**: GitHub Actions workflow `.github/workflows/ci.yml` running `xcodebuild test -scheme ActiveLabel -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5'` on `macos-14` runner. **Not** `swift test` — UIKit imports preclude SPM test runs on macOS host.
- `Package.swift`: do **not** add a `.testTarget` for now. SPM testing of UIKit-only targets is not supported on macOS host. Tests stay in the Xcode project.
- Delete `.travis.yml`.

## 7. Build / Execution Order (TDD)

Each commit on a feature branch. Run `xcodebuild test` after each.

1. **CI baseline** — add GitHub Actions running `xcodebuild test`. Lock green baseline against `master` HEAD before any changes. Delete `.travis.yml`.
2. **Bucket A1** — synthesize `Hashable`. Tests stay green.
3. **Bucket A2** — `class` → `AnyObject`. Tests stay green.
4. **Bucket A4** — inline `trim(to:)`, delete `StringTrimExtension.swift`, update `project.pbxproj`. Tests stay green.
5. **Bucket A5, A6** — delete `.travis.yml` (superseded by step 1) and `.swift-version`. (A5 already done in step 1.)
6. **Bucket A8** — off-by-one fix. New hit-test test added first (TDD, fails on `<=`), then fix.
7. **Bucket B1 + A9** — new URL detector tests added first (TDD), implement detector + remove `RegexParser.urlPattern` + remove `.url` case from `ActiveType.pattern`. Update existing test at line 201 in same commit with rationale comment.
8. **Bucket B2** — cancellation tests added first (TDD), then `Task` implementation with deinit hook.
9. **Bucket B3 + A3** — drop `@IBDesignable`/`@IBInspectable`, flip `_customizing` default to `false`, drop init lines.
10. **Bucket A7** — `fileprivate` → `private`. Style commit.
11. **Metadata sync** — see §8.

## 8. Metadata & Documentation Updates

Bundled into one commit at the end of step 10 to avoid review noise:

- `ActiveLabel.podspec`: bump `s.version` from `1.1.6` to `2.0.0`. Update description if needed.
- `Package.swift`: confirm iOS 17 / macCatalyst 17 (already correct).
- `ActiveLabel.xcodeproj/project.pbxproj`: `SWIFT_VERSION = 5.0` → `5.9`. Remove `StringTrimExtension.swift` membership (handled in step 4).
- `README.md`:
  - Update install section: `iOS 10+` → `iOS 17+`.
  - Update Carthage reference (still valid but de-emphasize; CocoaPods + SPM are primary).
  - Fix email default mismatch: README says default is `[.mention, .hashtag, .url, .email]` but code is `[.mention, .hashtag, .url]`. Either change the code default to include `.email` (preferred — minor enhancement, ships with major) or update README to match code. **Decision: update code default to include `.email`** — the docs have advertised this for years; align reality with the docs as part of v2.0. Note as second non-breaking enhancement in changelog.
  - Add "URL detection now uses NSDataDetector" note with bare-domain example.
  - Add "Why TextKit 1" section linking §9 reasoning.
- `CHANGELOG.md` (create if missing): 2.0.0 entry summarizing breaking + behavioral changes.

## 9. Why Not TextKit 2 (this round)

Web research (early 2026):

- **Apple has not deprecated TextKit 1**. No `@available(*, deprecated)` on `NSLayoutManager` / `NSTextStorage` / `NSTextContainer` in iOS 17 SDK. Apple "encourages" migration; encouragement ≠ deadline.
- **TextKit 2 wins are editor-shaped**: viewport-driven non-linear layout, NSTextViewportLayoutController. ActiveLabel renders 1–5 lines. Net benefit ≈ 0.
- **TextKit 2 hit-testing is materially worse for tap routing**. TK1: `layoutManager.glyphIndex(for:in:)` — 1 line. TK2: `textLayoutFragment(for:)` → `enumerate textLineFragments` → `NSTextLineFragment.characterIndex(for:)` → manual coordinate-space conversion + document-offset reconstruction — 15–25 lines, with known coordinate bugs. For a library whose entire purpose is point-to-character routing, this is a regression.
- **Practitioner reports (2025)**: STTextView author Marcin Krzyżanowski calls TK2 "lacking and unexpectedly difficult to use correctly"; `usageBoundsForTextContainer` jitters; `textSelections(interactingAt:)` has known bugs (FB11898356). MarkEdit, CodeEdit, Runestone all abandoned TK2 for CodeMirror or CoreText. Apple's own Pages/Xcode/Notes do not use TK2.
- **No Swift "rich label" library has migrated to TK2** (verified by GitHub search): MLLabel, AttributedLabel, KILabel, ActiveLabel — all on TK1. Only full text editors have attempted, and they report friction.

Conclusion: keep TK1. Fix the known off-by-one (A8). Revisit if (a) Apple ships a deprecation attribute on TK1 APIs, or (b) a user reports a real complex-script rendering bug that TK2 would fix.

## 10. Open Questions

Honest list (down from "none"):

1. **Code default for `.email`** — change from `[.mention, .hashtag, .url]` to `[.mention, .hashtag, .url, .email]` to match README? §8 proposes yes. Confirm before step 11.
2. **`pic.` URL detection** — old regex matched `pic.twitter.com/...`. NSDataDetector matches it as a link. Verify in CI; no test currently asserts the behavior delta is identical here.
3. **TextKit 1 retention** — long-term, if Apple announces TK1 deprecation in WWDC26 or later, a follow-up project becomes urgent. Not today's problem; flagged for future tracking.

## 11. References

Cited during research:
- [Meet TextKit 2 — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [What's new in TextKit and text views — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10090/)
- [TextKit 2 — The Promised Land (Krzyżanowski, 2025)](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/)
- [Adopting TextKit 2 — Shadowfacts](https://shadowfacts.net/2022/textkit-2/)
- [Apple forum 708610](https://developer.apple.com/forums/thread/708610)
