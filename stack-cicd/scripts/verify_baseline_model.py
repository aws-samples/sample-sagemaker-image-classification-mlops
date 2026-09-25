#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Verification Script for Baseline Model Creation

This script verifies that:
1. The baseline model creation script runs successfully
2. The group has an Approved model (the placeholder baseline counts once a
   person has approved it); a still-pending placeholder is reported with the
   command that approves it
3. Model artifacts are uploaded to S3

This is used for checkpoint verification in the implementation plan.
"""

import argparse
import logging
import os
import sys

import boto3

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Initialize AWS clients
sagemaker_client = boto3.client("sagemaker")
s3_client = boto3.client("s3")


def verify_model_registry(model_package_group_name: str) -> dict | None:
    """
    Verify that an approved model exists in Model Registry.

    Args:
        model_package_group_name: Name of the model package group

    Returns:
        Dictionary with model details if found, None otherwise
    """
    try:
        logger.info(f"Verifying Model Registry for group: {model_package_group_name}")

        # List approved models
        response = sagemaker_client.list_model_packages(
            ModelPackageGroupName=model_package_group_name,
            ModelApprovalStatus="Approved",
            SortBy="CreationTime",
            SortOrder="Descending",
            MaxResults=10,
        )

        model_packages = response.get("ModelPackageSummaryList", [])

        if not model_packages:
            logger.error("No approved models found in Model Registry")
            pending = sagemaker_client.list_model_packages(
                ModelPackageGroupName=model_package_group_name,
                ModelApprovalStatus="PendingManualApproval",
                SortBy="CreationTime",
                SortOrder="Descending",
                MaxResults=1,
            ).get("ModelPackageSummaryList", [])
            if pending:
                arn = pending[0]["ModelPackageArn"]
                logger.error(f"Pending model awaiting approval: {arn}")
                logger.error(
                    f"Approve it with: aws sagemaker update-model-package --model-package-arn "
                    f"{arn} --model-approval-status Approved --profile <profile>"
                )
            return None

        logger.info(f"Found {len(model_packages)} approved model(s)")

        # Get details of the latest approved model
        latest_model = model_packages[0]
        model_package_arn = latest_model["ModelPackageArn"]

        logger.info(f"Latest approved model ARN: {model_package_arn}")

        # Describe the model package to get full details
        model_details = sagemaker_client.describe_model_package(ModelPackageName=model_package_arn)

        # The placeholder baseline is marked in CustomerMetadataProperties
        # (packages in a group cannot carry their own tags).
        metadata = model_details.get("CustomerMetadataProperties", {})
        logger.info(f"Model approval status: {model_details['ModelApprovalStatus']}")
        if metadata.get("ModelRole") == "placeholder-baseline":
            logger.warning("Latest approved model is the placeholder baseline, not a medical model")
        else:
            logger.info("Latest approved model is a pipeline-trained model")

        return {
            "arn": model_package_arn,
            "approval_status": model_details["ModelApprovalStatus"],
            "model_role": metadata.get("ModelRole", "pipeline"),
            "model_data_url": model_details["InferenceSpecification"]["Containers"][0].get(
                "ModelDataUrl"
            ),
            "creation_time": latest_model["CreationTime"],
        }

    except sagemaker_client.exceptions.ResourceNotFound:
        logger.error(f"Model package group '{model_package_group_name}' not found")
        return None
    except Exception as e:
        logger.error(f"Failed to verify Model Registry: {e}", exc_info=True)
        return None


def verify_s3_artifacts(model_data_url: str) -> bool:
    """
    Verify that model artifacts exist in S3.

    Args:
        model_data_url: S3 URI of model artifacts (s3://bucket/key)

    Returns:
        True if artifacts exist, False otherwise
    """
    try:
        logger.info(f"Verifying S3 artifacts at: {model_data_url}")

        # Parse S3 URI
        if not model_data_url.startswith("s3://"):
            logger.error(f"Invalid S3 URI: {model_data_url}")
            return False

        s3_path = model_data_url[5:]  # Remove 's3://'
        bucket, key = s3_path.split("/", 1)

        logger.info(f"S3 Bucket: {bucket}")
        logger.info(f"S3 Key: {key}")

        # Check if object exists
        response = s3_client.head_object(Bucket=bucket, Key=key)

        logger.info("Model artifacts found in S3")
        logger.info(f"Object size: {response['ContentLength']} bytes")
        logger.info(f"Last modified: {response['LastModified']}")

        return True

    except s3_client.exceptions.NoSuchKey:
        logger.error(f"Model artifacts not found in S3: {model_data_url}")
        return False
    except s3_client.exceptions.NoSuchBucket:
        logger.error(f"S3 bucket not found: {bucket}")
        return False
    except Exception as e:
        logger.error(f"Failed to verify S3 artifacts: {e}", exc_info=True)
        return False


def main():
    """
    Main verification function.

    Checks:
    1. Model Registry has approved model
    2. Model artifacts exist in S3
    3. Model is properly tagged

    Exit Codes:
        0: All verifications passed
        1: One or more verifications failed
    """
    try:
        parser = argparse.ArgumentParser(description="Verify baseline model creation")
        parser.add_argument(
            "--model-package-group-name",
            type=str,
            default=os.environ.get("MODEL_PACKAGE_GROUP_NAME"),
            help="SageMaker Model Package Group name",
        )

        args = parser.parse_args()

        if not args.model_package_group_name:
            logger.error("MODEL_PACKAGE_GROUP_NAME is required")
            sys.exit(1)

        logger.info("=" * 80)
        logger.info("Baseline Model Creation Verification")
        logger.info("=" * 80)
        logger.info(f"Model Package Group: {args.model_package_group_name}")
        logger.info("=" * 80)

        # Verification 1: Check Model Registry
        logger.info("\n[1/2] Verifying Model Registry...")
        model_details = verify_model_registry(args.model_package_group_name)

        if not model_details:
            logger.error("\nVERIFICATION FAILED: No approved model in Model Registry")
            sys.exit(1)

        # Verification 2: Check S3 artifacts
        logger.info("\n[2/2] Verifying S3 artifacts...")
        if not model_details.get("model_data_url"):
            logger.error("VERIFICATION FAILED: Model data URL not found")
            sys.exit(1)

        s3_verified = verify_s3_artifacts(model_details["model_data_url"])

        if not s3_verified:
            logger.error("\nVERIFICATION FAILED: Model artifacts not found in S3")
            sys.exit(1)

        # All verifications passed
        logger.info("\n" + "=" * 80)
        logger.info("ALL VERIFICATIONS PASSED")
        logger.info("=" * 80)
        logger.info("\nSummary:")
        logger.info(f"  Model ARN: {model_details['arn']}")
        logger.info(f"  Approval Status: {model_details['approval_status']}")
        logger.info(f"  Model Role: {model_details['model_role']}")
        logger.info(f"  S3 Location: {model_details['model_data_url']}")
        logger.info(f"  Created: {model_details['creation_time']}")
        logger.info("=" * 80)

        sys.exit(0)

    except KeyboardInterrupt:
        logger.warning("\nVerification interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"\nVerification failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
