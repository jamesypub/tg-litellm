#!/usr/bin/env python3
# Canonical Codex key refresher for the no-Lambda path
# (codex_key_mode = external_cron_auto_refresh). Mints a short-lived Bedrock
# bearer token from the caller's AWS credentials, stores it in the gateway's
# secret, and rolls the ECS service so the new key is picked up.
#
# Single source of truth: docs and the customer setup script reference THIS file
# instead of pasting the body inline (drift risk — #84). boto3/botocore only, no
# extra deps. It NEVER logs the secret ARN or value — only the rolled service.
#
# Required env (the .sh wrapper sets these; env-scoped, no fixed global names):
#   REGION       AWS region of the gateway + Bedrock
#   SECRET_ARN   Secrets Manager ARN holding the Codex bearer key
#   ECS_CLUSTER  gateway ECS cluster name
#   ECS_SERVICE  gateway ECS service name
import base64
import os
import sys
import time
from datetime import datetime, timezone
import boto3
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest

HOST = "bedrock.amazonaws.com"
URL = f"https://{HOST}/"
SERVICE = "bedrock"
PREFIX = "bedrock-api-key-"
VERSION = "&Version=1"
TTL = 43200  # 12h; cron re-mints every 6h
# ECS injects the secret as an env var at task START and never re-reads it, so a
# fresh token is only actually served once the rolled task reaches steady state.
# Poll to steady state and emit success ONLY after it — printing success while two
# deployments are live is the #86 stale-token 401 (task keeps serving the OLD key).
# Bound the wait so a stuck roll fails loudly instead of hanging cron:
# 40 attempts * 15s = 10 min ceiling (mirrors the ECS services_stable waiter).
WAIT_DELAY = 15
WAIT_MAX_ATTEMPTS = 40


def _ts():
    """UTC ISO-8601 to the second, matching the existing refresh.log convention."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def progress(msg):
    """Timestamped phase/heartbeat line. Goes to STDERR so stdout stays the single
    canonical success line (#113): the run was invisible for up to 10 min inside the
    ECS wait and looked hung. Never logs the secret ARN or value."""
    print(f"{_ts()}  {msg}", file=sys.stderr, flush=True)


def mint_token(region):
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=URL, headers={"host": HOST},
                     params={"Action": "CallWithBearerToken"})
    SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
    return PREFIX + base64.b64encode((req.url.replace("https://", "") + VERSION).encode()).decode()


def _is_stable(ecs, cluster, service):
    """True once the rollout is complete: exactly one deployment and its running
    count equals the desired count. Mirrors the services_stable waiter's success
    condition so behaviour (and the #86 stale-token guarantee) is unchanged — we
    just poll it ourselves to emit heartbeats instead of blocking silently."""
    svc = ecs.describe_services(cluster=cluster, services=[service])["services"][0]
    deps = svc["deployments"]
    return len(deps) == 1 and deps[0]["runningCount"] == deps[0]["desiredCount"]


def main():
    region = os.environ["REGION"]
    cluster = os.environ["ECS_CLUSTER"]
    service = os.environ["ECS_SERVICE"]

    progress("minting Bedrock bearer token…")
    token = mint_token(region)
    progress("storing token in Secrets Manager…")
    boto3.client("secretsmanager", region_name=region).put_secret_value(
        SecretId=os.environ["SECRET_ARN"], SecretString=token)

    ecs = boto3.client("ecs", region_name=region)
    progress("triggering ECS deployment…")
    ecs.update_service(cluster=cluster, service=service, forceNewDeployment=True)

    # Poll to steady state (one deployment, running == desired) so the fresh key is
    # actually being served. Heartbeat each poll so a long roll visibly ticks rather
    # than going dark. Fail on timeout — do NOT print success.
    ceiling = WAIT_DELAY * WAIT_MAX_ATTEMPTS
    progress(f"waiting for service to reach steady state… (up to {ceiling}s)")
    start = time.monotonic()
    for attempt in range(1, WAIT_MAX_ATTEMPTS + 1):
        if _is_stable(ecs, cluster, service):
            break
        if attempt == WAIT_MAX_ATTEMPTS:
            raise SystemExit(
                f"refresh-codex-key: {service} did not reach steady state within "
                f"{ceiling}s; token stored but roll unconfirmed")
        time.sleep(WAIT_DELAY)
        progress(f"waiting for service to reach steady state… (attempt {attempt + 1}/{WAIT_MAX_ATTEMPTS})")

    progress(f"ECS update complete — {service} (stable)")
    print(f"rotated Codex key and rolled {service} (stable)")  # no secret ARN/value in logs


if __name__ == "__main__":
    main()
