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
5. Hand the developer a ready-to-paste config package (see **Render a developer
   package** below) rather than raw values.

> **Model-ID note (important):** a key's allowed **Models** must contain the
> **exact model ID the client sends**. For Codex that's the canonical Mantle ID
> (e.g. `openai.gpt-5.6-sol`), and for Claude Code a **non-slash** alias
> (e.g. `claude-opus-4-8`, not `global/claude-opus-4-8`) — otherwise the request is
> denied with a policy 403. `/v1/models` shows the IDs to allow.

## Render a developer package

Don't send developers raw values + setup steps — render a complete, copy-ready
package with the handoff renderer and deliver it through your approved secure
channel (internal portal or secure email). The developer just pastes it.

The renderer needs the key's **secret**, which LiteLLM returns **only at creation**.
So it either **creates the key itself** (`--create`) or reads a secret you saved at
creation (`--key-file`, or `-` for stdin):

```bash
# Create the key AND render in one step (simplest):
AWS_PROFILE="$AWS_PROFILE" ./deploy/render-handoff.sh "$ENV" claude dev-alice-claude \
  --create 50 claude-opus-4-8 --user alice
AWS_PROFILE="$AWS_PROFILE" ./deploy/render-handoff.sh "$ENV" codex dev-alice-codex \
  --create 50 openai.gpt-5.6-sol --user alice

# Or render from a key you already created (one-time secret saved to a file):
AWS_PROFILE="$AWS_PROFILE" ./deploy/render-handoff.sh "$ENV" claude dev-alice-claude \
  --key-file ~/.secrets/dev-alice-claude.key --models claude-opus-4-8
```

> **Model ID must be one the gateway SERVES.** The model you pass to `--create`
> must appear in `/v1/models` (run the “what’s served” check below). `--create`
> validates this up front and fails closed listing the served client-compatible
> aliases, so you can’t hand out a key that request-time-400s. For Claude use a
> **bare** `claude-*` id (`register-models.sh` registers bare aliases in addition
> to the `global/…`/`us/…` scope names); the slash/scope names are served for
> explicit scope selection but the Claude Code CLI rejects them.

> **Key ownership (spend attribution).** Pass `--user <id>` (and optionally
> `--team <id>`) so the key — and all spend it drives — is attributable to a
> developer and enforceable by per-user budget / cross-user isolation. If you omit
> `--user`, the renderer derives the owner from the key alias so a key is **never**
> created ownerless; naming the user explicitly is recommended.

The package contains actual values (isolated config dir, exact models, launcher,
owner-only key files, managed-settings check for Claude, version-matched Codex
catalog). The developer's whole job is then: paste, `source ~/.bash_profile`, run
`claude-lg-$ENV` / `codex-lg-$ENV` (see [client-setup.md](client-setup.md)).

> The rendered **output contains the developer's virtual key** — treat it as secret
> and deliver only through the approved channel. The renderer holds no secrets.

## Models

Models are registered at install by `deploy/register-models.sh`. To add/change
models later, use the admin UI (**Models** tab) or re-run that script — see
[installer.md](installer.md) and upstream
[Model management](https://docs.litellm.ai/docs/proxy/model_management).

### Resetting a gateway's model set (wizard mode)

By default the script is purely additive — re-running it only adds new models,
never removes stale ones. Set `WIZARD=1` to reset a gateway to a clean, current
model set instead: it walks through a few plain questions (what to do, what to
delete, which scope wins the bare Claude alias), each with a one-line "why" and
a sensible default, then shows **one summary of the whole run** — what it will
delete and register — before it touches anything. Run it at a terminal for the
interactive walkthrough, or fully non-interactively via env vars (see the
script's header comment for the full var reference: `WIZARD_MODE`,
`WIZARD_DELETE_SCOPE`, `SCOPE`, `WIZARD_INCLUDE`/`WIZARD_EXCLUDE`).

Mutating the gateway requires an explicit go-ahead: interactively that's the
summary's `Proceed? [y/N]`; non-interactively it's `WIZARD_CONFIRM=1` — without
it, any run that would **delete or register** models aborts loudly rather than
guessing. Use `SKIP_DELETE=1` to keep the wizard's other choices (e.g. `SCOPE`)
but skip the delete step, or `DRY_RUN=1` to preview what would happen with no
writes at all.

Clean mode deletes the models this script registers — recognized by their name
forms (the scoped `global/…`/`us/…` and bare Claude aliases, their canonical
inference-profile ids, and the Mantle/`gpt-oss` aliases). In these gateways
every model was registered by this script, so a clean run replaces the whole
set. A name that exactly matches one of those forms is treated as ours and will
be deleted, so **do not hand-register a model under one of the script's own
names** (e.g. `global/claude-…` or a bare `claude-…`) if you want it to survive
a clean run — give it a distinct name; names that match none of the script's
forms are left untouched. Registration is idempotent, so a run interrupted
partway through (e.g. after delete, before every model re-registers) is safe to
just re-run — it picks up where it left off.

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
