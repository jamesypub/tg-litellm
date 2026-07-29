# Developer setup — copy-paste configs for Claude Code + Codex

Concrete, scrubbed, drop-in config files for using this gateway from a developer
laptop. Unlike `docs/client-setup.md` (which shows `$VARIABLE` template shapes),
these are real files you copy into place, edit in three spots, and run.

**Bash only. One blessed default per tool.** These files are byte-for-byte the
shape the admin renderer (`render-handoff.sh`) emits, so your setup, the renderer,
and this example never diverge.

## What you replace

Only three things — everywhere they appear in the files below:

| Placeholder | Replace with |
|---|---|
| `https://EXAMPLE.cloudfront.net` | your gateway URL (ask your admin) |
| `sk-<your-key>` | your personal virtual key (ask your admin) |
| the model (optional) | only if your key's model differs — see each tool's README |

Claude Code and Codex use **separate keys and separate config** — set up each tool
from its own folder.

## Layout

```
example/developer-setup/
  claude-setup/    # Claude Code — settings.json + launcher
  codex-setup/     # Codex — profile toml + model catalog + key file + launcher
```

- **[claude-setup/README.md](claude-setup/README.md)** — Claude Code
- **[codex-setup/README.md](codex-setup/README.md)** — Codex (note the **pinned Codex version**)

Each tool's README has the exact copy paths, the values to replace, and the launch
command. Start a **fresh shell** after editing your `~/.bash_profile`.
