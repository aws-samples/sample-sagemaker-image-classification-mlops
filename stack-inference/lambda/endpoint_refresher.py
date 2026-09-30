# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Endpoint refresher: rolls the SageMaker endpoint weekly onto fresh hosts so
instances pick up the latest host OS and container patches.

Triggered on a schedule by EventBridge. The Lambda:

1. Describes the endpoint to find its active endpoint config.
2. Clones that config under a new timestamped name. Every field is copied
   except the name, ARN and creation time, so settings added later (VPC,
   async, shadow variants, execution role, serverless config) survive.
3. Calls UpdateEndpoint; SageMaker performs a blue/green replacement with
   DEPLOYMENT_CONFIG, the same traffic policy (canary by default) and
   auto-rollback alarms the auto-deploy Lambda sends.
4. Deletes refresh configs from earlier runs. The config being replaced is
   kept, because a blue/green rollback returns to it.

Environment variables:
    ENDPOINT_NAME      (required)  SageMaker endpoint name to refresh.
    DEPLOYMENT_CONFIG  (optional)  UpdateEndpoint DeploymentConfig JSON, the
                       endpoint module's deployment_config_json output. Empty
                       = RetainDeploymentConfig (reuse the last one).
"""

from __future__ import annotations

import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Response-only fields of DescribeEndpointConfig that CreateEndpointConfig rejects.
_NOT_COPIED = {"EndpointConfigName", "EndpointConfigArn", "CreationTime", "ResponseMetadata"}


def refresh_prefix(endpoint_name: str) -> str:
    # Endpoint config names are capped at 63 characters.
    return f"{endpoint_name[:40]}-refresh-"


def clone_config_request(source: dict, new_name: str, running: dict | None = None) -> dict:
    """CreateEndpointConfig kwargs that reproduce `source` under `new_name`.

    `running` maps variant name to its current instance count. A variant's
    InitialInstanceCount is raised to it, because auto scaling may have grown
    the fleet past the config's count and a canary is rejected on one instance.
    """
    request = {k: v for k, v in source.items() if k not in _NOT_COPIED}
    request["EndpointConfigName"] = new_name
    running = running or {}
    variants = []
    for variant in request.get("ProductionVariants", []):
        variant = dict(variant)
        current = running.get(variant.get("VariantName"))
        if "InitialInstanceCount" in variant and current:
            variant["InitialInstanceCount"] = max(variant["InitialInstanceCount"], current)
        variants.append(variant)
    if variants:
        request["ProductionVariants"] = variants
    return request


def update_endpoint_request(endpoint_name: str, config_name: str) -> dict:
    """UpdateEndpoint kwargs: DEPLOYMENT_CONFIG when set, else retain the last config."""
    request = {"EndpointName": endpoint_name, "EndpointConfigName": config_name}
    raw = os.environ.get("DEPLOYMENT_CONFIG", "").strip()
    if raw:
        request["DeploymentConfig"] = json.loads(raw)
    else:
        request["RetainDeploymentConfig"] = True
    return request


def superseded_configs(sm, endpoint_name: str, keep: set) -> list:
    """Refresh configs created by earlier runs that are no longer needed."""
    prefix = refresh_prefix(endpoint_name)
    names = []
    paginator = sm.get_paginator("list_endpoint_configs")
    for page in paginator.paginate(NameContains=prefix):
        for cfg in page.get("EndpointConfigs", []):
            name = cfg["EndpointConfigName"]
            if name.startswith(prefix) and name not in keep:
                names.append(name)
    return sorted(names)


def handler(event, context, sm=None):
    sm = sm or boto3.client("sagemaker")
    endpoint_name = os.environ["ENDPOINT_NAME"]

    desc = sm.describe_endpoint(EndpointName=endpoint_name)
    status = desc["EndpointStatus"]
    current_config = desc["EndpointConfigName"]
    logger.info("Endpoint %s: status=%s current_config=%s", endpoint_name, status, current_config)

    if status != "InService":
        logger.warning(
            "Endpoint is %s - skipping refresh so an in-flight deployment is not "
            "clobbered. The next schedule retries.",
            status,
        )
        return {"skipped": True, "reason": f"endpoint status {status}"}

    # Parsed before anything is created, so a bad value leaves no orphan config.
    new_config = f"{refresh_prefix(endpoint_name)}{int(time.time())}"
    update_request = update_endpoint_request(endpoint_name, new_config)
    source = sm.describe_endpoint_config(EndpointConfigName=current_config)
    running = {
        v["VariantName"]: v.get("CurrentInstanceCount", 0)
        for v in desc.get("ProductionVariants", [])
    }
    sm.create_endpoint_config(**clone_config_request(source, new_config, running))
    logger.info("Created endpoint config %s (cloned from %s)", new_config, current_config)

    sm.update_endpoint(**update_request)
    logger.info("Triggered blue/green roll of %s to %s", endpoint_name, new_config)

    deleted = []
    for name in superseded_configs(sm, endpoint_name, keep={current_config, new_config}):
        try:
            sm.delete_endpoint_config(EndpointConfigName=name)
            deleted.append(name)
        except Exception as exc:
            logger.warning("Could not delete superseded config %s: %s", name, exc)
    if deleted:
        logger.info("Deleted superseded refresh configs: %s", ", ".join(deleted))

    return {"refreshed": True, "new_config": new_config, "deleted_configs": deleted}
