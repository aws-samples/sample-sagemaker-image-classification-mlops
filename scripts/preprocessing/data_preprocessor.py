#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import logging
import os
import shutil
import sys
import time
from datetime import UTC, datetime

from PIL import Image

# The step's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.breakhis import groups_overlap, patient_grouped_split
from mlops_common.constants import DEFAULT_SEED, IMAGE_EXTENSIONS
from mlops_common.preprocess import STORAGE_SIZE, standardize
from mlops_common.s3io import delete_prefix
from mlops_common.seeds import set_seeds

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

DEFAULT_TARGET_SIZE = STORAGE_SIZE
VAL_FRACTION = 0.15
TEST_FRACTION = 0.15


def clear_processed_data_s3(bucket):
    """Delete train/, validation/ and test/ in the named processed-data bucket.

    The bucket comes from PROCESSED_DATA_BUCKET; without it nothing is deleted.
    Stale images from an earlier run would otherwise mix into this run's splits.
    """
    if not bucket:
        logger.warning("PROCESSED_DATA_BUCKET not set - skipping S3 cleanup of old splits")
        return
    import boto3

    s3 = boto3.client("s3")
    for prefix in ("train/", "validation/", "test/"):
        try:
            count = delete_prefix(s3, bucket, prefix)
            logger.info("Cleared %d objects from s3://%s/%s", count, bucket, prefix)
        except Exception as e:
            logger.warning("Failed to clear s3://%s/%s: %s", bucket, prefix, e)


def resize_image(src_path, dst_path, target_size):
    """Resize one image to (target_size, target_size) RGB and save it.

    Resolution standardisation only, with the shared resample filter.
    Normalisation (/255 then ImageNet mean/std) happens at train, eval and
    inference time; baking it in here would double-normalise.
    """
    with Image.open(src_path) as img:
        standardize(img, target_size).save(dst_path)


def _list_images(class_dir):
    return sorted(f for f in os.listdir(class_dir) if f.lower().endswith(IMAGE_EXTENSIONS))


def preprocess_images(input_path, output_path, target_size=DEFAULT_TARGET_SIZE):
    """Standardise images and split them into train/validation/test by patient."""

    # Validate input parameters
    if not input_path or not output_path:
        logger.error("Input path and output path are required")
        return False

    if not os.path.exists(input_path):
        logger.error(f"Input path does not exist: {input_path}")
        return False

    try:
        os.makedirs(output_path, exist_ok=True)
    except Exception as e:
        logger.error(f"Cannot create output directory: {e}")
        return False

    logger.info("Starting preprocessing...")
    logger.info(f"Input path: {input_path}")
    logger.info(f"Output path: {output_path}")

    set_seeds(DEFAULT_SEED)
    clear_processed_data_s3(os.environ.get("PROCESSED_DATA_BUCKET", ""))

    # Check input structure
    benign_dir = os.path.join(input_path, "breast_benign")
    malignant_dir = os.path.join(input_path, "breast_malignant")

    if not os.path.exists(benign_dir) or not os.path.exists(malignant_dir):
        logger.error(f"Expected directories not found: {benign_dir}, {malignant_dir}")
        return False

    benign_files = _list_images(benign_dir)
    malignant_files = _list_images(malignant_dir)

    logger.info(f"Found {len(benign_files)} benign images")
    logger.info(f"Found {len(malignant_files)} malignant images")

    if len(benign_files) == 0 or len(malignant_files) == 0:
        logger.error("No images found in one or both categories")
        return False

    # Clear and create output directories with retry logic
    train_dir = os.path.join(output_path, "train")
    val_dir = os.path.join(output_path, "validation")
    test_dir = os.path.join(output_path, "test")

    # Remove existing directories if they exist
    for split_dir in [train_dir, val_dir, test_dir]:
        if os.path.exists(split_dir):
            shutil.rmtree(split_dir, ignore_errors=True)
            logger.info(f"Cleared local directory: {split_dir}")

    # Create fresh directories with retry logic for filesystem delays
    for split_dir in [train_dir, val_dir, test_dir]:
        for attempt in range(3):
            try:
                os.makedirs(os.path.join(split_dir, "breast_benign"), exist_ok=True)
                os.makedirs(os.path.join(split_dir, "breast_malignant"), exist_ok=True)
                logger.info(f"Created directory: {split_dir}")
                break
            except OSError as e:
                if attempt < 2:
                    logger.warning(
                        f"Directory creation attempt {attempt + 1} failed: {e}. Retrying..."
                    )
                    time.sleep(2)
                    continue
                else:
                    logger.error(f"Failed to create directory after 3 attempts: {e}")
                    raise e

    # Patient-grouped split: every image of one patient lands in one split, so
    # near-duplicate tiles cannot leak from train into validation or test.
    items = [(f, 0) for f in benign_files] + [(f, 1) for f in malignant_files]
    train_items, val_items, test_items = patient_grouped_split(
        items, VAL_FRACTION, TEST_FRACTION, DEFAULT_SEED
    )
    overlap = groups_overlap(train_items, val_items, test_items)
    if overlap:
        logger.error("Patient groups in more than one split: %s", overlap[:10])
        return False
    logger.info("No patient appears in more than one split")

    def by_class(split_items, label):
        return [f for f, lab in split_items if lab == label]

    benign_train, benign_val, benign_test = (
        by_class(x, 0) for x in (train_items, val_items, test_items)
    )
    malignant_train, malignant_val, malignant_test = (
        by_class(x, 1) for x in (train_items, val_items, test_items)
    )
    for name, tr, va, te in (
        ("benign", benign_train, benign_val, benign_test),
        ("malignant", malignant_train, malignant_val, malignant_test),
    ):
        logger.info("%s: %d train, %d val, %d test", name, len(tr), len(va), len(te))

    # Resolution standardization: every image is resized to a fixed square
    # (target_size x target_size) RGB before being written to the split dirs.
    logger.info(f"Standardizing all images to {target_size}x{target_size} RGB")

    def copy_files(file_list, source_dir, dest_dir, class_name):
        count = 0
        for filename in file_list:
            src = os.path.join(source_dir, filename)
            dst = os.path.join(dest_dir, f"breast_{class_name}", filename)
            try:
                resize_image(src, dst, target_size)
                count += 1
                # Progress logged via existing system
            except Exception as e:
                logger.warning(f"Failed to process {src}: {e}")
        return count

    # Copy training files
    train_benign_count = copy_files(benign_train, benign_dir, train_dir, "benign")
    train_malignant_count = copy_files(malignant_train, malignant_dir, train_dir, "malignant")

    # Copy validation files
    val_benign_count = copy_files(benign_val, benign_dir, val_dir, "benign")
    val_malignant_count = copy_files(malignant_val, malignant_dir, val_dir, "malignant")

    # Copy test files
    test_benign_count = copy_files(benign_test, benign_dir, test_dir, "benign")
    test_malignant_count = copy_files(malignant_test, malignant_dir, test_dir, "malignant")

    # Calculate totals
    total_train = train_benign_count + train_malignant_count
    total_val = val_benign_count + val_malignant_count
    total_test = test_benign_count + test_malignant_count

    logger.info("=== Preprocessing Complete ===")
    logger.info(f"Training: {train_benign_count} benign, {train_malignant_count} malignant")
    logger.info(f"Validation: {val_benign_count} benign, {val_malignant_count} malignant")
    logger.info(f"Test: {test_benign_count} benign, {test_malignant_count} malignant")

    # Log metrics for CloudWatch metric filters in CamelCase
    logger.info(json.dumps({"metric_name": "TrainingImageCount", "metric_value": total_train}))
    logger.info(json.dumps({"metric_name": "ValidationImageCount", "metric_value": total_val}))
    logger.info(json.dumps({"metric_name": "TestImageCount", "metric_value": total_test}))
    logger.info(
        json.dumps(
            {
                "metric_name": "TotalProcessedImages",
                "metric_value": total_train + total_val + total_test,
            }
        )
    )
    logger.info(
        json.dumps({"metric_name": "TrainingBenignCount", "metric_value": train_benign_count})
    )
    logger.info(
        json.dumps({"metric_name": "TrainingMalignantCount", "metric_value": train_malignant_count})
    )
    logger.info(
        json.dumps({"metric_name": "ValidationBenignCount", "metric_value": val_benign_count})
    )
    logger.info(
        json.dumps({"metric_name": "ValidationMalignantCount", "metric_value": val_malignant_count})
    )
    logger.info(json.dumps({"metric_name": "TestBenignCount", "metric_value": test_benign_count}))
    logger.info(
        json.dumps({"metric_name": "TestMalignantCount", "metric_value": test_malignant_count})
    )

    # Dataset History Record for Table
    dataset_version = f"v{datetime.now(UTC).strftime('%Y%m%d.%H%M')}"
    total_images = total_train + total_val + total_test
    total_benign = train_benign_count + val_benign_count + test_benign_count
    total_malignant = train_malignant_count + val_malignant_count + test_malignant_count

    dataset_history = {
        "dataset_version": dataset_version,
        "total_images": total_images,
        "train_images": total_train,
        "val_images": total_val,
        "test_images": total_test,
        "benign_images": total_benign,
        "malignant_images": total_malignant,
        "retraining_reason": os.environ.get("RETRAINING_REASON", "manual"),
        "status": "Success",
    }

    logger.info(json.dumps(dataset_history))

    # Keep human-readable logs too
    logger.info(f"Training Images: {total_train}")
    logger.info(f"Validation Images: {total_val}")
    logger.info(f"Test Images: {total_test}")

    logger.info(
        "Preprocessing complete: %d images, patient-grouped split (about 70/15/15 by "
        "patient), seed %d",
        len(benign_files) + len(malignant_files),
        DEFAULT_SEED,
    )

    if total_train < 20 or total_val < 10 or total_test < 10:
        logger.error(
            f"Insufficient data after split: train={total_train}, val={total_val}, test={total_test}"
        )
        return False

    # Create summary file
    summary = {
        "train": {"benign": train_benign_count, "malignant": train_malignant_count},
        "validation": {"benign": val_benign_count, "malignant": val_malignant_count},
        "test": {"benign": test_benign_count, "malignant": test_malignant_count},
        "status": "success",
        "total_processed": total_train + total_val + total_test,
    }

    try:
        with open(os.path.join(output_path, "preprocessing_summary.json"), "w") as f:
            json.dump(summary, f, indent=2)
    except Exception as e:
        logger.error(f"Failed to create summary file: {e}")
        return False

    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-path", required=True, help="Input data path")
    parser.add_argument("--output-path", required=True, help="Output data path")
    parser.add_argument(
        "--target-size",
        type=int,
        default=DEFAULT_TARGET_SIZE,
        help="Square edge length (px) to resize every image to",
    )
    # Accepted so an older pipeline definition that still passes the flag keeps
    # working; class imbalance is handled by class weights in the trainers.
    parser.add_argument("--apply-smote", action="store_true", help=argparse.SUPPRESS)

    args = parser.parse_args()

    logger.info("=== Data Preprocessing Started ===")

    try:
        if args.apply_smote:
            logger.warning("--apply-smote is ignored: the trainers use class weights instead")
        success = preprocess_images(args.input_path, args.output_path, target_size=args.target_size)
        if success:
            logger.info("Preprocessing completed successfully")

            # Validate outputs were created
            required_outputs = [
                os.path.join(args.output_path, "train"),
                os.path.join(args.output_path, "validation"),
                os.path.join(args.output_path, "test"),
                os.path.join(args.output_path, "preprocessing_summary.json"),
            ]

            missing_outputs = [f for f in required_outputs if not os.path.exists(f)]
            if missing_outputs:
                logger.error(f"Missing required outputs: {missing_outputs}")
                sys.exit(1)

            # Validate each split has data
            for split in ["train", "validation", "test"]:
                split_dir = os.path.join(args.output_path, split)
                benign_count = len(
                    [
                        f
                        for f in os.listdir(os.path.join(split_dir, "breast_benign"))
                        if f.lower().endswith((".jpg", ".jpeg", ".png"))
                    ]
                )
                malignant_count = len(
                    [
                        f
                        for f in os.listdir(os.path.join(split_dir, "breast_malignant"))
                        if f.lower().endswith((".jpg", ".jpeg", ".png"))
                    ]
                )

                if benign_count == 0 or malignant_count == 0:
                    logger.error(
                        f"{split} split has no data: benign={benign_count}, malignant={malignant_count}"
                    )
                    sys.exit(1)

            logger.info("All preprocessing outputs validated")
        else:
            logger.error("Preprocessing failed")
            sys.exit(1)
    except Exception as e:
        logger.error(f"Preprocessing failed with error: {e}")
        sys.exit(1)
