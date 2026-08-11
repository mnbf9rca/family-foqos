# Issue #193 Safe Preview Context Design

## Goal

Restore the four remaining blank SwiftUI previews that render `BlockedProfiles` through
`SafeModelView` or `@SafeQuery`, without weakening the production zombie-model safeguards.

## Root cause

`SafeModelView` and the `.valid` array extension intentionally reject a `PersistentModel` unless
it is registered with a live `ModelContext`. The three `BlockedProfileCarousel` previews construct
`BlockedProfiles` directly, so their models have no context and the carousel filters them out. A
`.modelContainer` modifier alone does not retroactively insert those already-created objects.

`ChildDashboardView` obtains its profiles through `@SafeQuery`. Its preview does not construct
models directly, but the query has no model container to read from.

## Design

Introduce a debug-only carousel preview fixture that:

- creates an in-memory `ModelContainer` for `BlockedProfiles`;
- creates the profiles for each existing preview scenario;
- inserts every profile into the container's main context before the view renders; and
- attaches that exact container to the carousel view.

Keep the existing active, inactive, and starting-profile scenarios. Centralizing their setup in
one fixture avoids three subtly different container lifetimes and makes registration directly
testable.

For `ChildDashboardView`, attach an in-memory `BlockedProfiles` model container to the preview.
Because `@SafeQuery` owns model retrieval there, no explicit seed insertion is required.

Do not change `SafeModelView`, `.valid`, or production persistence behavior.

## Verification

Add a focused unit test that constructs each carousel preview scenario and proves every supplied
profile is registered and valid. Run that test red before implementing the fixture, then green.
Compile the app to validate both preview declarations. Finally run the project test suite and the
repository checks through the serialized Xcode stream.

## Delivery

Ship #193 as its own branch and PR with a strict marketing/build version bump above `main`.
Request independent code review and require green CI before handing the PR to the planner for
merge.
