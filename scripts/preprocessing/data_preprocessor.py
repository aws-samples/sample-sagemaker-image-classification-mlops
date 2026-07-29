#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import logging
import os
import shutil
import sys

import boto3
import numpy as np
from PIL import Image
from sklearn.model_selection import train_test_split

# Configure logging for SageMaker CloudWatch integration
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

# SMOTE lives in imbalanced-learn, which is an optional dependency. Guard the
# import so the module still loads in environments where it isn't installed;
# we log and skip oversampling at runtime instead of crashing on import.
try:
    from imblearn.over_sampling import SMOTE

    _SMOTE_AVAILABLE = True
except ImportError:
    SMOTE = None
    _SMOTE_AVAILABLE = False

DEFAULT_TARGET_SIZE = 512


def clear_processed_data_s3():
    """Clear existing processed data from S3 bucket before new preprocessing"""
    try:
        # Get S3 bucket info from environment or infer from output path
        project_name = os.environ.get("PROJECT_NAME", "medical-image-classification")
        region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

        s3 = boto3.client("s3", region_name=region)

        # List all buckets and find processed data bucket
        buckets = s3.list_buckets()["Buckets"]
        processed_bucket = None

        for bucket in buckets:
            bucket_name = bucket["Name"]
            if f"{project_name}" in bucket_name and "processed-data" in bucket_name:
                processed_bucket = bucket_name
                break

        if not processed_bucket:
            logger.warning("⚠️ Could not find processed data bucket - skipping S3 cleanup")
            return True

        logger.info(f"🧹 Clearing processed data from S3 bucket: {processed_bucket}")

        # Clear train, validation, test folders
        folders_to_clear = ["train/", "validation/", "test/"]

        for folder in folders_to_clear:
            try:
                # List objects in folder
                response = s3.list_objects_v2(Bucket=processed_bucket, Prefix=folder)

                if "Contents" in response:
                    objects_to_delete = [{"Key": obj["Key"]} for obj in response["Contents"]]

                    if objects_to_delete:
                        # Delete objects in batches of 1000 (S3 limit)
                        for i in range(0, len(objects_to_delete), 1000):
                            batch = objects_to_delete[i : i + 1000]
                            s3.delete_objects(Bucket=processed_bucket, Delete={"Objects": batch})
                        logger.info(f"✅ Cleared {len(objects_to_delete)} objects from {folder}")
                    else:
                        logger.info(f"📁 {folder} already empty")
                else:
                    logger.info(f"📁 {folder} does not exist or is empty")

            except Exception as e:
                logger.warning(f"⚠️ Failed to clear {folder}: {e!s}")

        logger.info("✅ S3 processed data cleanup completed")
        return True

    except Exception as e:
        logger.error(f"❌ S3 cleanup failed: {e!s}")
        # Don't fail the entire preprocessing if S3 cleanup fails
        return True


def validate_no_duplicates(train_files, val_files, test_files):
    """Validate that there are no duplicate files across splits"""
    train_set = set(train_files)
    val_set = set(val_files)
    test_set = set(test_files)

    # Check for overlaps
    train_val_overlap = train_set.intersection(val_set)
    train_test_overlap = train_set.intersection(test_set)
    val_test_overlap = val_set.intersection(test_set)

    if train_val_overlap:
        logger.error(f"❌ Train-Validation overlap: {len(train_val_overlap)} files")
        return False

    if train_test_overlap:
        logger.error(f"❌ Train-Test overlap: {len(train_test_overlap)} files")
        return False

    if val_test_overlap:
        logger.error(f"❌ Validation-Test overlap: {len(val_test_overlap)} files")
        return False

    logger.info("✅ No duplicate files across splits")
    return True


def resize_image(src_path, dst_path, target_size):
    """Resize one image to (target_size, target_size) RGB and save it.

    Resolution standardization only. Pixel normalization (/255 then ImageNet
    mean/std) is applied downstream at train/eval/inference time via the
    ImageNet transform - baking it in here would double-normalize the data.
    """
    with Image.open(src_path) as img:
        resized = img.convert("RGB").resize((target_size, target_size))
        resized.save(dst_path)


def balance_train_split_with_smote(train_dir, target_size):
    """Oversample the minority TRAIN class to a 1:1 ratio using SMOTE.

    SMOTE operates on flattened image vectors; synthetic samples are reshaped
    back to (target_size, target_size, 3) images and written into the minority
    class train dir with a `smote_synth_` filename prefix. Only the TRAIN split
    is touched - val/test must never be oversampled.
    """
    if not _SMOTE_AVAILABLE:
        logger.warning(
            "⚠️ imbalanced-learn not installed - skipping SMOTE class-imbalance correction"
        )
        return

    benign_dir = os.path.join(train_dir, "breast_benign")
    malignant_dir = os.path.join(train_dir, "breast_malignant")

    def load_class(class_dir):
        vectors = []
        for filename in sorted(os.listdir(class_dir)):
            if not filename.lower().endswith((".jpg", ".jpeg", ".png")):
                continue
            with Image.open(os.path.join(class_dir, filename)) as img:
                arr = np.asarray(img.convert("RGB").resize((target_size, target_size)))
            vectors.append(arr.reshape(-1))
        return vectors

    benign_vectors = load_class(benign_dir)
    malignant_vectors = load_class(malignant_dir)

    n_benign = len(benign_vectors)
    n_malignant = len(malignant_vectors)

    if n_benign == 0 or n_malignant == 0:
        logger.warning("⚠️ A train class is empty - skipping SMOTE")
        return
    if n_benign == n_malignant:
        logger.info("✅ Train split already balanced - skipping SMOTE")
        return

    # SMOTE labels: 0 = benign, 1 = malignant.
    x = np.vstack(benign_vectors + malignant_vectors)
    y = np.array([0] * n_benign + [1] * n_malignant)

    # k_neighbors must be < the minority class size; clamp it for tiny splits.
    minority_count = min(n_benign, n_malignant)
    k_neighbors = min(5, minority_count - 1)
    if k_neighbors < 1:
        logger.warning(f"⚠️ Minority class too small for SMOTE (count={minority_count}) - skipping")
        return

    logger.info(f"⚖️ Applying SMOTE on train split: {n_benign} benign vs {n_malignant} malignant")

    smote = SMOTE(random_state=42, k_neighbors=k_neighbors)
    x_resampled, y_resampled = smote.fit_resample(x, y)

    # Everything past the original rows is synthetic. Write synthetic samples
    # into the minority class dir (the only class SMOTE oversamples).
    minority_label = 0 if n_benign < n_malignant else 1
    minority_dir = benign_dir if minority_label == 0 else malignant_dir
    minority_name = "benign" if minority_label == 0 else "malignant"

    synth_count = 0
    for i in range(len(x), len(x_resampled)):
        if y_resampled[i] != minority_label:
            continue
        arr = x_resampled[i].reshape(target_size, target_size, 3).astype(np.uint8)
        dst = os.path.join(minority_dir, f"smote_synth_{synth_count}.png")
        Image.fromarray(arr).save(dst)
        synth_count += 1

    logger.info(f"✅ SMOTE added {synth_count} synthetic {minority_name} images to train split")
    logger.info(json.dumps({"metric_name": "SmoteSyntheticImages", "metric_value": synth_count}))


def preprocess_images(input_path, output_path, target_size=DEFAULT_TARGET_SIZE, apply_smote=False):
    """Preprocess medical images and split into train/val/test"""

    # Validate input parameters
    if not input_path or not output_path:
        logger.error("❌ Input path and output path are required")
        return False

    if not os.path.exists(input_path):
        logger.error(f"❌ Input path does not exist: {input_path}")
        return False

    try:
        os.makedirs(output_path, exist_ok=True)
    except Exception as e:
        logger.error(f"❌ Cannot create output directory: {e}")
        return False

    logger.info("Starting preprocessing...")
    logger.info(f"Input path: {input_path}")
    logger.info(f"Output path: {output_path}")

    # Clear existing processed data from S3
    logger.info("🧹 Clearing existing processed data...")
    clear_processed_data_s3()

    # Check input structure
    benign_dir = os.path.join(input_path, "breast_benign")
    malignant_dir = os.path.join(input_path, "breast_malignant")

    if not os.path.exists(benign_dir) or not os.path.exists(malignant_dir):
        logger.error(f"Expected directories not found: {benign_dir}, {malignant_dir}")
        return False

    # Count images
    benign_files = [
        f for f in os.listdir(benign_dir) if f.lower().endswith((".jpg", ".jpeg", ".png"))
    ]
    malignant_files = [
        f for f in os.listdir(malignant_dir) if f.lower().endswith((".jpg", ".jpeg", ".png"))
    ]

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
            logger.info(f"🧹 Cleared local directory: {split_dir}")

    # Create fresh directories with retry logic for filesystem delays
    import time

    for split_dir in [train_dir, val_dir, test_dir]:
        for attempt in range(3):
            try:
                os.makedirs(os.path.join(split_dir, "breast_benign"), exist_ok=True)
                os.makedirs(os.path.join(split_dir, "breast_malignant"), exist_ok=True)
                logger.info(f"✅ Created directory: {split_dir}")
                break
            except OSError as e:
                if attempt < 2:
                    logger.warning(
                        f"⚠️ Directory creation attempt {attempt + 1} failed: {e}. Retrying..."
                    )
                    time.sleep(2)
                    continue
                else:
                    logger.error(f"❌ Failed to create directory after 3 attempts: {e}")
                    raise e

    # Split data (70% train, 15% val, 15% test) with consistent random seed
    RANDOM_SEED = 42

    def split_files(files, class_name):
        # Sort files first for consistent ordering
        files = sorted(files)
        train_files, temp_files = train_test_split(
            files, test_size=0.3, random_state=RANDOM_SEED, shuffle=True
        )
        val_files, test_files = train_test_split(
            temp_files, test_size=0.5, random_state=RANDOM_SEED, shuffle=True
        )

        logger.info(
            f"{class_name}: {len(train_files)} train, {len(val_files)} val, {len(test_files)} test"
        )
        return train_files, val_files, test_files

    # Process benign images
    benign_train, benign_val, benign_test = split_files(benign_files, "benign")

    # Process malignant images
    malignant_train, malignant_val, malignant_test = split_files(malignant_files, "malignant")

    # Validate no duplicates across splits
    logger.info("🔍 Validating split integrity...")
    if not validate_no_duplicates(
        benign_train + malignant_train, benign_val + malignant_val, benign_test + malignant_test
    ):
        logger.error("❌ Split validation failed - overlapping files detected")
        return False

    # Resolution standardization: every image is resized to a fixed square
    # (target_size x target_size) RGB before being written to the split dirs.
    logger.info(f"📐 Standardizing all images to {target_size}x{target_size} RGB")

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

    # SMOTE class-imbalance correction - TRAIN split only. Synthetic minority
    # samples are written into the train dir, so refresh the train counts from
    # disk afterwards for accurate reporting.
    if apply_smote:
        balance_train_split_with_smote(train_dir, target_size)

        def count_split(split_dir, class_name):
            class_dir = os.path.join(split_dir, f"breast_{class_name}")
            return len(
                [f for f in os.listdir(class_dir) if f.lower().endswith((".jpg", ".jpeg", ".png"))]
            )

        train_benign_count = count_split(train_dir, "benign")
        train_malignant_count = count_split(train_dir, "malignant")

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
    import datetime

    dataset_version = f"v{datetime.datetime.utcnow().strftime('%Y%m%d.%H%M')}"
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

    # Log final validation
    logger.info("✅ Data preprocessing completed with:")
    logger.info("  • No duplicate files across splits")
    logger.info("  • Consistent random seed (42) for reproducibility")
    logger.info("  • Fresh data splits (old processed data cleared)")
    logger.info(f"  • Total unique images processed: {len(benign_files) + len(malignant_files)}")
    logger.info("  • Split distribution: 70% train, 15% val, 15% test")

    if total_train < 20 or total_val < 10 or total_test < 10:
        logger.error(
            f"❌ Insufficient data after split: train={total_train}, val={total_val}, test={total_test}"
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
        logger.error(f"❌ Failed to create summary file: {e}")
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
    parser.add_argument(
        "--apply-smote",
        action="store_true",
        help="Balance the train split to 1:1 using SMOTE on flattened image vectors",
    )

    args = parser.parse_args()

    logger.info("=== Data Preprocessing Started ===")

    try:
        success = preprocess_images(
            args.input_path,
            args.output_path,
            target_size=args.target_size,
            apply_smote=args.apply_smote,
        )
        if success:
            logger.info("✅ Preprocessing completed successfully")

            # Validate outputs were created
            required_outputs = [
                os.path.join(args.output_path, "train"),
                os.path.join(args.output_path, "validation"),
                os.path.join(args.output_path, "test"),
                os.path.join(args.output_path, "preprocessing_summary.json"),
            ]

            missing_outputs = [f for f in required_outputs if not os.path.exists(f)]
            if missing_outputs:
                logger.error(f"❌ Missing required outputs: {missing_outputs}")
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
                        f"❌ {split} split has no data: benign={benign_count}, malignant={malignant_count}"
                    )
                    sys.exit(1)

            logger.info("✅ All preprocessing outputs validated")
        else:
            logger.error("❌ Preprocessing failed")
            sys.exit(1)
    except Exception as e:
        logger.error(f"❌ Preprocessing failed with error: {e}")
        sys.exit(1)
