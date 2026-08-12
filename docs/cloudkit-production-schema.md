# CloudKit Schema Upgrade Process

Container: `iCloud.com.cynexia.family-foqos`

CloudKit Production does not infer schema from app writes. TestFlight and App Store builds use the
Production environment, so promote the final Development schema before uploading the first build
that depends on it. Production schema changes are additive-only; never rename or remove a deployed
record type or field.

## 1. Routine Schema Change — Coding Agents

The coding agent making a CloudKit record or field change normally completes this workflow in the
same pull request. Maintainers do not need to run discovery searches by hand.

1. Make the record-type or field change in code.
2. Run the drift reporter:

   ```bash
   bash scripts/report-cloudkit-schema-drift.sh
   ```

   Stop if it reports drift. Update the reported entries in
   `fastlane/required-prod-schema.txt` and `Foqos/CloudKit/cloudkit-schema.ckdb`, preserving
   declarations already deployed to Production, then rerun the reporter until it prints
   `OK: no CloudKit schema drift.`.
3. Run the checked-in schema checker and its harness:

   ```bash
   bash scripts/check-cloudkit-schema-export.sh
   bash scripts/test-check-cloudkit-schema-export.sh
   ```

4. Include the code, manifest, and `.ckdb` changes plus successful reporter and checker output in
   the pull request.

## 2. Release Promotion — Maintainer Only

Only a maintainer performs this workflow, after the final schema-touching pull request has merged
and before the first dependent TestFlight or App Store build.

1. Run repository preflight:

   ```bash
   bash scripts/report-cloudkit-schema-drift.sh
   bash scripts/check-cloudkit-schema-export.sh
   bash scripts/test-check-prod-schema.sh
   ```

2. With `cktool` authenticated for the container, import the reviewed checked-in schema into the
   Development environment:

   ```bash
   xcrun cktool import-schema \
     --team-id BU7526J4QY \
     --container-id iCloud.com.cynexia.family-foqos \
     --environment development \
     --validate \
     --file Foqos/CloudKit/cloudkit-schema.ckdb
   ```

   Alternatively, in [CloudKit Console](https://icloud.developer.apple.com/), select the container's
   Development environment, choose **Import Schema**, and select the same checked-in `.ckdb` file.

   Treat the checked-in file as canonical. Import applies it to Development and may remove
   Development-only experiments that are absent from the file. CloudKit rejects the update without
   making changes if the required modifications could cause data loss relative to Production;
   resolve any rejection before continuing.
3. In CloudKit Console, choose **Deploy Schema Changes** and review the actual
   Development-to-Production additive diff. If nothing is pending, record that the canonical schema
   is already deployed and continue to postflight. Otherwise, confirm the deployment and wait for
   completion.
4. With `cktool` authenticated for the container, run Production postflight:

   ```bash
   bash scripts/check-prod-schema.sh
   ```

   Do not continue unless the command exits `0` and prints `Production schema OK.`. Also confirm
   newly promoted fields in CloudKit Console because this postflight checks required record types.
5. Close the release's schema tracking issue.
6. Proceed with the appropriate upload only after postflight is green:

   ```bash
   scripts/fastlane.sh beta     # TestFlight
   scripts/fastlane.sh release  # App Store submission
   ```

Agents can update, check, and review repository artifacts, but they must not promote the Production
schema.

## Apple References

- [Integrating a Text-Based Schema into Your Workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
- [Deploying an iCloud Container’s Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
