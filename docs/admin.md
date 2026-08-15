# Administer

Administration is done in the **LiteLLM admin UI** — open
`https://<your-gateway-url>/ui` and log in as `admin` with the `ui_password` you
set at install. LiteLLM's own docs are the authoritative reference — this page only
covers the gateway-specific bits.

**Retrieving your gateway URL and master key** (run from the `deploy/` directory
with `ENV` and `AWS_PROFILE` set):

```bash
# 1. Gateway URL — CloudFront if you enabled it, otherwise the ALB:
CF_URL="$(terraform output -raw cloudfront_url 2>/dev/null)"
ALB_URL="$(terraform output -raw alb_url 2>/dev/null)"
LITELLM_URL="${CF_URL:-$ALB_URL}"
echo "$LITELLM_URL"   # confirm it looks right

# 2. Master key — fetch from Secrets Manager:
MK_ARN="$(terraform output -raw master_key_secret_arn)"
LITELLM_MASTER_KEY="$(aws secretsmanager get-secret-value \
  --secret-id "$MK_ARN" --query SecretString --output text)"
```

Export both before running any command in this guide:
```bash
export LITELLM_URL LITELLM_MASTER_KEY
```

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
prefix (e.g. `acme/openai.gpt-5.6-sol`). Pricing is set automatically from
LiteLLM's built-in cost map at registration time — no manual price entry needed.
To onboard a new Mantle account, run the wizard (see **Adding a second AWS
account** below).

> **Re-running with the same prefix** re-registers models but also creates a
> new team and a new virtual key each time. Use the original virtual key from
> the first run; only re-run if you intend to replace it.

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

`tgw add-account` onboards a second AWS account's Mantle/Codex models to your
existing gateway — no Terraform or ECS restart required. It takes about two
minutes to run and leaves the gateway live throughout.

**What it does:**
- Mints a short-lived Bedrock bearer token for the target account and injects it
  into the running gateway (live within ~30 seconds).
- Registers all Mantle models under a namespace prefix you choose (e.g.
  `acme/openai.gpt-5.6-sol`). Pricing is set automatically.
- Creates a dedicated team and virtual key restricted to that prefix, so
  developers on this account can't reach other accounts' models.
- Writes a ready-to-use Codex catalog file for the developer.

**Before you start — you need:**
- The gateway running and healthy (v1.1.4+).
- `LITELLM_URL` and `LITELLM_MASTER_KEY` (see top of this page for how to
  retrieve them).
- An AWS CLI profile for the **secondary account** with Bedrock Mantle access
  enabled (Console → Bedrock → Model access).
- Python 3 with `boto3` installed (`pip3 install boto3`).
- A short prefix for this account — letters, numbers, and underscores
  (e.g. `acme`, `team1`). You'll use it everywhere to identify this account.

### Step-by-step runbook

**Step 1 — confirm Bedrock Mantle access**

In the secondary AWS account, go to **Console → Bedrock → Model access** and
confirm the Mantle/OpenAI models are enabled in your region.

**Step 2 — run the wizard**

Run from the **repository root**:

```bash
# If not already exported, set these first (see top of this page):
export LITELLM_URL LITELLM_MASTER_KEY

./deploy/tgw add-account
```

The wizard asks three things:
- **Prefix** — your short account identifier (e.g. `acme`).
- **Model families** — which Mantle model family this account provides (select from menu).
- **AWS profile** — the profile that has access to the secondary Bedrock account.

Region defaults to `us-east-1`. To use a different region, set `REGION=<region>`
before running the wizard.

The wizard prints a virtual key at the end — **copy it immediately**, it is
shown only once. It also prints the paths to the generated Codex catalog and config files.

**Step 3 — set a budget for this account**

In the admin UI: **Teams** → find `<prefix>-team` → edit → set `max_budget` and
`budget_duration` before giving the key to anyone.

**Step 4 — verify models are live**

```bash
curl -s "$LITELLM_URL/v1/models" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  | python3 -m json.tool | grep '"<prefix>/'
# Should list e.g. "acme/openai.gpt-5.6-sol", "acme/openai.gpt-5.5", etc.
```

**Step 5 — set up the token refresh cron**

The bearer token expires in ~12 hours. Set up the cron refresh now so it rotates
automatically — see **Cron token refresh** below.

**Step 6 — give the developer access**

See **Developer access for the new account** below.

**Step 7 — test end-to-end**

Use the profile name the wizard printed (e.g. `lg-prod-mantle-on-acme`):

```bash
codex --profile <profile-name-from-wizard>
```

Send a simple prompt to confirm the route is working.

### Cron token refresh

The bearer token expires in ~12 hours. A cron job on the operator's host
re-mints it automatically every 6 hours, writing the fresh token to both
Secrets Manager and the running gateway (no restart needed).

The full setup guide is in [codex-cron-key-refresh.md](codex-cron-key-refresh.md)
— follow **§6a** for a secondary account. Summary of what you configure:

| Setting | What to put |
|---|---|
| `REGION` | Your Bedrock + Secrets Manager region (e.g. `us-east-1`) |
| `SECRET_ARN` | ARN of the Secrets Manager secret for this account's token |
| `LITELLM_URL` | Your gateway URL |
| `LITELLM_MASTER_KEY` | Your gateway admin key — keep the config file `chmod 600` |
| `BEDROCK_API_KEY_ENV` | `BEDROCK_API_KEY_<PREFIX>` (e.g. `BEDROCK_API_KEY_ACME`) |
| `CRED_MODE` | `profile` (named AWS profile) or `instance_role` (EC2 role) |
| `AWS_PROFILE` | The secondary-account profile — required when `CRED_MODE=profile` |
| `UPDATE_ECS` | `false` for secondary accounts; `true` only on the primary account's cron |

### Developer access for the new account

The wizard generates a profile name from your gateway URL and prefix. For example,
if your gateway URL is `https://prod.example.com` and prefix is `acme`, the profile
name is `lg-prod-mantle-on-acme`. You can derive it yourself, or read it from the
config file path the wizard prints at the end (e.g. `✓ Codex config → example/developer-setup/codex-setup/acme.config.toml`).

After the wizard runs, find these two files in `example/developer-setup/codex-setup/`
(in the repository root):
- `<prefix>-models.json` — the model catalog
- `<prefix>.config.toml` — the Codex profile (already has the gateway URL and correct profile name filled in)

Give the developer:
1. The **virtual key** the wizard printed
2. The `<prefix>-models.json` catalog file
3. The `<prefix>.config.toml` profile file
4. The **profile name** (e.g. `lg-prod-mantle-on-acme`)

The developer runs these commands once to install the Codex profile:

```bash
# Fill in the profile name and prefix for this account:
PROFILE="lg-<gateway>-mantle-on-<prefix>"   # e.g. lg-prod-mantle-on-acme
PREFIX="<prefix>"                            # e.g. acme

# 1. Save the catalog:
mkdir -p ~/.codex/model-catalogs
cp "${PREFIX}-models.json" ~/.codex/model-catalogs/"${PROFILE}".json

# 2. Install the profile (gateway URL is already set in the file):
cp "${PREFIX}.config.toml" ~/.codex/"${PROFILE}".config.toml

# 3. Store the virtual key:
mkdir -p ~/.codex/secrets && chmod 700 ~/.codex/secrets
echo '<virtual-key>' > ~/.codex/secrets/"${PROFILE}"-litellm-key
chmod 600 ~/.codex/secrets/"${PROFILE}"-litellm-key

# 4. Launch:
codex --profile "$PROFILE"
```

For the full developer setup reference, see [client-setup.md](client-setup.md) →
**Multi-account profile**.

### Removing a second AWS account

Have `LITELLM_URL`, `LITELLM_MASTER_KEY`, and `curl` available. Substitute your
actual prefix throughout (e.g. `acme`).

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

**Step 5 — delete the Secrets Manager token secret** (if you set one up):

Run these with the **gateway account's** AWS profile and region:

```bash
# List secrets to find the one for this prefix (use the gateway account profile):
AWS_PROFILE=<gateway-account-profile> aws secretsmanager list-secrets \
  --region <gateway-region> --query 'SecretList[*].[Name,ARN]' --output table

# Delete it (add --force-delete-without-recovery to skip the 30-day window):
AWS_PROFILE=<gateway-account-profile> aws secretsmanager delete-secret \
  --region <gateway-region> --secret-id "<arn-or-name-of-token-secret>"
```

Skip this step if you want to keep the secret and reuse it when adding the account back.

---

**To add the account back**, run `tgw add-account` from the repository root:

```bash
export LITELLM_URL LITELLM_MASTER_KEY   # already set from earlier
./deploy/tgw add-account
# Enter the same prefix and AWS profile when prompted.
```

The wizard mints a fresh bearer token, re-registers all `<prefix>/*` models (clean
mode), and creates a new team and virtual key. If you kept the old Secrets Manager
secret, the cron job can reuse it — just update the token value in it. If you deleted
it, follow the wizard's printed next-steps to create a new one.

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
