# Rename-Invariant Log Privacy Taint Fix

## Problem

The log privacy analyzer currently decides whether to inspect a local value from its identifier
spelling. Renaming `displayInfo` to `label`, `member` to `m`, or `error` to `e` can therefore turn a
privacy finding into a pass without changing the value or log site. This is a critical bypass: the
analyzer enforces a naming convention instead of the privacy property.

## Decision

Replace name-triggered inspection with bounded semantic analysis inside the function containing each
log call. The analyzer will classify every non-allowlisted interpolation from declarations,
assignments, sensitive accessors, and stable message context. Identifier spelling will not determine
whether a value is inspected.

The analysis remains intentionally bounded rather than becoming a Swift type checker:

- declared sensitive types identify whole errors, participant/member objects, URLs, and coordinates;
- sensitive accessors such as `displayName`, `nameComponents`, `emailAddress`, and `phoneNumber`
  taint values regardless of receiver name;
- local assignments form a dependency graph, so taint propagates through renamed intermediates and
  ternaries such as `c = !a.isEmpty ? a : b`;
- stable literal context such as NFC, QR, and participant wording can add suspicion for otherwise
  opaque parameters;
- context never clears suspicion, and unresolved or ambiguous origins fail closed with exit 2 unless
  an adjacent counted `LOG-PRIVACY-SAFE` annotation documents an audit;
- existing semantic formatters and explicit safe accessors remain the only pass-oriented allowlist.

The zero-annotation production baseline remains unchanged. We will not default-deny every scalar
interpolation because that would require roughly one hundred annotations and make the escape hatch
too common to remain meaningful.

## Data Flow

For each `Log.*` call, the analyzer uses the source before that call, bounded to the current function.
It collects parameters, local declarations, and plain-identifier reassignments in source order,
including statements that begin after a semicolon. It extracts each assignment before the call and
classifies dependencies recursively with cycle protection. A value is sensitive if its declared
type, direct expression, or any dependency is sensitive. A value is safe only when an existing
semantic allowlist proves it safe. All other origins are ambiguous and fail closed.

Declaration tracking is deliberately conservative when a nested scope shadows an earlier binding
with the same name. The analyzer may retain the earlier taint and reject the interpolation rather
than trying to prove Swift scope dominance; this is intentional fail-closed behavior, not a signal
to weaken the rule or add an annotation without an audit.

Direct interpolation rules also become receiver-independent. In particular, `.displayName` is
sensitive on every receiver except explicit non-person presentation domains such as role, mode, and
rule type.

## Tests

Every identifier-bearing fail fixture gets a renamed twin that changes identifiers only and expects
the same status and diagnostic. The current analyzer must demonstrably fail this expanded suite
before production code changes.

The fixtures cover:

- renamed display-name receivers and whole participant/member objects;
- renamed `Error`, URL, coordinate, NFC, and QR parameters;
- renamed participant contact receivers;
- renamed intermediates that read participant identity fields;
- the exact multi-hop #359 shape using neutral locals `a`, `b`, and `c`;
- renamed direct-sink and nonliteral-message parameters;
- annotation accounting independent of the annotated identifier's name.

After GREEN, verification includes the full adversarial suite, the production analyzer with equal
discovered/analyzed counts and zero annotations, the uncached latency ceiling, RuboCop, recursive
Swift formatting, the focused formatter tests, the full iOS suite, and the Debug build. Independent
review must approve the semantic fix before merge.

## Out of Scope

This fix does not change the audited error formatter, add a cache, weaken fail-closed parsing, or
introduce general-purpose interprocedural Swift analysis. Calls that intentionally transform sensitive
data must use an already-audited formatter or a counted adjacent annotation.
