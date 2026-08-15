"""tgw — a friendly front-end over deploy/register-models.sh.

The wizard owns Q&A + orchestration only. It NEVER edits or reimplements
register-models.sh (or any engine script): its sole contract is the
environment variables those scripts already document. See
internal/specs/install-wizard-spec.md.

v1 ships one subcommand: `tgw models` (the model-catalog step).
"""
from __future__ import annotations

__version__ = "1.0.0"
