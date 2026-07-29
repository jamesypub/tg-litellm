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
import boto3
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest
from botocore.exceptions import WaiterError

HOST = "bedrock.amazonaws.com"
URL = f"https://{HOST}/"
SERVICE = "bedrock"
PREFIX = "bedrock-api-key-"
VERSION = "&Version=1"
TTL = 43200  # 12h; cron re-mints every 6h
# ECS injects the secret as an env var at task START and never re-reads it, so a
# fresh token is only actually served once the rolled task reaches steady state.
# Block on the stability waiter and emit success ONLY after it — printing success
# while two deployments are live is the #86 stale-token 401 (task keeps serving the
# OLD key). Bound the wait so a stuck roll fails loudly instead of hanging cron:
# 40 attempts * 15s = 10 min ceiling (ECS waiter default cadence).
WAIT_DELAY = 15
WAIT_MAX_ATTEMPTS = 40


def mint_token(region):
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=URL, headers={"host": HOST},
                     params={"Action": "CallWithBearerToken"})
    SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
    return PREFIX + base64.b64encode((req.url.replace("https://", "") + VERSION).encode()).decode()


def main():
    region = os.environ["REGION"]
    cluster = os.environ["ECS_CLUSTER"]
    service = os.environ["ECS_SERVICE"]
    token = mint_token(region)
    boto3.client("secretsmanager", region_name=region).put_secret_value(
        SecretId=os.environ["SECRET_ARN"], SecretString=token)
    ecs = boto3.client("ecs", region_name=region)
    ecs.update_service(cluster=cluster, service=service, forceNewDeployment=True)
    # Wait for the rollout to reach steady state (one deployment) so the fresh key
    # is actually being served. Fail on waiter timeout — do NOT print success.
    waiter = ecs.get_waiter("services_stable")
    try:
        waiter.wait(cluster=cluster, services=[service],
                    WaiterConfig={"Delay": WAIT_DELAY, "MaxAttempts": WAIT_MAX_ATTEMPTS})
    except WaiterError:
        raise SystemExit(
            f"refresh-codex-key: {service} did not reach steady state within "
            f"{WAIT_DELAY * WAIT_MAX_ATTEMPTS}s; token stored but roll unconfirmed")
    print(f"rotated Codex key and rolled {service} (stable)")  # no secret ARN/value in logs


if __name__ == "__main__":
    main()
