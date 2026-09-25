#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Baseline Model Creation Script

This script creates a minimal TensorFlow model to satisfy SageMaker endpoint
creation requirements on first deployment. It is idempotent: it does nothing
when the group already holds an Approved or PendingManualApproval package.

The baseline model is a toy network that cannot classify images:
- Input: 30 features
- Hidden: 16 units with ReLU activation
- Output: 2 classes (benign, malignant) with softmax activation

The model is registered as PendingManualApproval and marked as a placeholder
in CustomerMetadataProperties (ModelRole=placeholder-baseline). It is not a
medical model: it only lets the first stack-inference apply create an
endpoint. A person approves it once, on purpose, before that first apply:

    aws sagemaker update-model-package \
        --model-package-arn <arn printed by this script> \
        --model-approval-status Approved \
        --approval-description "Placeholder for first endpoint deploy" \
        --profile <profile>

Model packages in a group inherit the group's tags and cannot take their own,
so the marker lives in CustomerMetadataProperties.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import tarfile
import tempfile
import uuid

import boto3

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Initialize AWS clients
sagemaker_client = boto3.client("sagemaker")
s3_client = boto3.client("s3")

PLACEHOLDER_METADATA = {
    "ModelRole": "placeholder-baseline",
    "ClinicalUse": "none",
}


def existing_model_package(model_package_group_name: str) -> dict | None:
    """Latest Approved or PendingManualApproval package in the group, if any.

    A pending package (the placeholder from an earlier run, or a pipeline
    model awaiting review) also counts: creating another placeholder on every
    run would only add registry noise.
    """
    try:
        for status in ("Approved", "PendingManualApproval"):
            logger.info(f"Checking for {status} models in group: {model_package_group_name}")
            response = sagemaker_client.list_model_packages(
                ModelPackageGroupName=model_package_group_name,
                ModelApprovalStatus=status,
                SortBy="CreationTime",
                SortOrder="Descending",
                MaxResults=1,
            )
            packages = response.get("ModelPackageSummaryList", [])
            if packages:
                return packages[0]
        return None

    except sagemaker_client.exceptions.ResourceNotFound:
        logger.warning(f"Model package group '{model_package_group_name}' not found")
        return None
    except Exception as e:
        logger.error(f"Failed to check Model Registry: {e}", exc_info=True)
        raise


def create_baseline_model() -> dict[str, str]:
    """
    Create a minimal TensorFlow model with simple architecture.

    The model is created using TensorFlow/Keras and saved in SavedModel format
    compatible with SageMaker TensorFlow serving containers.

    Returns:
        Dictionary containing:
            - model_dir: Local directory path where model is saved
            - model_tar_path: Path to compressed model tarball

    Raises:
        Exception: If model creation or saving fails
    """
    try:
        logger.info("Creating baseline TensorFlow model")

        # Import TensorFlow (lazy import to avoid loading if not needed)
        import tensorflow as tf

        # Create a simple sequential model
        model = tf.keras.Sequential(
            [
                tf.keras.layers.Input(shape=(30,), name="input"),
                tf.keras.layers.Dense(16, activation="relu", name="hidden"),
                tf.keras.layers.Dense(2, activation="softmax", name="output"),
            ]
        )

        # Compile the model
        model.compile(
            optimizer="adam", loss="sparse_categorical_crossentropy", metrics=["accuracy"]
        )

        logger.info("Model architecture created successfully")
        logger.info(f"Model summary:\n{model.summary()}")

        # Create temporary directory for model artifacts
        temp_dir = tempfile.mkdtemp()
        model_dir = os.path.join(temp_dir, "baseline-model", "1")
        os.makedirs(model_dir, exist_ok=True)

        # Save model in SavedModel format
        # Keras 3 requires using export() for SavedModel format (TensorFlow Serving)
        logger.info(f"Exporting model to SavedModel format: {model_dir}")
        model.export(model_dir)

        # Create tarball for S3 upload
        tar_path = os.path.join(temp_dir, "model.tar.gz")
        logger.info(f"Creating model tarball: {tar_path}")

        with tarfile.open(tar_path, "w:gz") as tar:
            # Add the model directory (version 1) to the tarball
            tar.add(model_dir, arcname="1")

        logger.info("Baseline model created successfully")

        return {"model_dir": model_dir, "model_tar_path": tar_path}

    except ImportError as e:
        logger.error(f"Failed to import TensorFlow: {e}", exc_info=True)
        logger.error("Please ensure TensorFlow is installed: pip install tensorflow")
        raise
    except Exception as e:
        logger.error(f"Failed to create baseline model: {e}", exc_info=True)
        raise


def upload_model_to_s3(model_tar_path: str, bucket: str, key: str) -> str:
    """
    Upload model tarball to S3.

    Args:
        model_tar_path: Local path to model tarball
        bucket: S3 bucket name
        key: S3 object key

    Returns:
        S3 URI of uploaded model (s3://bucket/key)

    Raises:
        Exception: If S3 upload fails
    """
    try:
        logger.info(f"Uploading model to s3://{bucket}/{key}")

        s3_client.upload_file(model_tar_path, bucket, key)

        s3_uri = f"s3://{bucket}/{key}"
        logger.info(f"Model uploaded successfully to: {s3_uri}")

        return s3_uri

    except Exception as e:
        logger.error(f"Failed to upload model to S3: {e}", exc_info=True)
        raise


def register_baseline_model(
    model_artifacts_uri: str,
    model_package_group_name: str,
    inference_image_uri: str,
    model_approval_status: str = "PendingManualApproval",
) -> str:
    """
    Register the placeholder baseline in Model Registry, pending manual approval.

    Args:
        model_artifacts_uri: S3 URI where model artifacts are stored
        model_package_group_name: Name of the model package group
        inference_image_uri: Docker image URI for TensorFlow serving
        model_approval_status: Approval status (default: 'PendingManualApproval')

    Returns:
        Model package ARN

    Raises:
        Exception: If model registration fails
    """
    try:
        logger.info(f"Registering baseline model in group: {model_package_group_name}")
        logger.info(f"Model artifacts URI: {model_artifacts_uri}")
        logger.info(f"Inference image URI: {inference_image_uri}")

        # Create model package
        response = sagemaker_client.create_model_package(
            ModelPackageGroupName=model_package_group_name,
            ModelPackageDescription=(
                "PLACEHOLDER baseline (30-feature toy network, not a medical model). "
                "Approve only to create the endpoint on first deploy."
            ),
            ModelApprovalStatus=model_approval_status,
            CustomerMetadataProperties=PLACEHOLDER_METADATA,
            InferenceSpecification={
                "Containers": [
                    {
                        "Image": inference_image_uri,
                        "ModelDataUrl": model_artifacts_uri,
                        "Framework": "TENSORFLOW",
                        # Must match the DLC tag actually used at serve time -
                        # the AWS SageMaker TF inference DLC stream caps at
                        # 2.19 (see stack-training/variables.tf
                        # sagemaker_images.tensorflow_inference_tag). Upstream
                        # TF is at 2.21 but AWS has not published 2.20/2.21
                        # DLCs for SageMaker yet.
                        "FrameworkVersion": "2.19",
                    }
                ],
                "SupportedContentTypes": ["application/json"],
                "SupportedResponseMIMETypes": ["application/json"],
                "SupportedRealtimeInferenceInstanceTypes": [
                    "ml.t2.medium",
                    "ml.m5.large",
                    "ml.m5.xlarge",
                ],
            },
        )

        model_package_arn = response["ModelPackageArn"]
        logger.info(f"Model registered successfully: {model_package_arn}")

        return model_package_arn

    except Exception as e:
        logger.error(f"Failed to register baseline model: {e}", exc_info=True)
        raise


def main():
    """
    Main entry point for baseline model creation.

    Implements idempotent logic:
    1. Check if an approved model already exists
    2. If yes, skip creation and exit successfully
    3. If no, create baseline model, upload to S3, and register in Model Registry

    Environment Variables:
        MODEL_PACKAGE_GROUP_NAME: Name of the SageMaker Model Package Group
        MODEL_ARTIFACTS_BUCKET: S3 bucket for storing model artifacts
        AWS_REGION: AWS region (default: us-east-1)
        INFERENCE_IMAGE_URI: Docker image URI for TensorFlow serving (optional)

    Exit Codes:
        0: Success (model created or already exists)
        1: Failure (error occurred)
    """
    try:
        # Parse command line arguments
        parser = argparse.ArgumentParser(description="Create baseline model for SageMaker endpoint")
        parser.add_argument(
            "--model-package-group-name",
            type=str,
            default=os.environ.get("MODEL_PACKAGE_GROUP_NAME"),
            help="SageMaker Model Package Group name",
        )
        parser.add_argument(
            "--model-artifacts-bucket",
            type=str,
            default=os.environ.get("MODEL_ARTIFACTS_BUCKET"),
            help="S3 bucket for model artifacts",
        )
        parser.add_argument(
            "--aws-region",
            type=str,
            default=os.environ.get("AWS_REGION", "us-east-1"),
            help="AWS region",
        )
        parser.add_argument(
            "--inference-image-uri",
            type=str,
            default=os.environ.get("INFERENCE_IMAGE_URI"),
            help="Docker image URI for TensorFlow serving",
        )

        args = parser.parse_args()

        # Validate required arguments
        if not args.model_package_group_name:
            logger.error("MODEL_PACKAGE_GROUP_NAME is required")
            sys.exit(1)

        if not args.model_artifacts_bucket:
            logger.error("MODEL_ARTIFACTS_BUCKET is required")
            sys.exit(1)

        # Set default inference image if not provided
        if not args.inference_image_uri:
            # Resolve to the current SageMaker TensorFlow Inference DLC for
            # the target region. The 763104351884 account ID is the canonical
            # DLC registry for commercial AWS regions; AWS GovCloud/CN use
            # different account IDs (see
            # https://github.com/aws/deep-learning-containers/blob/master/available_images.md).
            # The floating tag (no -v1.X suffix) auto-picks up AWS-published
            # patch versions, matching what stack-training/variables.tf
            # sets via sagemaker_images.tensorflow_inference_tag.
            account_id = os.environ.get("DLC_ACCOUNT_ID", "763104351884")
            dlc_tag = os.environ.get(
                "INFERENCE_IMAGE_TAG",
                "2.19.0-cpu-py312-ubuntu22.04-sagemaker",
            )
            args.inference_image_uri = (
                f"{account_id}.dkr.ecr.{args.aws_region}.amazonaws.com/"
                f"tensorflow-inference:{dlc_tag}"
            )
            logger.info(f"Using default inference image: {args.inference_image_uri}")

        logger.info("=" * 80)
        logger.info("Baseline Model Creation Script")
        logger.info("=" * 80)
        logger.info(f"Model Package Group: {args.model_package_group_name}")
        logger.info(f"Model Artifacts Bucket: {args.model_artifacts_bucket}")
        logger.info(f"AWS Region: {args.aws_region}")
        logger.info("=" * 80)

        # Step 1: skip when the group already has an approved or pending model
        existing = existing_model_package(args.model_package_group_name)
        if existing:
            logger.info(
                f"Model package already present ({existing['ModelApprovalStatus']}): "
                f"{existing['ModelPackageArn']}; skipping baseline creation"
            )
            sys.exit(0)

        # Step 2: Create baseline model
        logger.info("No approved or pending model found, creating placeholder baseline")
        model_artifacts = create_baseline_model()

        # Step 3: Upload model to S3
        s3_key = f"baseline-models/model-{uuid.uuid4().hex}.tar.gz"
        model_s3_uri = upload_model_to_s3(
            model_artifacts["model_tar_path"], args.model_artifacts_bucket, s3_key
        )

        # Step 4: Register model in Model Registry
        model_package_arn = register_baseline_model(
            model_s3_uri, args.model_package_group_name, args.inference_image_uri
        )

        logger.info("=" * 80)
        logger.info("Placeholder baseline registered as PendingManualApproval")
        logger.info(f"Model Package ARN: {model_package_arn}")
        logger.info(f"Model S3 URI: {model_s3_uri}")
        logger.info("Approve it once before the first stack-inference apply:")
        logger.info(
            f"  aws sagemaker update-model-package --model-package-arn {model_package_arn} "
            "--model-approval-status Approved --profile <profile>"
        )
        logger.info("=" * 80)

        sys.exit(0)

    except KeyboardInterrupt:
        logger.warning("Script interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Baseline model creation failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
