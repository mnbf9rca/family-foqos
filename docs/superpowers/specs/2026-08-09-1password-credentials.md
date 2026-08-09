# App Store Connect Credentials: 1Password, direnv, and Key Rotation

**Date:** 2026-08-09
**Status:** Approved design; implementation plan is a separate step
**Scope:** Local Fastlane credentials for V2 / `main`; resolves storage issue
[#365](https://github.com/mnbf9rca/family-foqos/issues/365) and makes the rotation from
[#364](https://github.com/mnbf9rca/family-foqos/issues/364) part of the migration cutover.

## Problem

The current App Store Connect (ASC) private key is a long-lived plaintext `.p8` file under the
maintainer's home directory. A gitignored `fastlane/.env` supplies its path, key ID, and issuer ID.
This protects the private key from git, but not from another process running as the user, and it
provides no scoped access, access record, or convenient revocation mechanism.

Issue #364 makes the migration urgent enough to include rotation. A verification command in the
committed Fastlane plan invoked `fastlane run app_store_connect_api_key`. That action returns a hash
whose `:key` member is the complete private key, so Fastlane printed the key into a local agent
session transcript. The transcript was not committed, pushed, or messaged elsewhere, but it now
contains the private half of the credential. Separately, this public repository contains the old
key ID, issuer ID, and local key path in the existing Fastlane plan and spec. Those identifiers do
not authenticate on their own, but together with the transcript they are all the inputs needed to
use the old private key. Rotation, rather than document deletion, is the security boundary because
git history and forks retain already-published identifiers.

The target state has one durable source of truth for ASC credentials: 1Password. The repository
contains only 1Password secret references. Fastlane resolves the references when a lane starts,
keeps the private key in process memory, and materializes it only in narrowly scoped temporary
files when a downstream Apple tool requires a path.

## Constraints

- The repository is public. No private key, service-account token, resolved environment value, new
  key ID, new issuer ID, or machine-specific key path may be committed.
- The replacement ASC key is created during this migration. There is no period where the new key is
  durably stored as a plaintext home-directory credential.
- ASC key creation normally produces a one-time browser download. This design therefore does not
  claim a diskless cutover. It minimizes that initial file's lifetime and treats revocation, not
  best-effort file erasure on APFS/SSD storage, as the security boundary.
- Truly unattended lanes must not wait indefinitely for a biometric prompt. The design must also
  retain a usable personal/biometric mode for maintainers who do not accept a new service-account
  token.
- The credential setup composes with #363 through one named interface: the **session-start unlock
  step**. This design does not depend on that step's internal implementation.
- `xcodebuild -allowProvisioningUpdates` may need ASC authentication for automatic signing.
  `-authenticationKeyPath` accepts a file path, not in-memory key content. Xcode documents the path,
  key ID, and issuer ID as a required set
  (`/Applications/Xcode.app/Contents/Developer/usr/share/man/man1/xcodebuild.1:244-265`).
- This task changes documentation only. Later implementation must preserve the existing lane
  behavior and must not run a submission merely to test credential loading.
- The migration must not introduce another credential-printing probe. In particular, never invoke
  `fastlane run` for an action that returns credential material.

## Options

### Option A — read-only 1Password service account (recommended)

Create a dedicated non-built-in automation vault containing only the Family Foqos ASC item. Give a
service account `read_items` access to that vault and inject its token into the worker session as
`OP_SERVICE_ACCOUNT_TOKEN`. The service account cannot use a Personal, Private, Employee, or default
Shared vault, so a dedicated vault is required. Its access can be limited, inspected, rotated, and
revoked. These constraints follow 1Password's
[service-account model](https://www.1password.dev/service-accounts/get-started) and
[CLI authentication contract](https://www.1password.dev/service-accounts/use-with-1password-cli).

This is the reliable unattended mode: `op read` does not require a biometric interaction once the
token is present. The trade-off is real: `OP_SERVICE_ACCOUNT_TOKEN` is itself a long-lived secret in
the worker's environment. It must never live in `.envrc`, an env file, shell history, or the repo.
The session-start unlock step owns injecting it from an operator-approved secret store. Limiting the
account to a one-item vault makes compromise narrower than today's raw, effectively immortal `.p8`,
and the token is revocable and its use report is inspectable.

**Status: RECOMMENDED, OPEN-FOR-MAINTAINER.** The maintainer chooses whether the unattended benefit
justifies custody of this new token.

### Option B — personal 1Password app integration with biometrics

If `OP_SERVICE_ACCOUNT_TOKEN` is absent, `op` uses the maintainer's personal 1Password CLI/app
integration. The session-start unlock step performs the biometric warm-up before unattended work.
This avoids a service token, attributes access to the maintainer, and uses the existing 1Password
unlock boundary described by the
[1Password app integration](https://www.1password.dev/cli/app-integration).

The limitation is that a later app relock can reintroduce a prompt during a lane. A warm-up reduces
that risk but cannot make long-running work as deterministic as service-account authentication.

**Status: SUPPORTED FALLBACK, OPEN-FOR-MAINTAINER.** Use this when interactive authorization is an
acceptable condition of a release session.

### Option C — retain a standing `.p8` for Xcode

Keep `~/.appstoreconnect/` solely for `xcodebuild` while using 1Password for Fastlane API actions.
This avoids temporary-file plumbing but leaves the highest-value secret at rest and defeats the
migration's purpose.

**Status: REJECTED.** The small implementation saving is not worth preserving the original risk.

## Recommendation

### One committed `.envrc`, two authentication modes

Use one `.envrc` for Options A and B. It exports literal 1Password references, not resolved values:

```bash
export ASC_KEY_ID_REF='op://<automation-vault>/<asc-item>/key-id'
export ASC_ISSUER_ID_REF='op://<automation-vault>/<asc-item>/issuer-id'
export ASC_KEY_CONTENT_BASE64_REF='op://<automation-vault>/<asc-item>/private-key-base64'
```

The file needs no authentication branch. When `OP_SERVICE_ACCOUNT_TOKEN` is present, 1Password CLI
uses the service account; otherwise it uses personal app integration. Fastlane resolves the three
references at lane start. This keeps the actual ASC key out of the interactive shell environment
and makes the maintainer's authentication choice runtime configuration rather than a second config
file.

The vault and item names are **OPEN-FOR-MAINTAINER**. The item name must describe the application,
not embed the ASC key ID. Implementation replaces the placeholders once those names are selected.

The committed setup flow is:

1. Install the 1Password CLI and direnv; configure personal app integration if Option B is used.
2. Add the direnv hook to the shell once.
3. Review `.envrc`, then run `direnv allow .`. A changed `.envrc` requires a fresh allow.
4. Enter through the session-start unlock step. It either injects `OP_SERVICE_ACCOUNT_TOKEN` for
   Option A or warms personal biometric access for Option B.

Add `.direnv/` to `.gitignore`. Do not ignore `.envrc`: it is the reviewed, committed replacement for
the env template. Retain `fastlane/.env` in `.gitignore` as defense in depth even after deleting the
file and removing all runtime use.

At base `bf97c18`, the current `.gitignore` ignores neither `.envrc` nor `.direnv/`; the
`feat/fastlane-setup` branch adds `fastlane/.env` at `.gitignore:63`. Integration adds only
`.direnv/` to that credential-related set and preserves the `fastlane/.env` denylist entry. A scan
of both feature branches finds credential-path references only on `feat/fastlane-setup`;
`feat/fastlane-demo-mode:fastlane/Fastfile` adds screenshot behavior and no credential dependency.

A leaked `op://` reference reveals vault/item/field naming metadata. It does **not** reveal or grant
access to the referenced value; an attacker still needs an authorized 1Password user session or
service-account token. This is why the public `.envrc` must contain references only and why the
service token remains outside it.

### Base64 at the storage boundary, raw PEM at the Fastlane boundary

Store the private key as base64 in 1Password. This removes PEM-newline and command-substitution
ambiguity. Fastlane resolves `ASC_KEY_CONTENT_BASE64_REF`, decodes it with strict base64 decoding in
Ruby, and passes the resulting raw multiline PEM as `key_content:`.

Fastlane 2.237.0 accepts raw `key_content`; it preserves real newlines and converts literal `\\n`
sequences to newlines
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/fastlane/lib/fastlane/actions/app_store_connect_api_key.rb:14-26`).
It also supports `is_key_content_base64:` and forwards that flag with the key
(`app_store_connect_api_key.rb:28-45,69-79`); Spaceship decodes the value before OpenSSL parses it
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/spaceship/lib/spaceship/connect_api/token.rb:52-71`).

The design deliberately decodes before calling the action instead of setting
`is_key_content_base64: true`. The action returns the original key hash, while Fastlane's Transporter
later writes `api_key[:key]` directly to an `AuthKey_*.p8` file without consulting the base64 flag
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/fastlane_core/lib/fastlane_core/itunes_transporter.rb:68-90`).
Passing raw PEM keeps `pilot`, `deliver`, and the existing temporary JSON handoff compatible while
base64 still protects the 1Password-to-Ruby transport.

The private `asc_api_key` lane therefore replaces `ASC_KEY_PATH` with the three references, resolves
them without logging stdout, strictly decodes the private key, and calls `app_store_connect_api_key`
with raw `key_content`. Resolution failures, missing fields, invalid base64, or invalid PEM fail the
lane before any build or network mutation.

### Path-only consumers get scoped temporary files

The in-memory `api_key` hash remains the input to `pilot` and `deliver`. `gym` does not expose an ASC
`api_key` option; its supported escape hatch is `xcargs`
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/gym/lib/gym/options.rb:220-225`).
Because Xcode requires `-authenticationKeyPath`, wrap only the `gym` call in a helper that:

1. creates a `Tempfile.create(["asc-auth-key", ".p8"])` block;
2. explicitly sets mode `0600` and writes the already-decoded raw PEM;
3. passes that path plus the resolved key and issuer IDs in `xcargs`; and
4. exits the block immediately after `gym`, deleting the file even when `gym` raises.

This extends the cleanup pattern already used by `pull_metadata`, which creates its API-key JSON in
a `Tempfile.create` block and invokes `deliver download_metadata` entirely inside that block
(`feat/fastlane-setup:fastlane/Fastfile:106-125`). The implementation must add an ensure-path test
that forces the wrapped operation to fail and verifies the path no longer exists.

Temporary materialization is not equivalent to durable storage. The key exists briefly in process
memory and in mode-`0600` temporary files required by Xcode or Fastlane. Fastlane's Transporter also
materializes an API key for upload and removes its key directory in an `ensure` block
(`fastlane_core/lib/fastlane_core/itunes_transporter.rb:864-882`). The invariant is therefore: **no
standing plaintext private-key file survives a lane or cutover**, not the untrue claim that the key
never exists outside 1Password.

### What dies and what replaces it

| Current dependency | Current references | Replacement |
| --- | --- | --- |
| `fastlane/.env` | Fastlane auto-load; `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` | Delete the file and all runtime dependence. Keep its ignore rule as a tripwire. `.envrc` supplies only `*_REF` values. |
| `fastlane/.env.template` | `feat/fastlane-setup:fastlane/.env.template:1-4` | Delete it. Committed `.envrc` plus setup documentation is the single template. |
| `ASC_KEY_PATH` in `asc_api_key` | `feat/fastlane-setup:fastlane/Fastfile:21-26` | Resolve base64 content, decode in Ruby, and pass raw `key_content:`. |
| `ASC_KEY_PATH` in `gym` `xcargs` | `feat/fastlane-setup:fastlane/Fastfile:128-143` | A helper-owned mode-`0600` temporary `.p8` path scoped to `gym`. Key and issuer IDs are resolved values, never committed literals. |
| `pull_metadata` API-key JSON | `feat/fastlane-setup:fastlane/Fastfile:106-125` | Retain the proven `Tempfile.create` handoff. Its hash now contains raw PEM produced from 1Password rather than a home-directory path. |
| `~/.appstoreconnect/` | Existing plan/spec and the old plaintext key | Remove the old `.p8` and empty directory after successful cutover. Fastlane may recreate a transient key directory internally during Transporter work; its ensure cleanup must leave no standing key. |
| Old IDs and absolute path in docs | `docs/superpowers/plans/2026-07-30-fastlane-screenshots-submission.md` and `docs/superpowers/specs/2026-07-30-fastlane-screenshots-submission-design.md` | After revocation, replace them with a neutral 1Password item reference and scrub the obsolete path. History remains, but the revoked identifiers no longer compose with a live key. |

## Migration/cutover plan

The cutover keeps the old key valid until the selected authentication mode and both the Fastlane
API and Xcode path consumers are proven. It does not upload a build or submit a release as a
credential test.

1. **Choose operator-owned settings.** Select Option A or B and choose the dedicated vault/item
   names. If Option A is chosen, create a service account with read-only access to only the dedicated
   automation vault and arrange `OP_SERVICE_ACCOUNT_TOKEN` injection through the session-start
   unlock step. Never paste the token into a command recorded by an agent.
2. **Prepare the code migration before creating the key.** Implement the committed `.envrc`, secret
   resolver, base64 decode, raw `key_content` handoff, gym-scoped tempfile helper, deletion of the old
   env files, `.gitignore` change, and non-submitting verification lanes/tests. The references may
   point to an empty placeholder item until the next step.
3. **Create the replacement App Manager key in App Store Connect.** Use the browser's one-time
   download. Configure an explicit private download location, keep the window between download and
   import as short as practical, and do not expose the values in a terminal transcript.
4. **Import immediately into 1Password.** In one local operator-controlled session, encode the
   downloaded PEM to base64 and create the item with the new key ID, issuer ID, and base64 private
   key. Sensitive item data must enter `op item create` via stdin/JSON, not command arguments or a
   reusable template file. Confirm the item fields can be resolved, then best-effort overwrite/remove
   the browser artifact and its empty staging directory. APFS snapshots and SSD wear leveling mean
   physical erasure cannot be guaranteed.
5. **Activate the new references.** Replace `.envrc` placeholders with the chosen vault/item/field
   references, review them, run `direnv allow .`, and enter via the session-start unlock step.
6. **Verify Fastlane authentication safely.** Run `bundle exec fastlane check_asc_key`. That lane
   may report only non-sensitive facts such as key/issuer presence; it must never print the returned
   key hash or any resolved value.
7. **Verify Xcode's path consumer without publishing.** Run an archive-only provisioning smoke test
   that uses the same gym tempfile helper as `beta`/`release` but calls neither `pilot` nor `deliver`.
   Confirm both successful authentication and removal of the temporary `.p8` after the archive.
8. **Revoke the old ASC key.** Only after steps 6-7 pass, revoke the previously active key tracked by
   #364 in App Store Connect. Immediately rerun `check_asc_key` to prove the configured replacement
   still works. From this point, residual copies of the old private key cannot authenticate.
9. **Remove old local material and references.** Best-effort secure-delete the old `.p8`, remove the
   now-empty standing `~/.appstoreconnect/` directory, delete `fastlane/.env` and
   `fastlane/.env.template`, and scrub the old identifiers and absolute path from the Fastlane plan
   and spec. Do not rewrite git history.
10. **Close the exposure loop.** Search the working tree for the old key ID, issuer ID,
    `ASC_KEY_PATH`, and the old home-directory path. Expected results are historical issue context
    only, not active configuration or current plan/spec prose. Record the replacement key only by
    its 1Password item name.

If any pre-revocation verification fails, keep the old key active, remove any failed new-key
temporary files, and repair the migration. Do not fall back to recreating a standing `.p8`. If a
failure occurs after revocation, fix the new 1Password path or create another replacement key; never
restore the revoked credential.

## Rollout & verification

### Required automated checks

- `.envrc` contains only `op://` references and non-secret shell logic; no resolved values.
- `.direnv/` is ignored, `.envrc` is tracked, and `fastlane/.env` remains ignored.
- No active Fastfile or script reads `ASC_KEY_PATH` or auto-loads `fastlane/.env`.
- Secret resolution suppresses stdout/stderr that could contain values and fails closed on every
  missing/invalid field.
- Base64 decode rejects malformed input; the decoded value loads through the real
  `app_store_connect_api_key` path.
- The gym helper creates a mode-`0600` file, exposes it only for the duration of the block, and
  removes it on both success and an injected failure.
- The existing `pull_metadata` temporary JSON cleanup remains intact.
- Repository scans find no private key block, service-account token, replacement identifiers, or
  absolute credential path.

### Authentication matrix

| Mode | Setup | Expected behavior |
| --- | --- | --- |
| Service account | Session-start unlock step injects `OP_SERVICE_ACCOUNT_TOKEN` | `.envrc` stays non-secret; Fastlane resolves the same refs with no biometric prompt. |
| Personal/biometric | Token absent; 1Password app integration enabled and warmed by session-start unlock step | The same `.envrc` and Fastfile work. A relocked app may prompt and is an acknowledged fallback limitation. |
| Neither available | Token absent and personal CLI unavailable/locked | Lane fails before build with a redacted authentication error; it does not use a disk fallback. |

### Manual acceptance

Before revocation, the maintainer confirms:

1. `check_asc_key` succeeds without printing a key or returned credential hash;
2. the archive-only gym probe authenticates without upload/submission;
3. no gym `.p8` or `pull_metadata` JSON tempfile remains after success or forced failure;
4. the selected authentication mode meets the maintainer's unattended-run policy; and
5. the 1Password item and, if selected, service-account usage are visible to the maintainer.

After revocation, rerun the non-secret key check and repository scans. Then close #364 as remediated
by rotation and #365 as remediated by the 1Password migration.

## Decision log

- **DECIDED:** Rotation of the transcript-exposed ASC key is part of this migration's cutover.
- **DECIDED:** 1Password is the only durable source of truth for the replacement ASC key.
- **DECIDED:** The repository commits one `.envrc` containing references only and ignores
  `.direnv/`.
- **DECIDED:** Store/transport private-key content as base64, decode in Ruby, and pass raw PEM to
  Fastlane.
- **DECIDED:** Xcode receives a mode-`0600`, gym-scoped temporary `.p8` with ensure cleanup.
- **RECOMMENDED / OPEN-FOR-MAINTAINER:** Use a read-only service account for reliable unattended
  runs; personal biometric authentication remains a supported runtime fallback.
- **OPEN-FOR-MAINTAINER:** Final dedicated vault and ASC item names.
- **REJECTED:** A standing home-directory `.p8`, a second auth-specific `.envrc`, a history rewrite,
  or an unverifiable claim that browser-issued key creation is diskless.
