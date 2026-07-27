# tg-llmgateway — LiteLLM gateway on AWS (Claude + Codex) with per-user spend governance

A self-hosted LLM gateway you deploy in **your own AWS account**: one
OpenAI/Anthropic-compatible endpoint in front of Amazon Bedrock (Claude) and
Bedrock Mantle (Codex/OpenAI), with per-user virtual keys, budgets, and hard
caps. Built on the official open-source **[LiteLLM](https://docs.litellm.ai)**
gateway.

Three tasks — pick yours:

## 1. Install it  →  [docs/installer.md](docs/installer.md)
One-time, by an operator with AWS access. Configure one `.tfvars`, then (setting
`AWS_PROFILE` and `ENV` first — see the guide) run
`./deploy/deploy.sh "$ENV" install`. You get a gateway URL, an admin login, and a
master key. (Commands are variable-based — no `<ANGLE>` placeholders to paste.)

## 2. Administer it  →  [docs/admin.md](docs/admin.md)
Create teams, users, virtual keys, budgets, and models in the LiteLLM admin UI.
This repo adds only the gateway-specific handoff; general administration is the
authoritative upstream **[LiteLLM docs](https://docs.litellm.ai/docs/)**.

## 3. Use it (developers)  →  [docs/client-setup.md](docs/client-setup.md)
Your admin hands you a complete, ready-to-paste config package for **Claude Code**
or **Codex CLI** (gateway URL, your virtual key, and your allowed models already
filled in). You just paste it and launch — no AWS credentials, no curl, no model
discovery on your machine.

## What's next

Optional steps layered on top of the gateway — not required to install and use it.

**Harden the edge (HTTPS + origin lock).** By default the ALB takes plaintext HTTP
and is directly reachable. Fix it one of two ways: put an ACM cert on the ALB
(`allow_plaintext_alb=false`) for end-to-end HTTPS, or front it with CloudFront —
CloudFront terminates HTTPS at the edge (no ACM cert or DNS to start), and a WAF
secret header + security group let only CloudFront reach the ALB, so it is no
longer world-reachable. Worth doing before real keys and spend flow through it.
See [installer §7](docs/installer.md#7-review-ingress--enable-https) and the
[Quick start vs. production hardening](docs/installer.md#quick-start-vs-production-hardening) table.

**Scale agentic coding with Amazon Bedrock AgentCore.** To take agentic coding
beyond a single developer's laptop, run the coding agents on
[Amazon Bedrock AgentCore](https://aws.amazon.com/bedrock-agentcore/) — a managed
runtime that scales elastically, so capacity isn't bound to local machines. Why a
decision-maker would add it:

- **Web search for coding agents** — Claude Code and Codex support web search, but
  it isn't available when they run through this gateway; an AgentCore Gateway
  web-search tool restores it → [docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-connector-web-search-tool.html).
- **Close-your-laptop execution** — long agentic runs continue server-side,
  decoupled from a developer's machine uptime and network → [blog](https://aws.amazon.com/blogs/machine-learning/its-safe-to-close-your-laptop-now-hosting-coding-agents-on-amazon-bedrock-agentcore/).
- **Trusted MCP servers** — hosting MCP servers on managed, governed
  infrastructure lets you trust the tools your agents call.

Start from the AWS end-to-end sample → [agentcore-samples: coding agents e2e](https://github.com/awslabs/agentcore-samples/tree/main/01-features/02-host-your-agent/01-runtime/04-coding-agents/03-code-agents-competition-e2e).

## How it works

Architecture and design — the request path, CloudFront/ALB/gateway topology, and
the Codex key-refresh flow (with a diagram) → [docs/maintainer/architecture.md](docs/maintainer/architecture.md).

---

MIT — see [LICENSE](LICENSE). Builds on **[LiteLLM](https://github.com/BerriAI/litellm)** (BerriAI, MIT)
and the **AWS Solutions Library / aws-samples** (MIT-0).
