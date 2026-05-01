# Changelog

## 2.0.0 — 2026-05-01

### Breaking changes
- iOS deployment target raised to 17.0 (was 10.0).
- `@IBDesignable` and `@IBInspectable` removed. Properties remain
  `open var` / `public var` and are settable at runtime; only Storyboard
  Attributes Inspector live-editing is affected.
- URL detection switched from a custom regex to
  `NSDataDetector(.link)`. Bare domains like `google.com` are now
  matched. The `testURL` case at line 201 of `ActiveTypeTests.swift`
  changed from `count == 0` to `count == 1` for `"google.com"`.

### Bug fixes
- Hit-test off-by-one: tapping exactly one character past the last
  glyph of an active element no longer falsely registers as that
  element.
- Duplicate-URL trim: when the same long URL appeared twice in a label
  with `urlMaximumLength` set, the second occurrence's range pointed at
  the wrong substring. Now each match is spliced independently.
- Pending deselect can no longer flicker: a fast retap during the 250ms
  deselect window now cancels the prior pending deselect.

### Enhancements
- Default `enabledTypes` now includes `.email`, matching the
  long-standing README claim.

### Internal changes
- TextKit 1 stack retained intentionally; see "Why TextKit 1?" in the
  README.
- Manual `Hashable`/`Equatable` for `ActiveType` replaced by Swift
  synthesis.
- `ActiveLabelDelegate: class` → `: AnyObject`.
- Delayed deselect uses `Task` + `Task.sleep` instead of
  `DispatchQueue.main.asyncAfter`.
- CI moved from Travis to GitHub Actions.

## 1.1.6
- Bump deployment target to iOS 17, add Mac Catalyst.

## 1.1.5
- Earlier history elided.
