# Install

The authoritative, ordered install guide is **[docs/installer.md](docs/installer.md)**.

Quick start (one command, after configuring `deploy/$ENV.tfvars` from
`deploy/env.tfvars.example`). Set the two variables once — the command is then
copy/paste-safe (no `<ANGLE>` placeholders; `<`/`>` are shell redirection):

```bash
export AWS_PROFILE="customer-admin"    # selects the AWS account
export ENV="prod"                     # environment name
./deploy/deploy.sh "$ENV" install
```

Then: administer via **[docs/admin.md](docs/admin.md)**, and hand developers
**[docs/client-setup.md](docs/client-setup.md)**.
