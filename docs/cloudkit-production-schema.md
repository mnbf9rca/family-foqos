# CloudKit Schema Upgrade Process

Container: `iCloud.com.cynexia.family-foqos`

CloudKit Production does not infer schema from app writes. TestFlight and App Store builds use the Production environment, so promote the final Development schema before uploading the first build that depends on it. Production schema changes are additive-only; never rename or remove a deployed record type or field.

## 1. Routine Schema Change — Coding Agents

The agent owns repository changes and the post-merge Development import; a PR changing `Foqos/CloudKit/cloudkit-schema.ckdb` is unfinished until that import succeeds, per the [human ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5973689700).

1. Make the record-type or field change in code.
2. Run the drift reporter:

   ```bash
   bash scripts/report-cloudkit-schema-drift.sh
   ```

   Stop if it reports drift. Update the reported entries in `fastlane/required-prod-schema.txt` and `Foqos/CloudKit/cloudkit-schema.ckdb`, preserving declarations already deployed to Production, then rerun the reporter until it prints `OK: no CloudKit schema drift.`.

3. Run the checked-in schema checker and its harness:

   ```bash
   bash scripts/check-cloudkit-schema-export.sh
   bash scripts/test-check-cloudkit-schema-export.sh
   ```

4. Include code, manifest, and `.ckdb` changes with a concise successful-check summary in the PR description.

5. After merge, fetch `origin/main`, check out that current revision in a clean agent-owned working copy, and import its schema with authenticated `cktool`; use current main rather than a stale merge commit, which could remove newer fields:

   ```bash
   xcrun cktool import-schema \
     --team-id BU7526J4QY \
     --container-id iCloud.com.cynexia.family-foqos \
     --environment development \
     --validate \
     --file Foqos/CloudKit/cloudkit-schema.ckdb
   ```

   Missing/expired credentials are a human gate through the orchestrator; never skip the import or mark it complete. Treat the checked-in file as canonical. Import applies it to Development and may remove Development-only experiments that are absent from the file. CloudKit rejects the update without making changes if the required modifications could cause data loss relative to Production; resolve any rejection before continuing. The only known import-rejection candidate on this container is the built-in `Users.roles` field (`LIST<INT64>`). If CloudKit rejects that field, record the exact response and stop for human resolution instead of changing reviewed app-owned records.

## 2. Release Promotion — Maintainer Only

Production deployment is the human’s release-checklist step in CloudKit Console, after the final schema PR’s Development import and before a dependent upload. Agents never deploy Production; agent-run release verification, postflight, or uploads still require explicit per-release human approval.

### Verifying Process Changes Before Merge

For a release-process PR, the human may authorize verifying the full TestFlight path from a clean feature worktree before merge:

```bash
scripts/fastlane.sh check_asc_key
verification_branch="$(git rev-parse --abbrev-ref HEAD)"
FOQOS_PREFLIGHT_ALLOW_BRANCH="$verification_branch" scripts/fastlane.sh beta
```

The override requires an attached, named feature branch, must exactly match the current branch, and prints a prominent verification-run banner. A missing branch or detached `HEAD` is rejected. It bypasses only the `main` branch check; the clean-tree, release-blocker, and Production schema gates remain mandatory. Omit the override for ordinary releases, which continue to require `main`.

### Signing Prerequisites

The upload lanes use automatic signing with an App Store Connect API key. The `check_asc_key` lane proves only that the credential loads; it cannot verify the key's role or its access to cloud-managed distribution certificates. Before running `beta` or `release`, use an Admin team API key whose team has enabled cloud-managed distribution-certificate access. Apple restricts creating those certificates to Account Holder and Admin roles, so an App Manager key can upload builds but still fail this automatic-signing step.

If export fails with `Cloud signing permission error` followed by `No profiles for ... were found`, stop instead of repeatedly rebuilding the archive. Either replace the credential with an Admin key that can use cloud-managed distribution certificates, or configure an active local Apple Distribution certificate and explicit App Store Connect provisioning profiles for the app and all three extensions. The current lanes implement only the automatic-signing path; the explicit-signing alternative requires a reviewed tooling change before it can be used.

1. Run repository preflight:

   ```bash
   bash scripts/report-cloudkit-schema-drift.sh
   bash scripts/check-cloudkit-schema-export.sh
   bash scripts/test-check-prod-schema.sh
   ```

2. The human opens [CloudKit Console](https://icloud.developer.apple.com/), chooses **Deploy Schema Changes** and reviews the actual Development-to-Production additive diff. If nothing is pending, record that the canonical schema is already deployed and continue to postflight. Otherwise, confirm the deployment and wait for completion.
3. With `cktool` authenticated for the container, run Production postflight:

   ```bash
   bash scripts/check-prod-schema.sh
   ```

   Do not continue unless the command verifies the required record types and fields, exits `0`, and prints `Production schema OK.`.

4. Close the release’s schema tracking issue.
5. Check the App Store Connect credential, then run exactly one upload lane after postflight is green:

   ```bash
   scripts/fastlane.sh check_asc_key

   # Choose exactly one:
   scripts/fastlane.sh beta     # TestFlight only
   scripts/fastlane.sh release  # App Store submission only
   ```

## Apple References

- [Integrating a Text-Based Schema into Your Workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
- [Deploying an iCloud Container’s Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
- [Cloud-Managed Certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)
- [Roles and Access](https://developer.apple.com/help/account/access/roles/)
- [App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
