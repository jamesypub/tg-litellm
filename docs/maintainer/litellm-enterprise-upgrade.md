# LiteLLM Enterprise Upgrade

How to activate the Enterprise edition on an existing deployment, what it unlocks, and how to get a license.

---

## In-place upgrade — one env var, restart

Enterprise is not a separate product or image. Set `LITELLM_LICENSE` on the running deployment and restart. No reinstall, no config file changes, no image swap.

```bash
LITELLM_LICENSE="eyJ..."   # JWT key issued by BerriAI
```

**Verify activation:** open the Swagger UI at `http://<proxy-host>:<port>/` — it shows **"Enterprise Edition"** in the description when the key is active.

---

## Getting a license

| Path | URL |
|---|---|
| 30-day free trial (no credit card) | https://www.litellm.ai/enterprise |
| Sales / custom quote | https://www.litellm.ai/pricing |

Pricing is custom-quoted — sized to annual request volume, deployment architecture, and support tier. Response within 1 business day. No per-token billing.

---

## Enterprise vs open source features

Core gateway functionality (virtual keys, budgets, rate limits, fallbacks, logging, 140+ providers, Prometheus) is identical in both editions. Enterprise adds identity, compliance, and support layers.

| Feature | Open Source | Enterprise |
|---|---|---|
| 140+ LLM provider integrations | Yes | Yes |
| Virtual keys, users, teams | Yes | Yes |
| Spend tracking, budgets, rate limits | Yes | Yes |
| LLM fallbacks, logging, load balancing | Yes | Yes |
| Prometheus metrics | Yes | Yes |
| Admin dashboard (`/ui`) | Basic | Full (org/project mgmt, team-scoped logging, SSO settings) |
| SSO + SCIM (Okta, Azure AD, Google Workspace) | No | Yes |
| OIDC / JWT authentication | Limited (≤5 users free) | Yes (unlimited) |
| Audit logs | No | Yes |
| Secret manager for credentials | Yes | Yes |
| Automated key rotation (scheduled, with grace periods) | No | Yes |
| Org / team admin controls | No | Yes |
| Multi-region control plane | No | Yes |
| Air-gapped deployment | No | Yes |
| 24/7 support with SLAs (1hr Sev0) | No | Add-on (standard enterprise includes Slack 9am–9pm PST Mon–Fri) |
| Dedicated Slack with engineering access | No | Yes |
| Roadmap prioritization / custom integrations | No | Yes |

---

## Docker image and Helm chart

No separate enterprise image or Helm chart. Same images used for both editions:

**Monolithic** (FYI — this project does not use this path):
```
ghcr.io/berriai/litellm-database:main-stable
```

**Componentized — this is what this project uses (ECS Terraform module):**
```
ghcr.io/berriai/litellm-gateway      # data plane  (port 4000)
ghcr.io/berriai/litellm-backend      # management API (port 4001)
ghcr.io/berriai/litellm-ui           # dashboard (port 3000)
ghcr.io/berriai/litellm-migrations   # pre-install DB migration job
```

For Helm deployments, enterprise billing metering can optionally be configured via the `billingMetrics` stanza in `values.yaml` (sends usage telemetry to BerriAI's collector — most self-hosted operators skip this). This stanza is not present in the pinned chart version used by this project.

**Injecting `LITELLM_LICENSE` in this project's ECS deployment:** add the license key as a Secrets Manager secret and pass it into the ECS task via the module's env var passthrough in `deploy/main.tf` (same pattern as `LITELLM_MASTER_KEY`).

---

## Recommended env vars for enterprise deployments

Beyond the license key, these are required or strongly recommended for production:

| Var | Required | Purpose |
|---|---|---|
| `LITELLM_LICENSE` | Yes (enterprise) | Activates enterprise features |
| `LITELLM_MASTER_KEY` | Yes | Proxy authentication |
| `DATABASE_URL` | Yes | PostgreSQL — virtual keys, spend tracking, audit logs |
| `LITELLM_SALT_KEY` | Recommended | Encrypts provider credentials stored in DB |
| `STORE_MODEL_IN_DB` | Recommended | `"True"` — enables day-2 model management via Admin UI without reloading `config.yaml` |

---

## References

- Enterprise feature list: https://docs.litellm.ai/docs/enterprise
- Pricing / contact: https://www.litellm.ai/pricing
- Trial signup: https://www.litellm.ai/enterprise
- Helm charts: https://github.com/BerriAI/litellm/tree/main/helm
