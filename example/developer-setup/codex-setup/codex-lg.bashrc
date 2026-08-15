# Append this function to your ~/.bash_profile, then: source ~/.bash_profile && codex-lg-dev
# Launcher (fix #47): scrub provider env; fail closed on a conflicting selector.
codex-lg-dev() {
  for v in OPENAI_API_KEY AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [ -n "${!v:-}" ]; then echo "codex-lg-dev: refusing to launch — conflicting var $v is set; open a clean shell" >&2; return 3; fi
  done
  . "$HOME/.codex/dev.key"
  env -u OPENAI_API_KEY codex --profile dev "$@"
}
