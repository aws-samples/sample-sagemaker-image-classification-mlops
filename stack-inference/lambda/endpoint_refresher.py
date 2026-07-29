# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Endpoint refresher - forces the SageMaker endpoint to re-provision its
instances weekly so they pull the latest OS/container patches.

Triggered on a cron schedule by EventBridge. The Lambda:

1. Describes the current endpoint to get the active endpoint config.
2. Creates a *new* endpoint-config object with identical production-variant
   and data-capture settings, just a new name with a fresh timestamp.
3. Calls update-endpoint - SageMaker performs a blue/green deployment,
   replacing every instance with a freshly-provisioned host.

This mitigates OS-layer CVE findings that appear even after the container
image has been upgraded, because the underlying SageMaker host OS also
receives security patches over time.

Environment variables:
    ENDPOINT_NAME  (required)  SageMaker endpoint name to refresh.
"""

from __future__ import annotations

import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("sagemaker")


def _describe_source_config(config_name: str) -> dict:
    resp = sm.describe_endpoint_config(EndpointConfigName=config_name)
    return resp


def _clone_config(source_name: str, new_name: str) -> str:
    """Create a new endpoint-config with the same variants and data-capture
    settings as `source_name`, named `new_name`."""
    src = _describe_source_config(source_name)

    variants = []
    for v in src.get("ProductionVariants", []):
        variants.append(
            {
                "VariantName": v["VariantName"],
                "ModelName": v["ModelName"],
                "InitialInstanceCount": v.get("InitialInstanceCount", 1),
                "InstanceType": v["InstanceType"],
                "InitialVariantWeight": v.get("InitialVariantWeight", 1.0),
                **({"VolumeSizeInGB": v["VolumeSizeInGB"]} if "VolumeSizeInGB" in v else {}),
            }
        )

    kwargs = {
        "EndpointConfigName": new_name,
        "ProductionVariants": variants,
    }
    if "DataCaptureConfig" in src:
        dc = src["DataCaptureConfig"]
        kwargs["DataCaptureConfig"] = {
            "EnableCapture": dc.get("EnableCapture", False),
            "InitialSamplingPercentage": dc.get("InitialSamplingPercentage", 100),
            "DestinationS3Uri": dc["DestinationS3Uri"],
            "CaptureOptions": dc.get("CaptureOptions", []),
        }
        if "KmsKeyId" in dc:
            kwargs["DataCaptureConfig"]["KmsKeyId"] = dc["KmsKeyId"]
        if "CaptureContentTypeHeader" in dc:
            kwargs["DataCaptureConfig"]["CaptureContentTypeHeader"] = dc["CaptureContentTypeHeader"]
    if "KmsKeyId" in src:
        kwargs["KmsKeyId"] = src["KmsKeyId"]
    if src.get("EnableNetworkIsolation"):
        kwargs["EnableNetworkIsolation"] = src["EnableNetworkIsolation"]

    sm.create_endpoint_config(**kwargs)
    logger.info("Created endpoint-config %s (cloned from %s)", new_name, source_name)
    return new_name


def handler(event, context):
    endpoint_name = os.environ["ENDPOINT_NAME"]

    desc = sm.describe_endpoint(EndpointName=endpoint_name)
    status = desc["EndpointStatus"]
    current_config = desc["EndpointConfigName"]

    logger.info("Endpoint %s: status=%s  current_config=%s", endpoint_name, status, current_config)

    if status not in ("InService",):
        logger.warning(
            "Endpoint is %s - skipping refresh to avoid clobbering an "
            "in-flight deployment. It will be retried on next schedule.",
            status,
        )
        return {"skipped": True, "reason": f"endpoint status {status}"}

    new_config = f"{endpoint_name[:40]}-refresh-{int(time.time())}"
    _clone_config(current_config, new_config)

    sm.update_endpoint(
        EndpointName=endpoint_name,
        EndpointConfigName=new_config,
    )
    logger.info("Triggered blue/green roll of %s → %s", endpoint_name, new_config)

    return {"refreshed": True, "new_config": new_config}
