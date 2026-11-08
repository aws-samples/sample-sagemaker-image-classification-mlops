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
    PATCHED_IMAGE_REPOSITORY, PATCHED_IMAGE_REPOSITORY_URL  (optional)  The
                       patched serving image repository. When set, step 2 also
                       points each variant at a copy of its model that runs the
                       newest image in it, so a rebuilt image reaches the
                       endpoint at the next roll, and image models from earlier
                       runs that no config needs any more are deleted.
"""

from __future__ import annotations

import json
import logging
import os
import time

import boto3
from botocore.exceptions import BotoCoreError, ClientError

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


def model_prefix(endpoint_name: str) -> str:
    # Model names are capped at 63 characters.
    return f"{endpoint_name[:40]}-image-"


def newest_image_uri(ecr, repository: str, repository_url: str) -> str | None:
    """Newest tagged image in the patched repository, pinned by digest."""
    newest = None
    paginator = ecr.get_paginator("describe_images")
    for page in paginator.paginate(repositoryName=repository, filter={"tagStatus": "TAGGED"}):
        for image in page.get("imageDetails", []):
            if newest is None or image["imagePushedAt"] > newest["imagePushedAt"]:
                newest = image
    return f"{repository_url}@{newest['imageDigest']}" if newest else None


def repin_model_request(model: dict, image: str, new_name: str) -> dict:
    """CreateModel kwargs that copy `model` with its container image replaced."""
    request = {"ModelName": new_name, "ExecutionRoleArn": model["ExecutionRoleArn"]}
    container = {k: v for k, v in model["PrimaryContainer"].items() if k != "ImageConfig"}
    container["Image"] = image
    request["PrimaryContainer"] = container
    for key in ("EnableNetworkIsolation", "VpcConfig", "InferenceExecutionConfig"):
        if key in model:
            request[key] = model[key]
    return request


def repin_to_newest_image(
    sm, ecr, source: dict, endpoint_name: str, stamp: int
) -> tuple[dict, list]:
    """Point every variant at a copy of its model that runs the newest patched image.

    The weekly roll alone re-creates the hosts but keeps the image digest the
    model was created with, so container patches built since then would never
    reach the endpoint. Returns the (possibly rewritten) config and the names
    of the models it created.
    """
    image = newest_image_uri(
        ecr, os.environ["PATCHED_IMAGE_REPOSITORY"], os.environ["PATCHED_IMAGE_REPOSITORY_URL"]
    )
    if not image:
        return source, []
    variants, created = [], []
    for index, variant in enumerate(source.get("ProductionVariants", [])):
        variant = dict(variant)
        model = sm.describe_model(ModelName=variant["ModelName"])
        if (model.get("PrimaryContainer") or {}).get("Image") != image:
            name = f"{model_prefix(endpoint_name)}{stamp}-{index}"
            sm.create_model(**repin_model_request(model, image, name))
            variant["ModelName"] = name
            created.append(name)
        variants.append(variant)
    if not created:
        return source, []
    return {**source, "ProductionVariants": variants}, created


def superseded_models(sm, endpoint_name: str, keep: set) -> list:
    """Image models created by earlier runs that no config still needs."""
    prefix = model_prefix(endpoint_name)
    names = []
    paginator = sm.get_paginator("list_models")
    for page in paginator.paginate(NameContains=prefix):
        for model in page.get("Models", []):
            name = model["ModelName"]
            if name.startswith(prefix) and name not in keep:
                names.append(name)
    return sorted(names)


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


def handler(event, context, sm=None, ecr=None):
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
    stamp = int(time.time())
    new_config = f"{refresh_prefix(endpoint_name)}{stamp}"
    update_request = update_endpoint_request(endpoint_name, new_config)
    source = sm.describe_endpoint_config(EndpointConfigName=current_config)
    current_models = {v["ModelName"] for v in source.get("ProductionVariants", [])}
    created_models = []
    if os.environ.get("PATCHED_IMAGE_REPOSITORY"):
        source, created_models = repin_to_newest_image(
            sm, ecr or boto3.client("ecr"), source, endpoint_name, stamp
        )
        if created_models:
            logger.info("Repinned to the newest patched image: %s", ", ".join(created_models))
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
        except (ClientError, BotoCoreError) as exc:
            logger.warning("Could not delete superseded config %s: %s", name, type(exc).__name__)
    if deleted:
        logger.info("Deleted superseded refresh configs: %s", ", ".join(deleted))

    # The models of the config being replaced stay too: a rollback needs them.
    deleted_models = []
    if os.environ.get("PATCHED_IMAGE_REPOSITORY"):
        keep = current_models | set(created_models)
        for name in superseded_models(sm, endpoint_name, keep):
            try:
                sm.delete_model(ModelName=name)
                deleted_models.append(name)
            except (ClientError, BotoCoreError) as exc:
                logger.warning("Could not delete superseded model %s: %s", name, type(exc).__name__)

    return {
        "refreshed": True,
        "new_config": new_config,
        "deleted_configs": deleted,
        "created_models": created_models,
        "deleted_models": deleted_models,
    }
