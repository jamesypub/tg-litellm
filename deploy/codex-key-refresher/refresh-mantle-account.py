#!/usr/bin/env python3
# Mantle bearer-token refresher for a secondary AWS account (multi-account routing).
# Mints a Bedrock bearer token from the caller's AWS credentials, writes it to a
# Secrets Manager secret (which may live in a DIFFERENT account than the one that
# signed the token — cross-account write via a publisher role), injects the fresh
# token into the running LiteLLM gateway via POST /config/update (no ECS restart
# needed; picks up within ~30s), and optionally restarts the ECS service.
#
# Required env (the .sh wrapper sets these):
#   REGION              AWS region for Bedrock + Secrets Manager
#   SECRET_ARN          Secrets Manager ARN to write the token into (gateway account)
#   LITELLM_URL         Gateway base URL (e.g. https://xxx.cloudfront.net)
#   LITELLM_MASTER_KEY  Gateway admin key — injected into /config/update
#   BEDROCK_API_KEY_ENV Env var name the gateway reads for this account's bearer key
#                       (e.g. BEDROCK_API_KEY_DEMO0) — must match what tgw add-account set
#   UPDATE_ECS          true | false — whether to force-restart the ECS service after write
#   ECS_CLUSTER         gateway ECS cluster name  (only read when UPDATE_ECS=true)
#   ECS_SERVICE         gateway ECS service name  (only read when UPDATE_ECS=true)
#
# Design: each secondary-account cron runs with UPDATE_ECS=false and fires BEFORE
# the primary-account refresher (which always runs last with UPDATE_ECS=true).
# The /config/update call keeps the gateway's DB value fresh between restarts so
# the token is live within ~30s regardless of ECS restart timing.
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
import boto3
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest

HOST = "bedrock.amazonaws.com"
URL = f"https://{HOST}/"
SERVICE = "bedrock"
PREFIX = "bedrock-api-key-"
VERSION = "&Version=1"
TTL = 43200  # 12h presign; actual lifetime = min(TTL, caller's STS session)

WAIT_DELAY = 15
WAIT_MAX_ATTEMPTS = 40


def _ts():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def progress(msg):
    print(f"{_ts()}  {msg}", file=sys.stderr, flush=True)


def mint_token(region):
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=URL, headers={"host": HOST},
                     params={"Action": "CallWithBearerToken"})
    SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
    return PREFIX + base64.b64encode(
        (req.url.replace("https://", "") + VERSION).encode()
    ).decode()


def inject_config_update(gateway_url, master_key, key_name, token):
    """POST /config/update to keep the LiteLLM DB value fresh.

    tgw add-account writes the initial token here; the gateway uses this DB
    value at request time — Secrets Manager alone is insufficient (#132).
    """
    url = gateway_url.rstrip("/") + "/config/update"
    body = json.dumps({"environment_variables": {key_name: token}}).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={
            "Authorization": f"Bearer {master_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} from /config/update (response body redacted)")
    except urllib.error.URLError as e:
        raise RuntimeError(f"could not reach {url}: {e.reason}")


def _is_stable(ecs, cluster, service):
    svc = ecs.describe_services(cluster=cluster, services=[service])["services"][0]
    deps = svc["deployments"]
    return len(deps) == 1 and deps[0]["runningCount"] == deps[0]["desiredCount"]


def main():
    region = os.environ["REGION"]
    secret_arn = os.environ["SECRET_ARN"]
    gateway_url = os.environ["LITELLM_URL"]
    master_key = os.environ["LITELLM_MASTER_KEY"]
    key_env_var = os.environ["BEDROCK_API_KEY_ENV"]
    update_ecs = os.environ.get("UPDATE_ECS", "false").lower() == "true"

    progress("minting Bedrock bearer token…")
    token = mint_token(region)

    progress("storing token in Secrets Manager…")
    boto3.client("secretsmanager", region_name=region).put_secret_value(
        SecretId=secret_arn, SecretString=token)

    progress(f"injecting {key_env_var} into gateway via /config/update…")
    inject_config_update(gateway_url, master_key, key_env_var, token)
    progress(f"{key_env_var} injected — live in ~30s (no ECS restart required)")

    if not update_ecs:
        progress("UPDATE_ECS=false, skipping ECS restart")
        print(f"rotated Mantle token, stored in Secrets Manager + injected into gateway (no ECS restart)")
        return

    cluster = os.environ["ECS_CLUSTER"]
    service = os.environ["ECS_SERVICE"]

    ecs = boto3.client("ecs", region_name=region)
    progress("triggering ECS deployment…")
    ecs.update_service(cluster=cluster, service=service, forceNewDeployment=True)

    ceiling = WAIT_DELAY * WAIT_MAX_ATTEMPTS
    progress(f"waiting for service to reach steady state… (up to {ceiling}s)")
    for attempt in range(1, WAIT_MAX_ATTEMPTS + 1):
        if _is_stable(ecs, cluster, service):
            break
        if attempt == WAIT_MAX_ATTEMPTS:
            raise SystemExit(
                f"refresh-mantle-account: {service} did not reach steady state within "
                f"{ceiling}s; token stored but roll unconfirmed")
        time.sleep(WAIT_DELAY)
        progress(f"waiting for service to reach steady state… (attempt {attempt + 1}/{WAIT_MAX_ATTEMPTS})")

    progress(f"ECS update complete — {service} (stable)")
    print(f"rotated Mantle token, injected into gateway, and rolled {service} (stable)")


if __name__ == "__main__":
    main()
