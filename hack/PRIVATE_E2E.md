# Private-repo e2e overrides (DROP BEFORE UPSTREAM PR)

This commit is intentionally local/private. Delete it (`git rebase -i` / `git
reset`) before opening a PR against `confidential-containers/cloud-api-adaptor`.

## Goal

Run the full Alibaba Cloud e2e path on GitHub Actions in **your** private fork
without needing write access to CoCo/quay official registries.

Built CAA / podvm / peerpod-ctrl / webhook images already go to
`ghcr.io/<your-owner>` via existing workflows. This commit adds overrides for
the remaining hardcoded pulls.

## Repository Variables to set

Settings → Secrets and variables → Actions → **Variables**:

| Variable | Purpose | Example |
|----------|---------|---------|
| `PRIVATE_E2E_ONLY_ALIBABA` | Skip AWS/libvirt/byom/s390x jobs | `true` |
| `E2E_IMAGE_REWRITE` | Rewrite test/workload image refs | see below |
| `KATA_DEPLOY_IMAGE` | Override kata-deploy container image | `ghcr.io/you/kata-deploy:3.28.0` |
| `KATA_KUBECTL_IMAGE` | Override kata kubectl helper image | `ghcr.io/you/kata-kubectl:latest` |
| `HELM_KATA_DEPLOY_CHART_REPO` | Override kata-deploy Helm OCI chart repo | `oci://ghcr.io/you/kata-deploy-charts` |
| `E2E_RUN_TESTS` | Limit Go test regex (optional; leave unset to run all) | `TestAlibabaCloudCreateSimplePod` |
| `E2E_TIMEOUT` | Override e2e timeout (optional) | `90m` |

### `E2E_IMAGE_REWRITE` format

Comma-separated `oldPrefix=newPrefix` rules (first match wins):

```text
quay.io/confidential-containers=ghcr.io/YOUR_OWNER,quay.io/kata-containers=ghcr.io/YOUR_OWNER,quay.io/prometheus=ghcr.io/YOUR_OWNER,quay.io/curl=ghcr.io/YOUR_OWNER,quay.io/nginx=ghcr.io/YOUR_OWNER,ghcr.io/kata-containers=ghcr.io/YOUR_OWNER
```

Mirror the referenced images/charts into your registry before running.

## Secrets still required for Alibaba

| Secret | Purpose |
|--------|---------|
| `ALIBABA_CLOUD_ROLE_ARN` | RAM role for GitHub OIDC |
| `ALIBABA_CLOUD_OIDC_PROVIDER_ARN` | RAM OIDC provider ARN |

`QUAY_PASSWORD` is optional when using `ghcr.io/<owner>` as the build registry.

## How to trigger

1. Push this branch to your private repo
2. Set the Variables above
3. Actions → **daily e2e tests** → Run workflow (select this branch)  
   **or** open a PR against `main` and label `test_e2e_alibabacloud`

## What this commit changes

- `E2E_IMAGE_REWRITE` applied to `utils.GetImage()` and hardcoded e2e image strings
- Helm env overrides: `KATA_DEPLOY_IMAGE`, `KATA_KUBECTL_IMAGE`, `HELM_KATA_DEPLOY_CHART_REPO`
- Workflows read those from repository Variables
- `PRIVATE_E2E_ONLY_ALIBABA=true` skips non-Alibaba e2e and s390x builds
- `QUAY_PASSWORD` / `REGISTRY_CREDENTIAL_ENCODED` no longer required by `e2e_run_all`
- Lowercase `ghcr.io/<owner>` so mixed-case GitHub usernames work
- Avoid exporting empty `RUN_TESTS` (breaks `go test -run`)

## Drop before upstream

```bash
# interactive: drop the "private e2e overrides" commit
git rebase -i origin/main

# or if it is still the tip commit:
git reset --hard HEAD~1
```
