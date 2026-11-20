# Coordinated release process

`main` is the permanent trunk. Short-lived feature and `release/*` branches merge by pull request; component repositories run CI but do not deploy. Only a platform tag matching `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$` can initiate Azure deployment. The tagged platform commit and every pinned component commit must be ancestors of their respective `origin/main`. Kind is local-only; its evidence is never release evidence, even from a clean checkout.

For coordinated component changes, PR-head mode allows platform PR validation against component PR head commits and their successful required checks. This is review evidence only: merge the component PRs, repin the platform to the resulting component `main` commits, and ensure those exact gitlinks have successful required push-to-main checks before tagging a platform commit on `main`. PR-head validation does not authorize a release.

CI runs pinned integration including E2E, builds release images, and applies Trivy scanning to the images selected for promotion; Azure promotes the CI-produced images by digest without rebuilding. `make kind-up` and `make kind-validate` are optional local development checks and are not run in CI or required for release. Azure uses one GitHub Environment, `azure`, and the four separate Terraform states described in the [bootstrap guide](azure-bootstrap.md). No bootstrap or release is authorized merely by changing this repository.

> **Phase 4 scope:** The current AKS release remains the Phase 3 single-image deployment. It does not deploy the separate OS, Billing and Execution services; a multi-service AKS release is outside the scope of this Phase 4 change. Do not treat the existing release as evidence of a microservices deployment.

The release runner authenticates to Azure through GitHub environment OIDC and uses the protected environment secrets described in the bootstrap guide. ACR Basic and Key Vault use authenticated public endpoints, not private endpoints; this exposes their network surfaces to the internet and makes protection of the runner, identity and RBAC essential. PostgreSQL remains private. The GitHub-hosted runner must be able to reach the AKS API and APIM gateway as well as the Azure control and registry/vault data planes; a private gateway requires a runner with appropriate private connectivity.

AKS Free, Function scale-to-zero and the workspace ingestion limit do not eliminate Azure costs. Nodes, APIM Developer, PostgreSQL, ACR, storage, networking and telemetry remain chargeable. Existing infrastructure changes that require Terraform deletes or replacements are deliberately blocked by the release guard and need a separately authorized migration; see the [bootstrap guide](azure-bootstrap.md#cost-and-migration).

## GitHub protections

After the first successful runs, configure required pull requests and strict required status checks on `main`, enforcing the rules for administrators with no bypass, force pushes or deletion. Set required approving reviews to zero. Apply equivalent protection to `release/**`. Required checks are:

- Platform: `Component Checks`, `Pinned Integration`, `Release Images`; E2E and Trivy must also pass as part of the CI gates.
- Application: `Build & Test`, `Opengrep SAST Scan`, `Security Scan`, `Docker Build & Scan`, `Validate Aspire Publish Model`.
- Authentication: `build-and-test`, `validate-infra`.
- Database: `validate`.
- Foundation: `validate-k8s`, `validate-alerts`.

Protect platform tags `v*` with a ruleset preventing update and deletion while permitting maintainers to create them. Configure the platform's `azure` environment with a custom deployment policy allowing tag pattern `v*` only; the workflow applies the stricter semantic version check. Do not require a branch filter for tag deployments. Component repositories do not receive Azure OIDC credentials. Do not delete old environments until their configuration is migrated and no deployment is running; do not automatically remove old branches.

## Failure and recovery

The release serializes Azure changes, promotes the validated image digests, and keeps the APIM write barrier active during database migration and reconciliation. A failed release after pausing must leave it active; a failed post-unpause smoke must re-enable it. Diagnose the failing phase and rerun the same tag after correcting the operational issue, or create a corrective tag. Never automatically downgrade the database or restore an older producer. Plans, state, secrets, tokens and generated values are not release artifacts. Only the redacted release manifest and validation evidence should be retained.

The first authorized deployment must verify the paused write and approval-link barriers, read/login availability, pause preservation across a failed run, and re-pausing after a failed smoke. These cloud proofs remain pending until an authorized first release; Kind does not prove APIM, managed identity or private network behavior.

After capturing release evidence, use the [Azure teardown guide](azure-teardown.md) to remove the ephemeral deployment while preserving its bootstrap for the next tag.
