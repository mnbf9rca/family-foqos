# 1Password Fastlane Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every App Store Connect Fastlane lane through child-scoped 1Password references,
strictly decode raw key material in Ruby, and ensure every project-created tempfile is removed.

**Architecture:** A focused `ASCCredentials` Ruby module owns decoding and sensitive tempfiles.
`Fastfile` composes those helpers around the existing gym and metadata flows; a shell wrapper
decides which lanes require `op run`. The operator bootstrap files and reference mappings are
committed but contain only `op://` references.

**Tech Stack:** Ruby 4 / Fastlane 2.237.0, Bash, 1Password CLI, direnv.

## Global Constraints

- Authoritative design: commit `0944afeb0e6dcdec150af9c0772f3b0f3a98c76d`, plus the maintainer's
  later superseding decision to reject runtime Transporter residue scans as overengineering.
- Never print a private key, service-account token, resolved 1Password value, or new issuer ID.
- Strictly decode `ASC_KEY_CONTENT_BASE64` once in Ruby and pass raw PEM as `key_content`; never set
  `is_key_content_base64`.
- Keep the namespaced `ASC_*` variables. Never use Fastlane's implicit `APP_STORE_CONNECT_*`
  environment names.
- Do not run Xcode, a simulator, `pilot`, `deliver`, an upload, a submission, or key revocation.
- Do not delete `fastlane/.env` during this implementation. Its key path now dangles and is not a
  credential fallback; never recreate the deleted legacy key file.
- Do not scan `~/.appstoreconnect`, add residue allowlists, or implement a per-lane residue
  postcondition. Transporter verification residue is a maintainer-accepted known limitation.
- Bootstrap configuration is a maintainer-approved exception to test-first code: its exact two
  reference-only files and ignore entries are specified verbatim and verified structurally.

---

### Task 1: Commit the reference-only bootstrap layer

**Files:**
- Create: `.env.tpl`
- Create: `.envrc`
- Modify: `.gitignore`

**Interfaces:**
- Produces: operator-approved `OP_SERVICE_ACCOUNT_TOKEN` bootstrap for the Session Credential
  Warm-up; `.direnv/`, `.agent-mail/`, and `.amqrc` remain untracked.

- [ ] **Step 1: Add the exact non-secret bootstrap files**

`.env.tpl`:

```bash
export OP_SERVICE_ACCOUNT_TOKEN="op://family-foqos/service_auth_token/OP_SERVICE_ACCOUNT_TOKEN"
```

`.envrc`:

```bash
eval "$(op inject -i .env.tpl)"
```

- [ ] **Step 2: Add the exact ignore entries**

```gitignore
/.direnv/

# Agent Message Queue
.agent-mail/
.amqrc
```

- [ ] **Step 3: Verify only references are committed**

Run:

```bash
bash -n .envrc
git check-ignore .direnv/probe .agent-mail/probe .amqrc
git diff --check
```

Expected: Bash syntax succeeds; all three probe paths are printed as ignored; diff check is quiet.

- [ ] **Step 4: Commit separately**

```bash
git add .env.tpl .envrc .gitignore
git commit -m "build: commit direnv bootstrap layer + amq ignores (maintainer request)" \
  -m ".env.tpl and .envrc contain op:// references only. Resolution requires the operator's 1Password authentication, so the committed files expose no credential value."
```

---

### Task 2: Specify credential-helper behavior with a failing test

**Files:**
- Create: `scripts/test-asc-credentials.rb`
- Create later: `fastlane/asc_credentials.rb`

**Interfaces:**
- Produces: `ASCCredentials.decode_private_key`, `with_private_key_tempfile`,
  and `with_api_key_json_tempfile`.

- [ ] **Step 1: Write the real-behavior test first**

The harness must generate an ephemeral EC key in memory and test these literal outcomes:

```ruby
raw_pem = OpenSSL::PKey::EC.generate("prime256v1").to_pem
encoded = Base64.strict_encode64(raw_pem)
raise "decode mismatch" unless ASCCredentials.decode_private_key(encoded) == raw_pem

assert_tempfile_contract(:with_private_key_tempfile, raw_pem)
assert_tempfile_contract(:with_api_key_json_tempfile, { key: raw_pem })
```

For each tempfile helper, assert mode `0600` while yielded and absence after both a successful block
and an injected exception. Also assert malformed base64 and decoded non-PEM input fail closed.

- [ ] **Step 2: Run RED**

Run: `ruby scripts/test-asc-credentials.rb`

Expected: FAIL because `fastlane/asc_credentials.rb` does not exist.

---

### Task 3: Implement the minimal credential helper

**Files:**
- Create: `fastlane/asc_credentials.rb`
- Test: `scripts/test-asc-credentials.rb`

**Interfaces:**
- `decode_private_key(encoded) -> String` returns validated raw PEM or raises `CredentialError`.
- `with_private_key_tempfile(raw_pem) { |absolute_path| ... }` yields a mode-`0600` file.
- `with_api_key_json_tempfile(api_key) { |absolute_path| ... }` yields mode-`0600` JSON.

- [ ] **Step 1: Implement strict decode and tempfile lifecycle**

Use `Base64.strict_decode64`, validate with `OpenSSL::PKey.read`, and translate parse/decode failures
to a redacted `CredentialError`. Both tempfile helpers use `Tempfile.create`, explicit
`chmod(0600)`, binary-safe writes, `flush`, block-scoped yield, and automatic ensure cleanup.

- [ ] **Step 2: Run GREEN and mutation-check**

Run: `ruby scripts/test-asc-credentials.rb`

Expected: `PASS: ASC credential decode and tempfile lifecycle`.

Mentally mutate strict decoding, explicit chmod, or failure cleanup; each mutation must break a
named harness case.

---

### Task 4: Specify wrapper routing behavior

**Files:**
- Create: `scripts/test-fastlane-credential-routing.sh`
- Create later: `scripts/fastlane.sh`
- Create later: `fastlane/asc.env`

**Interfaces:**
- `scripts/fastlane.sh <lane> ...` routes ASC lanes through `op run`; other lanes run Bundler
  directly with every original argument preserved.

- [ ] **Step 1: Write the routing harness first**

Use a temporary `PATH` containing recording `brew`, `op`, and `bundle` executables. Assert:

- `check_asc_key`, `pull_metadata`, `beta`, and `release` execute `op run --env-file` with the
  absolute repository `fastlane/asc.env` and preserve trailing arguments;
- `screenshots`, `lanes`, `gates`, and `build_number` execute Bundler directly;
- a missing `op` fails before Bundler with a friendly message; and
- no credential value appears in captured output.

- [ ] **Step 2: Run RED**

Run: `bash scripts/test-fastlane-credential-routing.sh`

Expected: FAIL because the wrapper and refs file do not exist.

---

### Task 5: Implement child-scoped routing

**Files:**
- Create: `fastlane/asc.env`
- Create: `scripts/fastlane.sh`
- Test: `scripts/test-fastlane-credential-routing.sh`
- Delete later with Fastfile wiring: `fastlane/.env.template`

**Interfaces:**
- Consumes only the three provisioned `op://family-foqos/app_store_connect_key/...` references.

- [ ] **Step 1: Add the refs file**

Commit exactly three assignments and a comment warning that the names must never become Fastlane's
implicit `APP_STORE_CONNECT_API_KEY_*` forms.

- [ ] **Step 2: Add the executable lane wrapper**

Use the Homebrew Ruby path, an explicit credential-lane case, a friendly `command -v op` failure,
and `exec op run --env-file "$(dirname "$0")/../fastlane/asc.env" -- bundle exec fastlane "$@"`.
All non-credential lanes execute `bundle exec fastlane "$@"` directly. Mark the script executable.

- [ ] **Step 3: Run GREEN**

Run:

```bash
bash -n scripts/fastlane.sh
bash scripts/test-fastlane-credential-routing.sh
```

Expected: syntax check is quiet and the routing harness prints PASS.

---

### Task 6: Wire Fastfile to raw PEM and scoped cleanup

**Files:**
- Modify: `fastlane/Fastfile`
- Delete: `fastlane/.env.template`
- Test: `scripts/test-asc-credentials.rb`

**Interfaces:**
- Consumes the helper APIs from Task 3 and child-only `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
  `ASC_KEY_CONTENT_BASE64`.

- [ ] **Step 1: Replace the disk-key API lane**

Require `asc_credentials`. `asc_api_key` must fetch all three namespaced variables, call
`ASCCredentials.decode_private_key`, and pass raw `key_content:` with no base64 flag or path.

- [ ] **Step 2: Scope the gym key file**

In both `beta` and `release`, wrap only `gym` in `with_private_key_tempfile(api_key.fetch(:key))`.
Build `-authenticationKeyPath`, key ID, and issuer ID from the yielded path and resolved hash.

- [ ] **Step 3: Scope metadata JSON**

Use `with_api_key_json_tempfile(api_key)` around the nested `deliver download_metadata` command and
set `log: false`. Do not add runtime Transporter residue scanning.

- [ ] **Step 4: Minimize check output and retire the template**

`check_asc_key` may print the resolved key ID plus boolean issuer/key presence, never issuer content
or a returned key hash. Delete `fastlane/.env.template`; keep the `fastlane/.env` ignore rule.

- [ ] **Step 5: Parse and fail-closed checks**

Run:

```bash
bundle exec fastlane lanes
bundle exec fastlane check_asc_key
```

Expected: lane listing exits 0 with every lane. Bare `check_asc_key` exits nonzero at `ENV.fetch`
before build/network work and names only the missing variable.

---

### Task 7: Full non-Xcode verification and wiring commit

**Files:** All implementation files from Tasks 2–6.

- [ ] **Step 1: Run the complete local suite one command at a time**

```bash
ruby scripts/test-asc-credentials.rb
bash scripts/test-fastlane-credential-routing.sh
ruby scripts/test-archive-storage.rb
bash scripts/test-check-prod-schema.sh
bash scripts/test-fastlane-gates.sh
bash -n scripts/fastlane.sh
bundle exec fastlane lanes
```

- [ ] **Step 2: Run secret and stale-path scans**

Search the active diff for the revoked key ID, `BEGIN PRIVATE`, resolved token/key material,
the stale disk-key environment variable, and implicit `APP_STORE_CONNECT_API_KEY_*` names. Require
the revoked ID and secret/path scans to be empty; allow only the explicit warning comment for the
implicit names.

- [ ] **Step 3: Attempt the live non-mutating credential check**

First test only whether `OP_SERVICE_ACCOUNT_TOKEN` is present, without printing it. If present, run
`./scripts/fastlane.sh check_asc_key` and record literal redacted output: the key ID must not be
the revoked key ID, issuer/key presence must be true, and no PEM material may appear. If unavailable,
a biometric prompt is required, or authentication fails, stop the live check and report the exact
redacted failure. No live fallback key exists; never improvise credentials.

- [ ] **Step 4: Commit the wiring**

```bash
git add fastlane scripts docs/superpowers/plans/2026-08-09-1password-wiring.md
git commit -m "build: wire Fastlane credentials through 1Password"
```

Do not amend either commit.

---

### Task 8: Review and publish

- [ ] **Step 1: Request adversarial review**

Send the full commit range and verification output to `reviewer` on `review/365-wiring`. Require
specific review of raw-vs-base64 handling, implicit env-name avoidance, tempfile failure cleanup,
shell routing, and secret-output risks.

- [ ] **Step 2: Address all gating findings with new commits**

Use technical verification; never amend or force-push.

- [ ] **Step 3: Push and open the PR**

Push `feat/365-1pw-wiring` and open a draft PR to `main`. The terse body states what changed, the
scoped lifecycle “the project-created gym and metadata tempfiles are mode-0600 and ensure-deleted,”
the accepted Transporter residue limitation, and the remaining maintainer verification: wrapped
`check_asc_key` plus the archive-only path probe. Revocation and local legacy-file deletion are
already complete.
