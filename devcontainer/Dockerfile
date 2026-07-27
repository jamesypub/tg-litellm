# Dev-environment container: Claude Code + Codex CLI wired to the LiteLLM gateway.
# No AWS credentials or secrets are baked in — the gateway holds those. The
# developer supplies only a gateway URL + their virtual key via .env at runtime.
FROM node:22-bookworm-slim

# Base dev tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq python3 python3-pip ripgrep less \
      passwd util-linux \
    && rm -rf /var/lib/apt/lists/*

# AI coding agents (official npm packages)
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
    && npm cache clean --force

# Non-root dev user; project mounts at /work
RUN useradd -ms /bin/bash dev
WORKDIR /work

# Build context is the repo ROOT (see docker-compose.yml), so paths are
# repo-root-relative. Explicit 0755 (not `chmod +x`): a source file checked out
# 0700 would stay owner-only and 'dev' would hit "Permission denied" (exit 126). (#30)
COPY --chmod=0755 devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh
# Copy the Codex catalog generator INTO the image so it is readable/executable by
# the dropped 'dev' UID regardless of the bind-mounted project's file mode. (#30)
COPY --chmod=0755 deploy/make-codex-catalog.sh /usr/local/bin/make-codex-catalog.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/make-codex-catalog.sh && chown -R dev:dev /work

# Start as root so the entrypoint can fix ownership of mounted named volumes
# (~/.claude, ~/.codex), then it drops to the 'dev' user via gosu-less su.
ENV HOME=/home/dev
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
