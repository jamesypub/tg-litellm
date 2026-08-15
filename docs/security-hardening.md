# Security hardening

Specific hardening steps for this gateway beyond the quick-start defaults.
The [installer's production-hardening table](installer.md#quick-start-vs-production-hardening)
covers ingress, HTTPS, and HA. This page covers the deeper controls.

---

## ECS task egress restriction

**Why this matters.** The LiteLLM supply chain incident (March 2026, CVE-2026-33634)
showed that a compromised container payload exfiltrates secrets by making outbound
HTTPS calls to an attacker-controlled domain. By default, ECS tasks in a VPC have
unrestricted outbound internet access. Restricting egress to only the AWS service
endpoints the gateway actually needs limits what a compromised container can reach.

**What the gateway legitimately calls outbound:**
- Amazon Bedrock (`bedrock-runtime.<region>.amazonaws.com`)
- AWS Secrets Manager (`secretsmanager.<region>.amazonaws.com`)
- Amazon RDS (inside the VPC — no internet path needed)
- Amazon ElastiCache (inside the VPC — no internet path needed)
- CloudFront / ALB health checks (intra-VPC)

**Recommended approach — VPC Endpoints + restrictive security group egress:**

### Step 1 — create VPC Interface Endpoints for Bedrock and Secrets Manager

In the AWS Console or via Terraform, create Interface Endpoints in your VPC for:
- `com.amazonaws.<region>.bedrock-runtime`
- `com.amazonaws.<region>.secretsmanager`

This routes all Bedrock and Secrets Manager traffic over the AWS private network,
never leaving the VPC. It also lets you remove those destinations from the public
egress rule.

### Step 2 — tighten the ECS task security group egress rule

After adding the VPC Endpoints, change the ECS task security group's outbound rule
from `0.0.0.0/0 all` to:

| Protocol | Port | Destination | Purpose |
|---|---|---|---|
| TCP | 443 | VPC CIDR | Bedrock + Secrets Manager via VPC Endpoints |
| TCP | 5432 | RDS security group | PostgreSQL |
| TCP | 6379 | ElastiCache security group | Redis |

Remove the `0.0.0.0/0` egress rule. This means a compromised container cannot
make outbound calls to the public internet, even if it tries.

> **Terraform note:** the upstream LiteLLM module currently creates a permissive
> `0.0.0.0/0` egress rule on the ECS task security group. Overriding it requires
> either a module fork or a post-apply `aws_security_group_rule` resource that
> removes the broad rule and adds the narrow ones. Track this as part of any
> module upgrade (see [Upgrading LiteLLM](#upgrading-litellm) below).

### Step 3 — enable VPC Flow Logs

Turn on VPC Flow Logs (CloudWatch Logs or S3) on the gateway VPC. This gives you
an audit trail of all outbound connection attempts. If a future supply-chain event
occurs, you can query flows to determine whether the gateway made unexpected
outbound calls during the exposure window.

```bash
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids <vpc-id> \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /vpc/tg-llmgateway-flows \
  --deliver-logs-permission-arn <iam-role-arn-for-flow-logs>
```

---

## Image version pinning

The gateway runs pre-built container images from
`ghcr.io/berriai/litellm-{gateway,backend,ui,migrations}`. Pinning by tag (e.g.
`v1.92.0`) is a start, but a tag can be force-pushed to point at a different image
digest. Pin by **digest** to guarantee bit-for-bit reproducibility:

```bash
# Get the digest for the current pinned tag:
docker pull ghcr.io/berriai/litellm-gateway:v1.92.0
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/berriai/litellm-gateway:v1.92.0
# e.g. ghcr.io/berriai/litellm-gateway@sha256:abc123...
```

Then set in `$ENV.tfvars`:
```hcl
image_tag = "v1.92.0@sha256:<digest>"
```

ECS resolves the digest at deploy time, so a tag re-push by an upstream attacker
does not change what runs in your cluster.

---

## Upgrading LiteLLM

LiteLLM does **not** have a built-in update notification. Monitor for new releases
manually:

- **GitHub releases:** watch `https://github.com/BerriAI/litellm/releases` (use
  GitHub's **Watch → Custom → Releases** to get email notifications).
- **Release cadence:** LiteLLM publishes a stable release approximately weekly
  (Friday/Saturday). Release candidates appear the prior Saturday.
- **Our pin:** `image_tag` in `deploy/variables.tf` and `deploy/env.tfvars.example`.

**To bump the version:**

1. Review the [LiteLLM changelog](https://github.com/BerriAI/litellm/releases) for
   breaking changes, migration notes, and security fixes since your current pin.
2. Update `image_tag` in `deploy/variables.tf` (default) and `deploy/env.tfvars.example`:
   ```hcl
   image_tag = "v<new-version>"
   ```
3. Get the new image digest and append it (see [Image version pinning](#image-version-pinning) above).
4. Test in a non-production environment first:
   ```bash
   ENV=staging ./deploy/deploy.sh staging apply
   ./deploy/verify.sh staging
   ```
5. If verify passes, apply to production:
   ```bash
   ENV=prod ./deploy/deploy.sh prod apply
   ./deploy/verify.sh prod
   ```

Database migrations run automatically on container startup
(`prisma migrate deploy`). No manual migration step is needed.

---

## Secret rotation

Rotate these on a schedule or after any suspected exposure:

| Secret | Location | How to rotate |
|---|---|---|
| LiteLLM master key | Secrets Manager `*-litellm-master-key` | Generate new `sk-...`, update in Secrets Manager, restart ECS tasks |
| UI password | Secrets Manager `*-ui-password` | Update in Secrets Manager + `$ENV.tfvars`, re-apply |
| DB password | Secrets Manager (managed by RDS) | Use RDS secret rotation or update manually + re-apply |
| Mantle bearer token | Secrets Manager `*-bedrock-api-key` | Cron refresher handles this automatically; force a re-mint if compromised |

After rotating the master key, all existing virtual keys remain valid (they are
stored in the DB, not derived from the master key). Only the admin API access
changes.
