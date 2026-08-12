# Codex/Mantle Bedrock API key auto-refresher (issue: Codex bearer key expiry).
#
# The Mantle/Responses leg (openai.gpt-5.x) authenticates with a SHORT-TERM
# Bedrock API key (bearer, ~12h TTL) because LiteLLM's bedrock_mantle SigV4 path
# is broken in the pinned version (fails to load — verified). Claude is
# unaffected (task-role SigV4). So the bearer token must be re-minted before it
# expires, or Codex calls start returning 401 "security token expired".
#
# This builds a scheduled Lambda that:
#   1. Mints a fresh short-term Bedrock token (SigV4-derived) from its own role,
#      which carries the SAME Bedrock permissions as the gateway task role.
#   2. Writes it to the BEDROCK_API_KEY Secrets Manager secret the gateway reads.
#   3. Forces a new ECS deployment so the gateway picks up the rotated env value.
#
# NOTE on identity: ideally the token would be minted AS the gateway task role,
# but that role's trust policy (owned by the vendored module) only allows
# ecs-tasks.amazonaws.com to assume it and cannot be appended to from here. So
# the Lambda uses its own role granted the identical Bedrock policy — the token
# authorizes with the same Bedrock access. Retire this whole file once LiteLLM's
# bedrock_mantle SigV4 auth works (then Codex uses the task role, like Claude).
#
# Gated on enable_codex_key_refresh so Claude-only installs deploy nothing.

variable "enable_codex_key_refresh" {
  type        = bool
  default     = true
  description = "Deploy a scheduled Lambda that re-mints the short-term Codex/Mantle Bedrock API key before its ~12h expiry and rolls the gateway. Default true (on with Codex). Set false only for a Claude-only install."
}

# Which secret the refresher rotates. Defaults to the Terraform-owned secret
# created in codex-secret.tf (local.bedrock_api_key_secret_arn). An operator
# bringing their own key can override this with an explicit ARN. (#61)
variable "codex_key_secret_arn" {
  type        = string
  default     = ""
  description = "Override: Secrets Manager ARN of the BEDROCK_API_KEY secret to rotate. Leave empty to use the installer-created secret (default). Set only when bringing your own key."

  validation {
    condition     = var.codex_key_secret_arn == "" || can(regex("^arn:aws:secretsmanager:", var.codex_key_secret_arn))
    error_message = "codex_key_secret_arn, when set, must be a Secrets Manager ARN."
  }
}

variable "codex_key_refresh_hours" {
  type        = number
  default     = 6
  description = "How often (hours) to re-mint the token. Half the ~12h TTL by default so a missed run still leaves a valid token."

  validation {
    condition     = var.codex_key_refresh_hours >= 1 && var.codex_key_refresh_hours <= 11
    error_message = "codex_key_refresh_hours must be 1..11 (below the ~12h token TTL)."
  }
}

locals {
  # Deploy the refresher when enabled AND a secret will exist to rotate. This MUST
  # be decidable at PLAN time — so it depends only on input variables, never on
  # local.bedrock_api_key_secret_arn (which can resolve to the TF-owned secret's
  # ARN, an apply-time attribute → "Invalid count argument", #61 regression). A
  # secret exists when Codex is on (TF creates one), or the operator brought their
  # own, or an explicit override ARN was given — all plan-time-known inputs.
  refresher_secret_will_exist = var.enable_codex || local.byo_bedrock_api_key != "" || var.codex_key_secret_arn != ""
  # This file is the LAMBDA refresh engine. Deploy it only when rotation is on
  # (local.codex_refresh_on, derived from codex_key_mode in codex-secret.tf) AND
  # the selected mode is lambda_auto_refresh. external_cron_auto_refresh deploys no
  # TF refresher (the operator's own cron re-mints the BYO key), so it never reaches
  # here. (#76)
  refresher_enabled = local.codex_refresh_on && var.codex_key_mode == "lambda_auto_refresh" && local.refresher_secret_will_exist
  refresher_name    = "${var.tenant}-litellm-${var.env}-codex-key-refresher"
}

# --- Lambda role: mint a Bedrock token + write the secret + roll ECS ----------
data "aws_iam_policy_document" "refresher_assume" {
  count = local.refresher_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "refresher" {
  count              = local.refresher_enabled ? 1 : 0
  name               = local.refresher_name
  assume_role_policy = data.aws_iam_policy_document.refresher_assume[0].json
  tags               = { "litellm:stack" = "${var.tenant}-litellm-${var.env}" }
}

data "aws_iam_policy_document" "refresher" {
  count = local.refresher_enabled ? 1 : 0

  # The minted token authorizes AS this role, so the role needs the same Bedrock
  # rights the token will be used for. The Mantle/Responses (Codex) path is a
  # SEPARATE service namespace (bedrock-mantle:*), distinct from bedrock:* used by
  # the Claude Converse path — the token must carry both to invoke Codex.
  statement {
    sid       = "MintBedrockToken"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = ["*"]
  }
  statement {
    sid       = "MantleInvoke"
    actions   = ["bedrock-mantle:CallWithBearerToken", "bedrock-mantle:CreateInference"]
    resources = ["*"]
  }
  # Write the rotated token to the secret the gateway reads.
  statement {
    sid       = "WriteSecret"
    actions   = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.bedrock_api_key_secret_arn]
  }
  # Force the gateway to pick up the rotated env value.
  statement {
    sid       = "RollGateway"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:ListServices"]
    resources = ["*"]
  }
  # CloudWatch Logs.
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:*:*"]
  }
}

resource "aws_iam_role_policy" "refresher" {
  count  = local.refresher_enabled ? 1 : 0
  name   = "${local.refresher_name}-policy"
  role   = aws_iam_role.refresher[0].id
  policy = data.aws_iam_policy_document.refresher[0].json
}

# --- Lambda function ----------------------------------------------------------
# Pure-boto3: mint the Bedrock short-term token by SigV4-signing a GetBearerToken
# style call. We use the AWS SDK directly (no external layer) — the token is a
# base64 of the SigV4 Authorization for the bedrock GetApiKey action.
data "archive_file" "refresher" {
  count       = local.refresher_enabled ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.build/codex-key-refresher.zip"

  source {
    filename = "handler.py"
    content  = <<-PY
      import base64, os, boto3
      from botocore.auth import SigV4QueryAuth
      from botocore.awsrequest import AWSRequest
      from botocore.exceptions import WaiterError

      # Mint a short-term Amazon Bedrock API key (bearer) from THIS Lambda's role
      # credentials. This replicates aws-bedrock-token-generator's algorithm
      # EXACTLY (only botocore, which ships in the Lambda runtime — no layer):
      # SigV4-QUERY-presign a POST to bedrock.amazonaws.com?Action=CallWithBearerToken
      # with a 12h expiry, then base64 the presigned URL (minus scheme) + "&Version=1".
      # Ref: aws_bedrock_token_generator.token_generator._generate_token.
      HOST = "bedrock.amazonaws.com"
      URL = f"https://{HOST}/"
      SERVICE = "bedrock"
      PREFIX = "bedrock-api-key-"
      VERSION = "&Version=1"
      TTL = 43200  # 12h
      WAIT_DELAY = 15
      WAIT_MAX_ATTEMPTS = 40  # 10-min ceiling on the ECS stability wait

      def _mint_token(region):
          creds = boto3.Session().get_credentials().get_frozen_credentials()
          req = AWSRequest(method="POST", url=URL, headers={"host": HOST},
                           params={"Action": "CallWithBearerToken"})
          SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
          presigned = req.url.replace("https://", "") + VERSION
          return PREFIX + base64.b64encode(presigned.encode()).decode()

      def handler(event, context):
          region = os.environ["REGION"]
          cluster = os.environ["ECS_CLUSTER"]
          service = os.environ["ECS_SERVICE"]
          token = _mint_token(region)

          boto3.client("secretsmanager", region_name=region).put_secret_value(
              SecretId=os.environ["SECRET_ARN"], SecretString=token)

          ecs = boto3.client("ecs", region_name=region)
          ecs.update_service(cluster=cluster, service=service, forceNewDeployment=True)

          # ECS reads the secret only at task START, so the fresh key is served
          # only after the roll reaches steady state. Wait, and report ok ONLY
          # then; raise on timeout. Returning ok before stability is the #86
          # stale-token 401. Lambda timeout (below) covers this bounded waiter.
          try:
              ecs.get_waiter("services_stable").wait(
                  cluster=cluster, services=[service],
                  WaiterConfig={"Delay": WAIT_DELAY, "MaxAttempts": WAIT_MAX_ATTEMPTS})
          except WaiterError:
              raise RuntimeError(
                  f"{service} did not reach steady state within "
                  f"{WAIT_DELAY * WAIT_MAX_ATTEMPTS}s; roll unconfirmed")

          return {"ok": True, "rolled": service, "stable": True}
    PY
  }
}

resource "aws_lambda_function" "refresher" {
  count            = local.refresher_enabled ? 1 : 0
  function_name    = local.refresher_name
  role             = aws_iam_role.refresher[0].arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.refresher[0].output_path
  source_code_hash = data.archive_file.refresher[0].output_base64sha256
  timeout          = 780  # must exceed the bounded services_stable waiter (600s) + mint/roll overhead (#86)
  memory_size      = 128

  environment {
    variables = {
      REGION      = var.region
      SECRET_ARN  = local.bedrock_api_key_secret_arn
      ECS_CLUSTER = module.litellm.ecs_cluster
      ECS_SERVICE = "${var.tenant}-litellm-${var.env}-gateway"
    }
  }

  tags = { "litellm:stack" = "${var.tenant}-litellm-${var.env}" }
}

# --- Schedule: run every N hours ---------------------------------------------
resource "aws_scheduler_schedule" "refresher" {
  count = local.refresher_enabled ? 1 : 0
  name  = local.refresher_name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(${var.codex_key_refresh_hours} hours)"

  target {
    arn      = aws_lambda_function.refresher[0].arn
    role_arn = aws_iam_role.scheduler[0].arn
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  count = local.refresher_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = local.refresher_enabled ? 1 : 0
  name               = "${local.refresher_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
  tags               = { "litellm:stack" = "${var.tenant}-litellm-${var.env}" }
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.refresher_enabled ? 1 : 0
  name  = "${local.refresher_name}-scheduler-policy"
  role  = aws_iam_role.scheduler[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.refresher[0].arn
    }]
  })
}

output "codex_key_refresher" {
  value = local.refresher_enabled ? {
    lambda        = aws_lambda_function.refresher[0].function_name
    every_hours   = var.codex_key_refresh_hours
    secret_arn    = local.bedrock_api_key_secret_arn
    rolls_service = "${var.tenant}-litellm-${var.env}-gateway"
  } : null
  description = "Codex/Mantle key auto-refresher (null when disabled)."
}
