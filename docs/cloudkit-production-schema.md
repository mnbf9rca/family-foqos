# CloudKit Schema Upgrade Process

Container: `iCloud.com.cynexia.family-foqos`

CloudKit Production does not infer schema from app writes. TestFlight and App Store builds use the
Production environment, so promote the final Development schema before uploading the first build
that depends on it. Production schema changes are additive-only; never rename or remove a deployed
record type or field.

## 1. Routine Schema Change

Use this checklist whenever a code change adds or changes a CloudKit record type or field.

1. Make the record-type or field change in code.
2. Run the manifest header searches to find every declared record type and field:

   ```bash
   rg -n 'static let recordType\s*=\s*"[^"]+"' Foqos FoqosDeviceMonitor FoqosShieldConfig FoqosWidget
   rg -n 'CKRecord\(recordType:\s*"[^"]+"' Foqos FoqosDeviceMonitor FoqosShieldConfig FoqosWidget
   rg -n 'static let recordType|enum FieldKey: String|^[[:space:]]+case [[:alnum:]_]+( = "[^"]+")?$' Foqos/CloudKit/SyncModels.swift Foqos/CloudKit/ProfileSessionRecord.swift
   rg -n 'static let recordType|enum RecordKey|^[[:space:]]+static let [[:alnum:]_]+ = "[^"]+"' Foqos/Models/DeviceHeartbeat.swift Foqos/Models/FamilyCommand.swift Foqos/Models/FamilyLockCode.swift Foqos/Models/FamilyMember.swift
   rg -n 'rootRecord\["[^"]+"\]' Foqos/CloudKit/CloudKitNetworkService.swift Foqos/CloudKit/CloudKitNetworkService+Sharing.swift
   ```

3. Reconcile `fastlane/required-prod-schema.txt` with the search results. Preserve built-in and
   deprecated requirements, and update the reconciliation date and descriptive counts in its
   header.
4. Reconcile `Foqos/CloudKit/cloudkit-schema.ckdb` with the CloudKit Development schema. Preserve
   declarations already deployed to Production for compatibility.
5. Run the checked-in schema checker and its harness:

   ```bash
   bash scripts/check-cloudkit-schema-export.sh
   bash scripts/test-check-cloudkit-schema-export.sh
   ```

6. Include the code change, manifest, `.ckdb`, and successful checker and harness output in the pull
   request.

## 2. Release Promotion

Use this checklist after the final schema-touching pull request has merged and before the first
TestFlight or App Store build that depends on it.

1. Run repository preflight:

   ```bash
   bash scripts/check-cloudkit-schema-export.sh
   bash scripts/test-check-prod-schema.sh
   ```

2. Sign in to [CloudKit Console](https://icloud.developer.apple.com/), select
   `iCloud.com.cynexia.family-foqos`, choose its CloudKit Database, and select the Development
   environment. Compare its schema with `Foqos/CloudKit/cloudkit-schema.ckdb`.
3. Review the pending additive changes, choose **Deploy Schema Changes**, confirm the deployment,
   and wait for completion.
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

The Console deployment is a maintainer-only action. Agents can update, check, and review repository
artifacts, but they must not promote the Production schema.

## Apple References

- [Integrating a Text-Based Schema into Your Workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
- [Deploying an iCloud Container’s Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
