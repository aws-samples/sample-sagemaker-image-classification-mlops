#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Auto-deploy handler - creates a new SageMaker endpoint config when a model is
approved in the Model Registry and points the endpoint at it.

SageMaker runs the blue/green rollout and auto-rollback natively using the
`deployment_config` already declared on the endpoint (see
`modules/sagemaker-endpoint/main.tf`). This Lambda's only job is to build the
new model + endpoint-config and call UpdateEndpoint; SageMaker handles the rest.

If PATCHED_IMAGE_URI is set, the new model runs against our private CVE-patched
ECR image instead of the public DLC; the model artefact is copied from the
approved model package either way.
"""

import json
import logging
import os
import re
import time
import uuid

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("sagemaker")

# Endpoint statuses from which UpdateEndpoint is NOT allowed. SageMaker rejects
# UpdateEndpoint unless the endpoint is InService, so we skip (and let the event
# retry) rather than create orphaned model/config resources we can't attach.
_DEPLOYABLE_STATUS = "InService"


def _build_container(model_package_arn):
    """Return a container spec for create_model.

    If PATCHED_IMAGE_URI is set, swap the image while keeping the artefact and
    environment from the approved model package. Otherwise reference the model
    package directly and let SageMaker pick the DLC.
    """
    patched_image_uri = os.environ.get("PATCHED_IMAGE_URI", "").strip()
    if not patched_image_uri:
        return {"ModelPackageName": model_package_arn}

    mp = sm.describe_model_package(ModelPackageName=model_package_arn)
    src = mp["InferenceSpecification"]["Containers"][0]
    logger.info(
        "Deploying with patched image %s (artefact %s)",
        patched_image_uri,
        src["ModelDataUrl"],
    )
    return {
        "Image": patched_image_uri,
        "ModelDataUrl": src["ModelDataUrl"],
        "Environment": src.get("Environment", {}),
    }


def _create_model_and_config(
    model_package_arn, project_name, monitoring_bucket, instance_type, data_capture_sampling
):
    # Microsecond + short uuid suffix so two approvals (or an EventBridge retry)
    # in the same second can't collide on the model/config name.
    suffix = f"{int(time.time())}-{uuid.uuid4().hex[:8]}"
    model_name = f"{project_name}-model-{suffix}"
    config_name = f"{project_name}-config-{suffix}"

    # Serverless-mode detection - set by Terraform via env vars when
    # use_serverless_inference = true. Defaults off so existing real-time
    # deployments behave exactly as before.
    use_serverless = os.environ.get("USE_SERVERLESS_INFERENCE", "false").lower() == "true"
    serverless_memory_mb = int(os.environ.get("SERVERLESS_MEMORY_SIZE_MB", "3072"))
    serverless_max_concurrency = int(os.environ.get("SERVERLESS_MAX_CONCURRENCY", "10"))

    container = _build_container(model_package_arn)
    tags = [
        {"Key": "Project", "Value": project_name},
        {"Key": "AutoDeployed", "Value": "true"},
        {"Key": "ModelPackageArn", "Value": model_package_arn},
        {"Key": "InferenceMode", "Value": "Serverless" if use_serverless else "RealTime"},
    ]

    logger.info(f"Creating model {model_name}")
    if "ModelPackageName" in container:
        sm.create_model(
            ModelName=model_name,
            Containers=[container],
            ExecutionRoleArn=os.environ["SAGEMAKER_ROLE"],
            Tags=tags,
        )
    else:
        sm.create_model(
            ModelName=model_name,
            PrimaryContainer=container,
            ExecutionRoleArn=os.environ["SAGEMAKER_ROLE"],
            Tags=[*tags, {"Key": "PatchedImage", "Value": "true"}],
        )

    logger.info(
        f"Creating endpoint config {config_name} (mode={'serverless' if use_serverless else 'real-time'})"
    )

    # Build production variant - instance-based or serverless. Both paths
    # must match what the Terraform module would create, so rollbacks and
    # Terraform plans stay in sync.
    if use_serverless:
        production_variant = {
            "VariantName": "AllTraffic",
            "ModelName": model_name,
            "ServerlessConfig": {
                "MemorySizeInMB": serverless_memory_mb,
                "MaxConcurrency": serverless_max_concurrency,
            },
        }
    else:
        production_variant = {
            "VariantName": "AllTraffic",
            "ModelName": model_name,
            "InitialInstanceCount": 1,
            "InstanceType": instance_type,
            "InitialVariantWeight": 1.0,
        }

    # DataCaptureConfig is not supported for serverless variants - SageMaker
    # rejects CreateEndpointConfig if both are set. For serverless deploys,
    # capture happens in the inference Lambda itself (see inference_handler).
    create_kwargs = {
        "EndpointConfigName": config_name,
        "ProductionVariants": [production_variant],
        "Tags": tags,
    }
    if not use_serverless:
        create_kwargs["DataCaptureConfig"] = {
            "EnableCapture": True,
            "InitialSamplingPercentage": data_capture_sampling,
            "DestinationS3Uri": f"s3://{monitoring_bucket}/data-capture",
            "CaptureOptions": [
                {"CaptureMode": "Input"},
                {"CaptureMode": "Output"},
            ],
        }

    sm.create_endpoint_config(**create_kwargs)
    return model_name, config_name


def lambda_handler(event, _context):
    logger.info(f"Received event: {json.dumps(event)}")

    model_package_arn = event.get("detail", {}).get("ModelPackageArn")
    if not model_package_arn:
        logger.error("ModelPackageArn missing from event detail")
        return {"statusCode": 400, "body": "missing ModelPackageArn"}

    # Defense in depth: even though the EventBridge rule already filters to this
    # project's model-package-group, validate the ARN shape and that it belongs
    # to the expected group + this account before acting on it, so a
    # misconfigured rule or a crafted PutEvents call can't drive a deploy of an
    # arbitrary/cross-account model package.
    expected_group = os.environ.get("MODEL_PACKAGE_GROUP_NAME", "")
    account_id = _context.invoked_function_arn.split(":")[4] if _context else ""
    arn_ok = re.match(
        r"^arn:aws:sagemaker:[a-z0-9-]+:\d{12}:model-package/[^/]+/\d+$",
        model_package_arn,
    )
    if not arn_ok or (account_id and f":{account_id}:" not in model_package_arn):
        logger.error(f"Rejecting unexpected ModelPackageArn: {model_package_arn}")
        return {"statusCode": 400, "body": "invalid ModelPackageArn"}
    if expected_group and f":model-package/{expected_group}/" not in model_package_arn:
        logger.error(f"ModelPackageArn not in expected group {expected_group}: {model_package_arn}")
        return {"statusCode": 400, "body": "model package group mismatch"}

    if event.get("detail", {}).get("ModelApprovalStatus") == "Rejected":
        logger.info("Model rejected, nothing to deploy")
        return {"statusCode": 200, "body": "model rejected, skipped"}

    endpoint_name = os.environ["ENDPOINT_NAME"]
    project_name = os.environ["PROJECT_NAME"]
    monitoring_bucket = os.environ.get("MONITORING_BUCKET", "")
    instance_type = os.environ.get("INSTANCE_TYPE", "ml.m5.xlarge")
    data_capture_sampling = int(os.environ.get("DATA_CAPTURE_SAMPLING_PERCENTAGE", "100"))

    # UpdateEndpoint only works on an InService endpoint. If the endpoint is
    # mid-deploy (e.g. a concurrent approval or the weekly refresher is rolling
    # it), don't create resources we can't attach - raise so the event retries
    # later. This both avoids the ValidationException AND the orphaned
    # model/config that a failed UpdateEndpoint would leave behind.
    try:
        status = sm.describe_endpoint(EndpointName=endpoint_name)["EndpointStatus"]
    except sm.exceptions.ClientError as exc:
        if "Could not find endpoint" in str(exc):
            logger.error(f"Endpoint {endpoint_name} does not exist yet; skipping deploy")
            return {"statusCode": 404, "body": "endpoint not found"}
        raise
    if status != _DEPLOYABLE_STATUS:
        raise RuntimeError(
            f"Endpoint {endpoint_name} is {status}, not {_DEPLOYABLE_STATUS}; "
            "retry once the in-flight deployment finishes."
        )

    model_name, config_name = _create_model_and_config(
        model_package_arn,
        project_name,
        monitoring_bucket,
        instance_type,
        data_capture_sampling,
    )

    # UpdateEndpoint uses the endpoint's declared deployment_config (blue/green
    # + auto-rollback) - see modules/sagemaker-endpoint/main.tf. We don't pass
    # a per-call DeploymentConfig here so there's one source of truth.
    logger.info(f"Updating endpoint {endpoint_name} -> {config_name}")
    try:
        sm.update_endpoint(
            EndpointName=endpoint_name,
            EndpointConfigName=config_name,
        )
    except Exception:
        # Don't leak the just-created model + config if the update fails;
        # otherwise every retry stacks another orphaned pair toward the
        # account's SageMaker quotas.
        logger.exception("UpdateEndpoint failed; cleaning up created model + config")
        for delete, kwargs in (
            (sm.delete_endpoint_config, {"EndpointConfigName": config_name}),
            (sm.delete_model, {"ModelName": model_name}),
        ):
            try:
                delete(**kwargs)
            except Exception as cleanup_exc:
                logger.warning(f"Cleanup failed for {kwargs}: {cleanup_exc}")
        raise

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "endpoint": endpoint_name,
                "endpoint_config": config_name,
                "model_package_arn": model_package_arn,
            }
        ),
    }
