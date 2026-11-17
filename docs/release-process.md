# Coordinated release process

`main` is the permanent trunk. Short-lived feature and `release/*` branches merge by pull request; component repositories run CI but do not deploy. Only a platform tag matching `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$` can initiate Azure deployment. The tagged platform commit and every pinned component commit must be ancestors of their respective `origin/main`. Local dirty Kind evidence is never release evidence.

Before creating a tag, run `make kind-up` and `make kind-validate`, review the result and ensure the platform gitlinks reference component commits with successful required push-to-main checks. CI repeats integration and Kind validation and scans the exact images that are promoted. Azure uses one GitHub Environment, `azure`, and the four separate Terraform states described in the [bootstrap guide](azure-bootstrap.md). No bootstrap or release is authorized merely by changing this repository.

## GitHub protections

After the first successful runs, configure required pull requests and strict required status checks on `main`, enforcing the rules for administrators with no bypass, force pushes or deletion. Set required approving reviews to zero. Apply equivalent protection to `release/**`. Required checks are:

- Platform: `Component Checks`, `Pinned Integration`, `Kind Validation`.
- Application: `Build & Test`, `Opengrep SAST Scan`, `Security Scan`, `Docker Build & Scan`, `Validate Aspire Publish Model`.
- Authentication: `build-and-test`, `validate-infra`.
- Database: `validate`.
- Foundation: `validate-k8s`, `validate-alerts`.

Protect platform tags `v*` with a ruleset preventing update and deletion while permitting maintainers to create them. Configure the platform's `azure` environment with a custom deployment policy allowing tag pattern `v*` only; the workflow applies the stricter semantic version check. Do not require a branch filter for tag deployments. Component repositories do not receive Azure OIDC credentials. Do not delete old environments until their configuration is migrated and no deployment is running; do not automatically remove old branches.

## Failure and recovery

The release serializes Azure changes, promotes the validated image digests, and keeps the APIM write barrier active during database migration and reconciliation. A failed release after pausing must leave it active; a failed post-unpause smoke must re-enable it. Diagnose the failing phase and rerun the same tag after correcting the operational issue, or create a corrective tag. Never automatically downgrade the database or restore an older producer. Plans, state, secrets, tokens and generated values are not release artifacts. Only the redacted release manifest and validation evidence should be retained.

The first authorized deployment must verify the paused write and approval-link barriers, read/login availability, pause preservation across a failed run, and re-pausing after a failed smoke. These cloud proofs remain pending until an authorized first release; Kind does not prove APIM, managed identity or private network behavior.
