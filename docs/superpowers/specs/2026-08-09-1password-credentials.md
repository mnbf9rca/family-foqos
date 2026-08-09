# App Store Connect Credentials: 1Password, Scoped `op run`, and Key Rotation

**Date:** 2026-08-09
**Status:** Approved design; credentials provisioned; old key revoked and local file deleted;
implementation/wiring verification pending
**Scope:** Local Fastlane credentials for V2 / `main`; resolves storage issue
[#365](https://github.com/mnbf9rca/family-foqos/issues/365) and records the completed rotation from
[#364](https://github.com/mnbf9rca/family-foqos/issues/364).

## Problem

The current App Store Connect (ASC) private key is a long-lived plaintext `.p8` file under the
maintainer's home directory. A gitignored `fastlane/.env` supplies its path, key ID, and issuer ID.
This protects the private key from git, but not from another process running as the user, and it
provides no scoped access, access record, or convenient revocation mechanism.

Issue #364 made the migration urgent enough to include rotation. A verification command in the
committed Fastlane plan invoked `fastlane run app_store_connect_api_key`. That action returns a hash
whose `:key` member is the complete private key, so Fastlane printed the key into a local agent
session transcript. The transcript was not committed, pushed, or messaged elsewhere, but it now
contains the private half of the credential. Separately, this public repository contains the old
key ID, issuer ID, and local key path in the existing Fastlane plan and spec. Those identifiers do
not authenticate on their own, but together with the transcript they are all the inputs needed to
use the old private key. Rotation, rather than repository-document deletion, is the security
boundary because
git history and forks retain already-published identifiers.

On 2026-08-09, the maintainer revoked old key `U2UZLVHKA5` in App Store Connect, shredded and
deleted its actual local file `~/.appstoreconnect/AuthKey_U2UZLVHKA5.p8`, and closed #364. The
replacement key remains in 1Password; the remaining cutover is its repository wiring plus a green
wrapped `check_asc_key`.

The target state has one durable source of truth for ASC credentials: 1Password. The repository
contains only non-secret 1Password references in `fastlane/asc.env`. A committed wrapper invokes
credential-using lanes through `op run`, which resolves those references only into that child
process. Fastlane keeps the private key in process memory and materializes it only in narrowly
scoped temporary files when a downstream Apple tool requires a path. The maintainer's ambient shell
never holds ASC key material.

## Constraints

- The repository is public. No private key, service-account token, resolved environment value, new
  key ID, new issuer ID, or machine-specific key path may be committed.
- The replacement ASC key already exists and is stored in 1Password. It is not durably stored as a
  plaintext home-directory credential. Old key `U2UZLVHKA5` is revoked and its local plaintext file
  was deleted on 2026-08-09; it is not a fallback if new-key verification fails.
- ASC key creation normally produces a one-time browser download. This design therefore does not
  claim a diskless cutover. It minimizes that initial file's lifetime and treats revocation, not
  best-effort file erasure on APFS/SSD storage, as the security boundary.
- A release session may spend one biometric interaction bootstrapping the service-account token,
  but credential-using lane child processes must not stop later for additional biometric prompts.
- The credential setup consumes the **Session Credential Warm-up** interface defined by #363. That
  specification owns credential inputs, token-injection custody, per-stage outcomes, and
  failure/expiry policy; this design does not duplicate them.
- `xcodebuild -allowProvisioningUpdates` may need ASC authentication for automatic signing.
  `-authenticationKeyPath` accepts a file path, not in-memory key content. Xcode documents the path,
  key ID, and issuer ID as a required set
  (`/Applications/Xcode.app/Contents/Developer/usr/share/man/man1/xcodebuild.1:244-265`).
- This task changes documentation only. Later implementation must preserve the existing lane
  behavior and must not run a submission merely to test credential loading.
- The migration must not introduce another credential-printing probe. In particular, never invoke
  `fastlane run` for an action that returns credential material.

## Options

### Option A — read-only 1Password service account (ratified)

Create a dedicated non-built-in automation vault containing only Family Foqos credential material.
Give a service account `read_items` access to that vault. 1Password CLI uses this mode when
`OP_SERVICE_ACCOUNT_TOKEN` is present. The service account cannot use a Personal, Private, Employee,
or default Shared vault, so a dedicated vault is required. Its access can be limited, inspected,
rotated, and revoked. These constraints follow 1Password's
[service-account model](https://www.1password.dev/service-accounts/get-started) and
[CLI authentication contract](https://www.1password.dev/service-accounts/use-with-1password-cli).

This is the reliable unattended mode: `op run` does not require a biometric interaction once the
token is present. The trade-off is real: `OP_SERVICE_ACCOUNT_TOKEN` is itself a long-lived secret in
the worker's ambient environment for the release session. It must never live in a committed file,
shell history, or the repository. Limiting the account to a dedicated, narrowly scoped application
vault makes compromise narrower than today's raw, effectively immortal `.p8`, and the token is
revocable and its use report is inspectable.

**Status: RATIFIED AND PROVISIONED.** The read-only token is stored at
`op://family-foqos/service_auth_token/OP_SERVICE_ACCOUNT_TOKEN`. Personal 1Password authentication
retrieves it once per session; the reference, never the resolved token, is safe to document.

### Option B — personal 1Password app integration as bootstrap

The maintainer's personal 1Password CLI/app integration performs the single biometric bootstrap
that reads `OP_SERVICE_ACCOUNT_TOKEN` into the release-session environment. Run **Session Credential
Warm-up** before credential-using work. This keeps personal authorization at the session boundary;
subsequent `op run` children resolve ASC references with the scoped service account instead of
re-prompting for personal access. The app integration follows 1Password's
[documented authentication contract](https://www.1password.dev/cli/app-integration).

**Status: DECIDED BOOTSTRAP LAYER.** Direct personal resolution of ASC values during a Fastlane lane
is no longer the normal delivery path.

### Option C — retain a standing `.p8` for Xcode

Keep `~/.appstoreconnect/` solely for `xcodebuild` while using 1Password for Fastlane API actions.
This avoids temporary-file plumbing but leaves the highest-value secret at rest and defeats the
migration's purpose.

**Status: REJECTED.** The small implementation saving is not worth preserving the original risk.

## Recommendation

### Two-layer credential injection

The ratified architecture separates operator bootstrap from ASC credential delivery.

**Layer 1 — committed reference-only bootstrap.** Personal 1Password app integration and direnv use
committed `.env.tpl` and `.envrc` files to export only `OP_SERVICE_ACCOUNT_TOKEN`, resolved from
`op://family-foqos/service_auth_token/OP_SERVICE_ACCOUNT_TOKEN`. Both files contain references and
non-secret bootstrap logic only; neither contains the resolved token. The operator reviews them and
runs `direnv allow` as the one-time consent step for that version, then personal 1Password costs one
biometric touch per release session. No ASC key ID, issuer ID, or key content enters the ambient
shell.

**Layer 2 — per-invocation ASC injection.** Commit `fastlane/asc.env` with exactly three non-secret
reference mappings:

```dotenv
ASC_KEY_ID=op://family-foqos/app_store_connect_key/ASC_KEY_ID_REF
ASC_ISSUER_ID=op://family-foqos/app_store_connect_key/ASC_ISSUER_ID_REF
ASC_KEY_CONTENT_BASE64=op://family-foqos/app_store_connect_key/ASC_KEY_CONTENT_BASE64_REF
```

The 1Password item and fields are decided and provisioned: vault `family-foqos`, item
`app_store_connect_key`, non-secret fields `ASC_KEY_ID_REF` and `ASC_ISSUER_ID_REF`, and concealed
field `ASC_KEY_CONTENT_BASE64_REF`. A credential-using invocation is:

```bash
op run --env-file fastlane/asc.env -- bundle exec fastlane <lane>
```

`op run` uses the bootstrapped service token, resolves references only for that child process, and
masks concealed values in output. Fastlane reads the resolved `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
`ASC_KEY_CONTENT_BASE64` values with `ENV.fetch`; a bare credential-using Fastlane invocation fails
closed instead of falling back to a disk credential.

Commit a thin `scripts/fastlane.sh` wrapper so operators do not forget the prefix. It runs
`screenshots` directly because that lane needs no ASC credential, and runs `beta`, `release`,
`pull_metadata`, and `check_asc_key` through `op run --env-file fastlane/asc.env`. Any later
credential-using lane joins the wrapped set explicitly.

The setup flow is:

1. Install the 1Password CLI and direnv; enable personal app integration.
2. Review the committed `.env.tpl`/`.envrc` bootstrap, confirm it handles only
   `OP_SERVICE_ACCOUNT_TOKEN`, and run `direnv allow` once to consent to that version.
3. Run **Session Credential Warm-up** once at the start of the release session.
4. Invoke Fastlane through `scripts/fastlane.sh`; do not call an ASC lane bare.

Retain `fastlane/.env` in `.gitignore` as defense in depth after deleting the file and removing all
runtime use. Commit `.envrc` and `.env.tpl`; they contain only the service-token reference and
non-secret bootstrap logic. Add a root-anchored `/.direnv/` ignore rule because that directory may
contain direnv-managed local state that must not be tracked. Commit `fastlane/asc.env`; it contains
references, not resolved values. Delete `fastlane/.env.template` because the operator no longer
copies or edits a Fastlane env template.

A leaked `op://` reference reveals vault/item/field naming metadata. It does **not** reveal or grant
access to the referenced value; an attacker still needs an authorized 1Password user session or
service-account token. This is why the public refs file contains references only and why the service
token remains confined to the operator's release-session environment.

### Base64 at the storage boundary, raw PEM at the Fastlane boundary

Store the private key as base64 in 1Password. This removes PEM-newline and command-substitution
ambiguity. `op run` resolves the `fastlane/asc.env` reference into the child-only
`ASC_KEY_CONTENT_BASE64` value. Fastlane decodes it with strict base64 decoding in Ruby and passes
the resulting raw multiline PEM as `key_content:`.

Fastlane 2.237.0 accepts raw `key_content`; it preserves real newlines and converts literal `\\n`
sequences to newlines
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/fastlane/lib/fastlane/actions/app_store_connect_api_key.rb:14-26`).
It also supports `is_key_content_base64:` and forwards that flag with the key
(`app_store_connect_api_key.rb:28-45,69-79`); Spaceship decodes the value before OpenSSL parses it
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/spaceship/lib/spaceship/connect_api/token.rb:52-71`).

The design deliberately decodes before calling the action instead of setting
`is_key_content_base64: true`. Mainline consumers do handle the flag: Spaceship's token loader
decodes it, `deliver/runner.rb:300` decodes before Transporter, and
`pilot/build_manager.rb:416` does the same. The responsibility is distributed, however, while
Fastlane's Transporter `prepare` writer itself is flag-blind and writes `api_key[:key]` directly to
an `AuthKey_*.p8` file
(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.237.0/fastlane_core/lib/fastlane_core/itunes_transporter.rb:68-90`).
Direct Transporter use or a hand-built API-key hash such as the `pull_metadata` JSON path therefore
depends on its builder remembering which upstream decode has occurred. Strictly decoding once in
Ruby establishes one raw-PEM invariant for every consumer and removes that distributed assumption;
base64 still protects the 1Password-to-child-process transport. No known upstream defect is claimed.

The private `asc_api_key` lane therefore replaces `ASC_KEY_PATH` with the three child-process values,
fetches them without logging, strictly decodes the private key, and calls
`app_store_connect_api_key` with raw `key_content`. `op run` resolution failures, missing environment
values, invalid base64, or invalid PEM fail the lane before any build or network mutation.

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
(`2404139:fastlane/Fastfile:106-125`). The JSON contains the same raw PEM as the gym file, so
implementation must explicitly assert mode `0600` for both tempfiles, cover cleanup after success
and an injected failure for both, and add `log: false` to the nested `sh` call so the live JSON path
is not advertised in lane output.

Temporary materialization is not equivalent to durable storage. The lifecycle is: at rest in
1Password → resolved values in a credential-using `op run` child environment for that invocation →
Fastlane memory and sensitive lane context → a gym-only or metadata-only mode-`0600` tempfile →
ensure-driven deletion. ASC material never enters the ambient shell. Fastlane's Transporter cleanup
is not uniform. `upload` and `provider_ids` remove the generated key directory in `ensure`
blocks (`fastlane_core/lib/fastlane_core/itunes_transporter.rb:864-882,959-982`), but `verify` calls
the same `prepare` writer without cleanup (`itunes_transporter.rb:903-953`). For a
`ShellScriptTransporterExecutor`, that writer creates
`~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8` instead of a temporary directory
(`itunes_transporter.rb:68-90`). Whether current project lanes reach `verify` is not an acceptable
security dependency.

Every credential-using project lane must therefore enforce its own postcondition in an `ensure`.
First, remove only the expected replacement-key file at the known Transporter path. Then recursively
scan `~/.appstoreconnect/` for `*.p8`. Any residual `.p8` fails the lane from the first implementation
run onward. There is no allowlist, warning branch, environment variable, feature flag, or activation
toggle. An unrelated standing key is reported for operator remediation, not silently deleted. The
scoped invariant is: **no standing plaintext private-key file survives a credential-using Family
Foqos lane or the cutover**. It is not the untrue claim that the key never exists outside 1Password
or that the gem always cleans up after itself.
Child-only `op run` injection strengthens this postcondition: the cleanup proof no longer has to
account for ASC values lingering in the parent shell after a lane.

### What dies and what replaces it

| Current dependency | Current references | Replacement |
| --- | --- | --- |
| `fastlane/.env` | Fastlane auto-load; `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` | Delete the file and all runtime dependence at cutover. Keep its ignore rule as a tripwire. `scripts/fastlane.sh` injects child-only values through committed, non-secret `fastlane/asc.env`. |
| `fastlane/.env.template` | `2404139:fastlane/.env.template:1-4` | Delete it. Its copy-and-edit job no longer exists; committed `fastlane/asc.env` plus bootstrap documentation replaces it. |
| `.envrc`, `.env.tpl`, and `.direnv/` | Layer 1 reference-only bootstrap and direnv-managed local state | Commit `.envrc` and `.env.tpl` with references/non-secret logic only. Ignore `/.direnv/`, assert it is untracked, and scan the committed files for resolved service-account tokens. |
| `ASC_KEY_PATH` in `asc_api_key` | `2404139:fastlane/Fastfile:21-26` | Fetch the child-only base64 value injected by `op run`, decode in Ruby, and pass raw `key_content:`. |
| `ASC_KEY_PATH` in `release` and `beta` `gym` `xcargs` | `4e6b28b:fastlane/Fastfile` | A helper-owned mode-`0600` temporary `.p8` path scoped to each `gym` call. Key and issuer IDs come from the same child-only environment, never committed literals. |
| `pull_metadata` API-key JSON | `2404139:fastlane/Fastfile:106-125` | Retain the `Tempfile.create` handoff, require mode `0600` and symmetric cleanup tests, and suppress logging of its live path. Its hash now contains raw PEM produced from 1Password rather than a home-directory path. |
| `~/.appstoreconnect/` | Fastlane Transporter's cleanup-deficient `verify` path; the old top-level `AuthKey_U2UZLVHKA5.p8` was deleted on 2026-08-09 | After every credential-using lane, surgically remove the expected replacement-key path, recursively scan for `.p8` files, and fail on any match. No legacy exception exists. |
| Retained document `3jey32ebbf3d4s2ktuyb64i4rq` | Accepted backup copy of the replacement PEM | Keep it under the same vault access control for this cutover. Every future key rotation must update or remove both this document and `ASC_KEY_CONTENT_BASE64_REF` so retired private-key material is not silently retained. |
| Old IDs and absolute path in docs | `docs/superpowers/plans/2026-07-30-fastlane-screenshots-submission.md` and `docs/superpowers/specs/2026-07-30-fastlane-screenshots-submission-design.md` | With revocation complete, replace them with a neutral 1Password item reference and scrub the obsolete path. History remains, but the revoked identifiers no longer compose with a live key. |

## Migration/cutover plan

The credential retirement is already complete: on 2026-08-09 the maintainer revoked
`U2UZLVHKA5`, shredded and deleted the top-level local file
`~/.appstoreconnect/AuthKey_U2UZLVHKA5.p8`, and closed #364. There is no fallback key and no
maintenance-window exception. The remaining cutover is repository wiring plus a green wrapped
`check_asc_key` against the replacement key. The archive-only probe remains implementation
verification for Xcode's path consumer; it does not gate an already-completed revocation. No step
uploads a build or submits a release merely to test credentials.

1. **Record the completed provisioning and retirement.** The maintainer has provisioned the
   read-only service account, vault `family-foqos`, item `app_store_connect_key`, and the three
   decided fields. The replacement key is present in the concealed base64 field. The old key is
   revoked, its actual top-level local `.p8` is deleted, and #364 is closed as of 2026-08-09.
2. **Implement the two layers.** Commit the reference-only `.env.tpl` and
   `.envrc` bootstrap for `OP_SERVICE_ACCOUNT_TOKEN`, `fastlane/asc.env`, and
   `scripts/fastlane.sh`; fetch child-only values in Fastlane, strictly decode raw `key_content`, add
   the gym-scoped tempfile helper, retire the old env files, and implement the Transporter
   postcondition and non-submitting tests. From its first run, every credential-using lane must use
   the wrapper and fail if the total recursive postcondition finds any residual `.p8`.
3. **Verify the 1Password field round trip.** Through an operator-controlled `op run` child, confirm
   all three mappings resolve, the base64 field strictly decodes, and the decoded value parses as the
   expected PEM without printing any value.
4. **Retain the 1Password document backup deliberately.** The maintainer initially stored the PEM as
   document item `3jey32ebbf3d4s2ktuyb64i4rq` before converting it to the concealed field. Keep that
   document alongside the field as an accepted backup copy: both are in the same vault under the
   same access control.
5. **Activate the bootstrap and wrapper.** Run **Session Credential Warm-up** to place only
   `OP_SERVICE_ACCOUNT_TOKEN` in the release-session environment, then use `scripts/fastlane.sh` for
   every credential-using lane.
6. **Verify Fastlane authentication safely.** Run `scripts/fastlane.sh check_asc_key`. That lane may
   report only non-sensitive facts such as key/issuer presence; it must never print the returned key
   hash or any resolved value.
7. **Verify Xcode's path consumer without publishing.** Run an archive-only provisioning smoke test
   through `op run` that uses the same gym tempfile helper as `beta`/`release` but calls neither
   `pilot` nor `deliver`. Confirm successful authentication and removal of the temporary `.p8` after
   both success and an injected failure.
8. **Remove old configuration and references.** Delete any now-empty standing
   `~/.appstoreconnect/` directory, `fastlane/.env`, and `fastlane/.env.template`; scrub the old
   identifiers and absolute path from the Fastlane plan and spec. Do not rewrite git history.
9. **Close the exposure loop.** Search the working tree for the old key ID, issuer ID,
    `ASC_KEY_PATH`, and the old home-directory path. Expected results are historical issue context
    only, not active configuration or current plan/spec prose. Record the replacement key only by
    its 1Password item name.

If verification fails, remove any failed new-key temporary files and repair the new 1Password path
or create another replacement key. Never restore the revoked credential or recreate a standing
`.p8` fallback.

## Rollout & verification

### Required automated checks

- `fastlane/asc.env` is tracked and contains exactly the three decided `op://` mappings; it contains
  no resolved value.
- `.envrc` and `.env.tpl` are tracked and contain only
  `op://family-foqos/service_auth_token/OP_SERVICE_ACCOUNT_TOKEN` plus non-secret bootstrap logic;
  neither contains a resolved token or any ASC value. Root-anchored `/.direnv/` prevents staging
  direnv-managed local state, and `fastlane/.env` remains ignored as a tripwire.
- `scripts/fastlane.sh` routes `beta`, `release`, `pull_metadata`, and `check_asc_key` through
  `op run --env-file fastlane/asc.env`; `screenshots` remains credential-free.
- With the legacy `fastlane/.env` still present, a bare credential-using Fastlane invocation fails
  at `ENV.fetch("ASC_KEY_CONTENT_BASE64")` before build or network mutation even though Fastlane may
  auto-load the legacy key and issuer IDs.
- No active Fastfile or script reads `ASC_KEY_PATH` or auto-loads `fastlane/.env`.
- `op run` resolution is child-scoped, masks the concealed key value, and fails closed on every
  missing/invalid reference; Fastlane does not print the injected values.
- Base64 decode rejects malformed input; the decoded value loads through the real
  `app_store_connect_api_key` path.
- The gym helper and `pull_metadata` JSON handoff both create mode-`0600` files, expose them only
  for the duration of their blocks, and remove them on both success and an injected failure.
- `pull_metadata` invokes its nested Fastlane process with `log: false`, so the live tempfile path
  is not emitted to lane output.
- After every credential-using lane, the recursive `~/.appstoreconnect/**/*.p8` postcondition removes
  only the expected replacement-key path and fails on any residual key, including when the
  downstream action fails.
- Tests prove the postcondition is total from its first implementation run: a legacy-path,
  replacement-path, or unrelated `.p8` residual fails with no allowlist, warning branch,
  environment variable, or activation toggle.
- A repository scan enumerates every `fastlane run` occurrence and fails if any credential-returning
  action is invoked that way. Non-secret action examples require an explicit allowlist rationale.
- Repository scans find no private key block, service-account token, replacement identifiers, or
  absolute credential path.

### Authentication matrix

| Invocation | Setup via **Session Credential Warm-up** | Expected behavior |
| --- | --- | --- |
| Wrapped ASC lane | Personal bootstrap resolves the service token once | `op run` injects ASC values only into the lane child; the lane proceeds without another biometric prompt. |
| Bare ASC lane | Irrelevant | `ENV.fetch` fails before build; there is no ambient ASC value or disk fallback. |
| `screenshots` | No credential input required | The wrapper runs Fastlane directly without `op run`. |
| Missing/expired bootstrap | Not ready | `op run` fails with a redacted authentication error before Fastlane can build or mutate network state. |

### Manual acceptance

Before completing the implementation, the maintainer confirms:

1. `check_asc_key` succeeds without printing a key or returned credential hash;
2. the archive-only gym probe authenticates without upload/submission;
3. no gym `.p8`, `pull_metadata` JSON tempfile, or Transporter `.p8` remains after success or forced
   failure;
4. the ambient shell contains the service token but no ASC value before, during, or after the lane;
   and
5. the provisioned 1Password item, retained document backup, and service-account usage are visible
   to the maintainer.

Revocation and #364 closure are already complete. After the wiring and wrapped non-secret key check
pass, rerun repository scans and close #365 as remediated by the 1Password migration.

## Decision log

- **COMPLETED 2026-08-09:** Old ASC key `U2UZLVHKA5` was revoked, its actual top-level local file
  `~/.appstoreconnect/AuthKey_U2UZLVHKA5.p8` was shredded and deleted, and #364 was closed.
- **DECIDED:** 1Password is the only durable source of truth for the replacement ASC key.
- **DECIDED:** Personal 1Password plus direnv bootstraps only `OP_SERVICE_ACCOUNT_TOKEN` once per
  session; `.env.tpl` and `.envrc` are committed with references/non-secret logic only,
  `direnv allow` records operator consent, and only `.direnv/` is ignored because it may contain
  direnv-managed local state.
- **DECIDED:** The repository commits non-secret `fastlane/asc.env`; `scripts/fastlane.sh` uses
  child-scoped `op run` injection for every ASC lane, while `screenshots` is exempt.
- **DECIDED:** Use the provisioned read-only service account in vault `family-foqos`; its token is
  stored at `op://family-foqos/service_auth_token/OP_SERVICE_ACCOUNT_TOKEN`.
- **DECIDED:** Use item `app_store_connect_key` with fields `ASC_KEY_ID_REF`, `ASC_ISSUER_ID_REF`,
  and concealed `ASC_KEY_CONTENT_BASE64_REF`.
- **DECIDED:** Store/transport private-key content as base64, decode in Ruby, and pass raw PEM to
  Fastlane.
- **DECIDED:** Xcode receives a mode-`0600`, gym-scoped temporary `.p8` with ensure cleanup.
- **DECIDED:** Every credential-using Family Foqos lane recursively enforces the no-standing-key
  postcondition instead of trusting Fastlane Transporter's non-uniform cleanup. It is total from the
  first implementation run: every residual `.p8` fails, with no allowlist, warning branch, or
  runtime activation toggle.
- **DECIDED:** Retain document item `3jey32ebbf3d4s2ktuyb64i4rq` as the maintainer's backup copy
  alongside the concealed field under the same vault access control.
- **PENDING CUTOVER:** Complete repository wiring and obtain a green wrapped `check_asc_key` against
  the replacement key. The revoked key is not a fallback.
- **REJECTED:** A standing home-directory `.p8`, a second auth-specific `.envrc`, a history rewrite,
  or an unverifiable claim that browser-issued key creation is diskless.
