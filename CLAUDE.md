# tg-llmgateway — working notes for Claude

## Public repos have live customers — owner approves every publish (2026-07-21)
- The public repos (e.g. `jamesypub/tg-litellm`) now serve **live customers**.
  **Only the owner approves before any change is applied/published to a public
  repo.** This OVERRIDES the lead role's prior "own merge + publish autonomously"
  authority for the public step.
- Lead may still fix, commit, push **private** `origin/main`, and prepare the
  publish (snapshot + secret-scan dry-run) — but MUST STOP before
  `internal/public-publish.sh --push` and get explicit owner approval for that
  exact change/SHA. Never publish unilaterally, even a QA-verified fix.

## Upstream issues: flag, never fix
- We do **not** fix bugs that originate in upstream dependencies (LiteLLM, its
  pinned image/UI, AWS services, etc.). When a finding is upstream, label it
  `wontfix`, record the root cause + any workaround, and keep it tracked to
  revisit on a dependency bump — but do not patch, vendor, or work around it in
  our own code. Our fixes are limited to *our* code, config, samples, and docs.
- Example dispositions: #54 (LiteLLM v1.92.0 Teams UI selector), #56 (LiteLLM
  cross-user lookup returns 200 not 403). Both ratified wontfix — flagged, not fixed.

## Inject what varies; don't hardcode it
- Values that differ across env / tenant / account / milestone must be injectable
  via arg, env, or tfvars — with a sensible default — never baked into a script.
  Genuine invariants stay named constants; this is not a license for speculative
  configurability (see upstream's "Simplicity First"). The bar is a real second
  value, not a hypothetical one.
- Learned from `internal/bus` (hardcoded `ISSUE=8` stalled the loop until it took
  `--issue N`/`BUS_ISSUE`). Secrets / account IDs / hostnames / customer + tenant
  names are the hard cases — those are enforced at the publish secret-scan gate,
  not by this note alone.

## Proactive skill suggestions
- Monitor the user's prompts. When a task would benefit from an available skill
  the user hasn't invoked, suggest it briefly before proceeding (name the skill
  and why it fits). Still honor the standing rule to invoke a clearly-applicable
  skill; this adds a nudge for the borderline cases the user may not know about.
