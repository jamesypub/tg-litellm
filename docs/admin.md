# Administer

Administration is done in the **LiteLLM admin UI** — open
`https://<your-gateway-url>/ui` and log in as `admin` with the `ui_password` you
set at install. LiteLLM's own docs are the authoritative reference — this page only
covers the gateway-specific bits.

**Retrieving your gateway URL and master key** (run from `deploy/` with `ENV` and
`AWS_PROFILE` set):

```bash
# Gateway URL (CloudFront if enabled, otherwise the ALB):
terraform output -raw cloudfront_url 2>/dev/null || terraform output -raw alb_url

# Master key secret ARN, then fetch the value:
MK_ARN="$(terraform output -raw master_key_secret_arn)"
aws secretsmanager get-secret-value --secret-id "$MK_ARN" \
  --query SecretString --output text
```

These two values are what you export as `LITELLM_URL` and `LITELLM_MASTER_KEY`
throughout this guide.

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
   > # MK = master key (from Secrets Manager, see above); GW = your gateway URL
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
> **exact model ID the client sends**. For Codex on the primary account that's the
> canonical Mantle ID (e.g. `openai.gpt-5.6-sol`); for a second account it's the
> prefixed form (e.g. `demo0/openai.gpt-5.6-sol`). For Claude Code use a **non-slash**
> alias (e.g. `claude-opus-4-8`, not `global/claude-opus-4-8`) — otherwise the
> request is denied with a policy 403. `/v1/models` shows the IDs to allow.

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

### How do I add a new model?

**Claude models — re-run registration (auto-discovered)**

Claude models are discovered automatically via `list-inference-profiles`. To
add a newly-released Claude model (e.g. Claude Opus 5):

1. **Enable Bedrock model access** for the new model in the AWS Console
   (Bedrock → Model access).
2. **Re-run registration** — it is idempotent; existing models are skipped:
   ```bash
   cd deploy
   ENV=<env> REGION=<region> LITELLM_URL="<LITELLM_URL>" LITELLM_MASTER_KEY="<LITELLM_MASTER_KEY>" ./register-models.sh
   ```
3. **Confirm it serves:**
   ```bash
   curl -s "<LITELLM_URL>/v1/models" -H "Authorization: Bearer <LITELLM_MASTER_KEY>" | grep <model>
   ```
4. **Add the model to each relevant developer key's allowlist** — admin UI →
   Virtual Keys → edit key → add the model to the **Models** list.

**Codex/Mantle models — via tgw add-account (preferred)**

Mantle models are registered by `tgw add-account` under a per-account namespace
prefix (e.g. `demo0/openai.gpt-5.6-sol`). The wizard uses clean mode so pricing
is always set correctly from LiteLLM's built-in cost map. To add a new Mantle
account, run the wizard (see **Adding a second AWS account** below).

> **Re-running with the same prefix** re-registers models (clean mode) but also
> creates a new team and a new virtual key each time — it is not idempotent on
> team/key creation. Use the original virtual key issued on first run; do not
> distribute keys from a re-run unless you intend to replace the old one.

Then add the new models to the relevant developer key allowlists.

**Troubleshooting "I registered it but developers can't use it"**

- **Not in key allowlist** — add the model to the key's **Models** list in the
  admin UI.
- **Bedrock model access not enabled** — enable it in the AWS Console (Bedrock →
  Model access).
- **Claude Code still shows the old model list** — developers must set
  `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` so Claude Code calls
  `/v1/models` on the gateway and refreshes its picker. Without it, Claude Code
  uses its built-in list and newly-registered models don't appear. See
  [client-setup.md](client-setup.md) → **Seeing the gateway's models in the
  `/model` picker**.

### Resetting a gateway's model set

Run `tgw models` to reset or update the model set. Use `--dry-run` to preview without making changes:

```bash
./deploy/tgw models             # reset/update the model set
./deploy/tgw --dry-run models   # preview only; changes nothing
```

## Adding a second AWS account

Use `tgw add-account` to onboard a second AWS account (Mantle/Codex models) to an
existing gateway — no Terraform required. The wizard:

1. Mints a Bedrock bearer token for the target account.
2. Injects the key into the running gateway via the LiteLLM `/config/update`
   endpoint — no ECS restart; picks up within ~30 seconds.
3. Registers the account's models under a namespace prefix (e.g. `demo0/`).
4. Creates a dedicated LiteLLM team + virtual key restricted to that prefix.
5. Writes a Codex catalog JSON for the developer.

**Prerequisites:**
- An AWS profile for the secondary account with Bedrock Mantle access enabled.
- The account prefix must be alphanumeric + underscores only (no dashes) — it
  becomes the env var suffix `BEDROCK_API_KEY_<PREFIX>`.
- Set a team budget before handing the key to a developer (`max_budget` — edit
  the team in the admin UI after the wizard creates it).

```bash
export LITELLM_URL=https://<your-cloudfront-domain>
export LITELLM_MASTER_KEY=sk-<your-admin-key>
./deploy/tgw add-account
```

The wizard asks for an account prefix (e.g. `demo0`), then the AWS profile for
the target account. It prints the virtual key once — save it.

### Step-by-step runbook

1. Confirm Bedrock Mantle access is enabled in the secondary account and region.
2. Export `LITELLM_URL` and `LITELLM_MASTER_KEY` (gateway admin key from Secrets Manager).
3. Run `./deploy/tgw add-account` and answer the prompts:
   - **Prefix** — short identifier, alphanumeric + underscores (e.g. `acme`).
   - **AWS profile** — the profile with access to the secondary Bedrock account.
4. The wizard prints a virtual key — copy it immediately (shown once).
5. Copy the Codex catalog the wizard writes to the developer (see **Developer access** below).
6. Set up cron token refresh — the token expires in ~12h (see **Cron token refresh** below).
7. To verify: query `/v1/models` and confirm `<prefix>/openai.gpt-*` models appear:
   ```bash
   # Replace <prefix> with your actual prefix (e.g. demo0):
   curl -s "$LITELLM_URL/v1/models" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     | python3 -m json.tool | grep '"<prefix>/'
   ```
8. Test end-to-end: `codex --profile lg-<gateway>-mantle-on-<prefix>` with a simple prompt.

### Cron token refresh

The bearer token the wizard mints is valid for up to 12 hours (capped by the
signing role's STS session). To keep it fresh, add two cron entries:

```cron
# Secondary account — runs first, updates Secrets Manager + gateway; skips ECS restart
0 */6 * * *   ~/.tg-litellm/refresh-mantle-account.sh  >> ~/.tg-litellm/refresh-demo0.log 2>&1

# Primary account — runs 3 minutes later, owns the single ECS restart
3 */6 * * *   ~/.tg-litellm/refresh-codex-key.sh       >> ~/.tg-litellm/refresh.log 2>&1
```

Copy `deploy/codex-key-refresher/refresh-mantle-account.env.sample` to
`~/.tg-litellm/refresh-mantle-account.env` (`chmod 600`) and fill in:

| Var | Example | Purpose |
|---|---|---|
| `REGION` | `us-east-1` | Bedrock + Secrets Manager region |
| `SECRET_ARN` | `arn:aws:...` | Secrets Manager secret that holds the bearer key |
| `LITELLM_URL` | `https://<domain>` | Gateway URL — used to inject the fresh key via `/config/update` |
| `LITELLM_MASTER_KEY` | `sk-...` | Gateway admin key — **store this file `0600`** |
| `BEDROCK_API_KEY_ENV` | `BEDROCK_API_KEY_DEMO0` | Env var name the gateway uses for this account |
| `CRED_MODE` | `profile` | `profile` or `instance_role` |
| `AWS_PROFILE` | `acme-sso` | Required when `CRED_MODE=profile` |
| `UPDATE_ECS` | `false` | Secondary accounts: `false`; primary account (last cron): `true` |

The refresher writes the fresh token to **both** Secrets Manager and the gateway's
live config (via `/config/update`) — no ECS restart needed for the secondary account.
See `docs/codex-cron-key-refresh.md` for the full setup guide and IAM policy.

### Developer access for the new account

After the wizard completes, give the developer the virtual key the wizard printed
and the Codex catalog JSON the wizard wrote. Name the Codex profile following the
convention `lg-<gateway>-mantle-on-<prefix>` so the routing is unambiguous:

```bash
# Developer saves the catalog:
mkdir -p ~/.codex/model-catalogs
cp <prefix>-models.json ~/.codex/model-catalogs/lg-<gateway>-mantle-on-<prefix>.json

# Developer saves the config (use the wizard-written file as a template):
cp <prefix>.config.toml ~/.codex/lg-<gateway>-mantle-on-<prefix>.config.toml
# Edit: replace base_url with the actual gateway URL.

# Developer stores the virtual key in the file that auth.command reads:
mkdir -p ~/.codex/secrets && chmod 700 ~/.codex/secrets
echo '<virtual-key>' > ~/.codex/secrets/lg-<gateway>-mantle-on-<prefix>-litellm-key
chmod 600 ~/.codex/secrets/lg-<gateway>-mantle-on-<prefix>-litellm-key

# Launch:
codex --profile lg-<gateway>-mantle-on-<prefix>
```

### Removing a second AWS account

There is no `tgw remove-account` command — removal is four manual steps. Substitute
your actual prefix (e.g. `demo0`) and gateway vars throughout.

**Prerequisites:** `LITELLM_URL` and `LITELLM_MASTER_KEY` exported; `curl` available.

```bash
# Convenience: write the master key into a temp curl config so it never appears in argv.
CFG="$(mktemp)"; chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$LITELLM_MASTER_KEY" > "$CFG"
```

**Step 1 — delete the `<prefix>/*` models.**

List the database IDs of the models you want to remove:

```bash
curl -sf --config "$CFG" "$LITELLM_URL/v1/models" \
  | python3 -c "
import sys, json
for m in json.load(sys.stdin)['data']:
    if m['id'].startswith('<prefix>/'):
        print(m.get('model_info', {}).get('db_model', False),
              m['id'],
              m.get('model_info', {}).get('id', ''))
" 
# Output: True  demo0/openai.gpt-5.6-sol  <db-id>
# (only rows with True in the first column have a db_model id to delete)
```

Delete each one (repeat for every `<prefix>/*` model):

```bash
curl -sf --config "$CFG" -X POST "$LITELLM_URL/model/delete" \
  -H 'Content-Type: application/json' \
  -d '{"id": "<db-id>"}'
```

Or delete all `<prefix>/*` models in one loop:

```bash
curl -sf --config "$CFG" "$LITELLM_URL/v1/models" \
  | python3 -c "
import sys, json
for m in json.load(sys.stdin)['data']:
    if m['id'].startswith('<prefix>/'):
        db_id = m.get('model_info', {}).get('id', '')
        if db_id: print(db_id)
" | while read -r db_id; do
  curl -sf --config "$CFG" -X POST "$LITELLM_URL/model/delete" \
    -H 'Content-Type: application/json' \
    -d "{\"id\": \"$db_id\"}" && echo "deleted $db_id"
done
```

**Step 2 — delete the team and virtual key.**

In the admin UI: **Teams** → find `<prefix>-team` → delete it. Then **Virtual Keys** →
find `<prefix>-key` → delete it.

Or via API:

```bash
# Find the team ID:
TEAM_ID="$(curl -sf --config "$CFG" "$LITELLM_URL/team/list" \
  | python3 -c "import sys,json; [print(t['team_id']) for t in json.load(sys.stdin)['teams'] if t.get('team_alias')=='<prefix>-team']")"

# Delete the team (this also revokes keys that belong to it):
curl -sf --config "$CFG" -X POST "$LITELLM_URL/team/delete" \
  -H 'Content-Type: application/json' \
  -d "{\"team_ids\": [\"$TEAM_ID\"]}"
```

**Step 3 — clear the bearer key from the gateway's live config.**

`/config/update` can inject an empty string to overwrite the value without an ECS
restart (~30 s propagation):

```bash
curl -sf --config "$CFG" -X POST "$LITELLM_URL/config/update" \
  -H 'Content-Type: application/json' \
  -d '{"environment_variables": {"BEDROCK_API_KEY_<PREFIX_UPPER>": ""}}'
# e.g. for prefix=demo0: "BEDROCK_API_KEY_DEMO0": ""
```

**Step 4 — remove the cron refresh entry** (if you set one up):

```bash
# Remove the secondary-account cron line (keep the primary refresh untouched):
existing="$(crontab -l 2>/dev/null || true)"
printf '%s\n' "$(printf '%s\n' "$existing" | grep -vF "# tg-litellm-mantle-refresh-<prefix>")" \
  | sed '/^$/d' | crontab -
crontab -l    # confirm it is gone
```

Also remove `~/.tg-litellm/refresh-<prefix>-mantle.sh`, `refresh-<prefix>-mantle-account.env`,
and `refresh-<prefix>.log` if you no longer need them.

**To add the account back**, run `tgw add-account` with the same prefix:

```bash
export LITELLM_URL=https://<your-cloudfront-domain>
export LITELLM_MASTER_KEY=sk-<your-admin-key>
./deploy/tgw add-account
# Prefix: <prefix>   AWS profile: <secondary-account-profile>
```

The wizard mints a fresh bearer token, re-registers all `<prefix>/*` models (clean
mode), and creates a new team and virtual key. Follow the printed next-steps to
re-create the Secrets Manager secret and cron refresh.

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

- **Cost tracking overview** — [Cost Tracking](https://docs.litellm.ai/docs/proxy/cost_tracking)
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
