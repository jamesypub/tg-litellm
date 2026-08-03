# Administer

Administration is done in the **LiteLLM admin UI** at the `admin_url` from
`deploy/handoff.$ENV.json` (log in as `admin` with the `ui_password` you set at
install). LiteLLM's own docs are the authoritative reference — this page only
covers the gateway-specific bits.

**Upstream LiteLLM admin docs:** <https://docs.litellm.ai/docs/proxy/ui>
(teams, users, virtual keys, budgets, model management, rate limits).

## Basic flow: give a developer access (UI)

In the admin UI:

1. **Teams** → create a team (optional) and set a team budget.
   > **Known issue (upstream, pinned LiteLLM UI v1.92.0):** the **Create Team**
   > dialog’s required **Models** selector can render empty (`No data`) even when
   > `/v1/models` serves models and the Virtual Key dialog’s selector is populated,
   > which blocks team creation from the UI. Until the pinned UI is updated,
   > create the team via the management API instead (the gateway itself is fine).
   > Pass the master key through a `curl --config` file, **never** on the command
   > line — a `Bearer` token placed in a `-H` **argument** is readable by any
   > process on the host while the command runs:
   > ```bash
   > # MK = master key (Secrets Manager); GW = gateway_url from handoff.$ENV.json
   > CFG="$(mktemp)"; chmod 600 "$CFG"
   > trap 'rm -f "$CFG"' EXIT                                        # remove the key file even if curl fails (set -e / non-2xx)
   > printf 'header = "Authorization: Bearer %s"\n' "$MK" > "$CFG"   # printf is a builtin — key never enters argv
   > curl -sf --config "$CFG" "$GW/team/new" \
   >   -H 'Content-Type: application/json' \
   >   -d '{"team_alias":"team-a","models":["claude-opus-4-8","openai.gpt-5.6-sol"],"max_budget":200}'
   > ```
   > Use exact **served** model IDs (see the alias note below). Teams created this
   > way are fully usable; only the UI create dialog is affected.
2. **Users** → add the developer (e.g. their email).
3. **Virtual Keys** → **Create Key**:
   - assign it to the user/team,
   - set **Models** = the exact model IDs they may call (see the alias note below),
   - set a **budget** (`max_budget`) + **budget duration**,
   - give the key a clear **alias** (e.g. `dev-alice-claude`) — use a **distinct key
     per client** so Claude vs. Codex spend is attributed separately.
4. Copy the key value shown **once** at creation (LiteLLM only reveals it then).
5. Hand the developer their key and the client setup (see **Give a developer
   access** below) rather than raw values.

> **Model-ID note (important):** a key's allowed **Models** must contain the
> **exact model ID the client sends**. For Codex that's the canonical Mantle ID
> (e.g. `openai.gpt-5.6-sol`), and for Claude Code a **non-slash** alias
> (e.g. `claude-opus-4-8`, not `global/claude-opus-4-8`) — otherwise the request is
> denied with a policy 403. `/v1/models` shows the IDs to allow.

## Give a developer access

A developer needs two things: **a virtual key** and **the client setup steps**.

1. Create the developer a virtual key in the admin UI (**Virtual Keys** →
   **Create Key**), following the flow above — assign the models and budget, and
   copy the key value shown once at creation.
2. Give them that key and point them at
   [example/developer-setup](../example/developer-setup) for the Claude Code and
   Codex CLI configuration. Those files are drop-in: the developer sets the
   gateway URL and their key, then launches.

Deliver the key through your approved secure channel (internal portal or secure
email) — it is a secret. The developer never needs AWS credentials or admin tools.

## Models

Models are registered at install by `deploy/register-models.sh`. To add/change
models later, use the admin UI (**Models** tab) or re-run that script — see
[installer.md](installer.md) and upstream
[Model management](https://docs.litellm.ai/docs/proxy/model_management).

### Resetting a gateway's model set

Adding models leaves stale ones in place. To reset a gateway to a clean, current
model set, run the **`tgw`** wizard and choose **Clean**:

```bash
./deploy/tgw models             # choose "Clean — reset to the current supported set"
./deploy/tgw --dry-run models   # preview only; changes nothing
```

It asks a few plain questions, shows exactly what it will delete and register,
and waits for your go-ahead before changing anything. See [installer.md](installer.md)
for the full model-registration step.

## Budgets, spend, and pricing — three separate concepts

Keep these distinct; they are not the same number:

- **Model unit price** — the per-token rates in the UI's Model Management are **unit
  rates per *million* tokens** (e.g. `$5.50` in / `$33.00` out *per 1M tokens*). NOT
  a key's spend.
- **Accrued spend** — what a key has spent in the current budget period.
- **`max_budget`** — the **hard enforcement cap**; over-cap requests are rejected
  (HTTP 429). `soft_budget` is **alert-only**.

**Enforcement is eventually consistent** — a lowered cap / revoked key propagates
through the gateway cache before denials begin (measured: ~33s for a hard-cap
change, ~63s for key revocation). Describe it as *eventual*, not immediate.

A developer can check their own key's budget/spend from the admin UI (**Virtual
Keys** → their key), or via the LiteLLM `/key/info` API authenticated as that key.
When comparing spend across tools, match each client to its key alias first (Claude
Code, Claude Desktop, and Codex are separate keys/aliases).

### Updating model pricing

Model unit prices come from LiteLLM's built-in cost map. LiteLLM handles both
setting prices and keeping them current — see the upstream docs:

- **Set or override a model's price** — [Custom LLM Pricing](https://docs.litellm.ai/docs/proxy/custom_pricing)
- **Keep pricing current as new models launch** (manual reload and scheduled
  sync endpoints) — [Auto Sync New Models](https://docs.litellm.ai/docs/proxy/sync_models_github)

Authenticate those endpoints with the gateway's master key.

## Further reading

Day-to-day administration is done in the LiteLLM admin UI; these upstream pages
are the authoritative reference for the tasks worth a pointer:

| Topic | Doc |
|---|---|
| Give a user their own access / roles | [Internal user self-serve](https://docs.litellm.ai/docs/proxy/self_serve) |
| View spend & usage | [Cost tracking](https://docs.litellm.ai/docs/proxy/cost_tracking) |
| Budgets & rate limits | [Budgets & rate limits](https://docs.litellm.ai/docs/proxy/users) |
| Virtual keys & key rotation | [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys) |
| Add / update / remove models | [Model management](https://docs.litellm.ai/docs/proxy/model_management) |
| Admin UI overview | [Admin UI](https://docs.litellm.ai/docs/proxy/ui) |

Gateway-specific tasks stay in this repo: model set reset (**Models** above),
pricing reload (**Updating model pricing** above), and the Codex Bedrock key
refresh ([codex-cron-key-refresh.md](codex-cron-key-refresh.md)).
