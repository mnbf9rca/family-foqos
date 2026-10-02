# Corrections to the V1 leakage audit — 2026-10-02

The [original report](2026-10-02-v1-leakage-audit.md) is preserved byte for byte, including its appended tag/link findings. This note corrects its NFC casing statements; the [V2 conditions rulebook](../superpowers/specs/2026-10-02-508-v2-conditions-rulebook.md) uses the verified value.

The follow-up appendix's “lowercase hexadecimal” and “using `%02x`” statements are incorrect. At both audited revisions (`0fa5f9d92caddde49ec3e8f9e3859a254bdb3d59` and `8e4ee25e977116c17508ca0af20bfc6636f905f6`), `Foqos/Utils/NFCScannerUtil.swift:338–340` implements:

```swift
func hexEncodedString() -> String {
  return map { String(format: "%02hhX", $0) }.joined()
}
```

The matching key is therefore the chip UID rendered as **uppercase hexadecimal**, exactly as this function produces. Preserve that representation in existing Specific keys, Same session origins and private-account sync; changing it to lowercase would break comparisons. SavedTag's hashed CloudKit record name is separate from this matching identity. QR digest handling is unaffected.

Reviewer identified the error during #508 review; planner verified the source before recording this correction. The audit's historical recommendations remain evidence, with the later human rulings in the rulebook controlling product behaviour.
