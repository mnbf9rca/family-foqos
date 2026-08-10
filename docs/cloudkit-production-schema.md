# CloudKit Production Schema Runbook

Container: `iCloud.com.cynexia.family-foqos`

CloudKit Production does not infer schema from app writes. TestFlight and App Store builds use the
Production environment, so promote the final Development schema before uploading the first build
that depends on it. Production schema changes are additive-only; never rename or remove a deployed
record type or field.

## Repository Preflight

Run these checks after the final schema-touching pull request has merged:

```bash
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
```

Review `Foqos/CloudKit/cloudkit-schema.ckdb` against the pending Development schema in CloudKit
Console. The local checker proves that the `.ckdb` covers every record type and field listed in
`fastlane/required-prod-schema.txt`. Keep that manifest aligned with the app's declared `FieldKey`
and `RecordKey` values through the hand-reconciliation commands in its header. Field review remains
part of the Console promotion review because the checker does not derive the manifest from code.

## Promote to Production — Maintainer Only

1. Sign in to [CloudKit Console](https://icloud.developer.apple.com/).
2. Select `iCloud.com.cynexia.family-foqos` and its CloudKit Database.
3. Confirm the Development schema contains the record types and fields in
   `Foqos/CloudKit/cloudkit-schema.ckdb`.
4. Review the pending schema changes and deploy them to Production.
5. Confirm the deployment completes before creating the TestFlight archive.

This Console deployment is a maintainer keystroke. Agents update and verify repository artifacts;
they do not promote the Production schema.

## Postflight

With `cktool` authenticated for the container, verify the deployed Production record types:

```bash
bash scripts/check-prod-schema.sh
```

The command must print `Production schema OK.` before TestFlight upload. It checks required record
types; also confirm the newly promoted fields in CloudKit Console.

## Apple References

- [Integrating a Text-Based Schema into Your Workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
- [Deploying an iCloud Container’s Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
