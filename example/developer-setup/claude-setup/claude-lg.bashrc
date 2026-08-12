# Append this function to your ~/.bash_profile, then: source ~/.bash_profile && claude-lg-dev
# Launcher (fix #47): run through a SCRUBBED provider environment so an inherited
# CLAUDE_CODE_USE_BEDROCK / _VERTEX / ANTHROPIC_API_KEY can't bypass the gateway.
# Fail closed if a conflicting selector is still set after scrubbing.
#
# To see the gateway's full registered model set in the /model picker (including
# models your admin adds later), opt into discovery by uncommenting the line
# below (or set it in settings.json's "env"). Off by default; see README.md →
# Models. The launcher forwards your environment to `claude`, so this reaches it.
# export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
claude-lg-dev() {
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_API_KEY AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [ -n "${!v:-}" ]; then echo "claude-lg-dev: refusing to launch — conflicting provider var $v is set; open a clean shell" >&2; return 3; fi
  done
  env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u ANTHROPIC_API_KEY \
      CLAUDE_CONFIG_DIR="$HOME/.claude-lg-dev" claude "$@"
}
