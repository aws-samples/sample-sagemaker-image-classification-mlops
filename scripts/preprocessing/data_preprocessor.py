#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import logging
import os
import shutil
import socket
import sys
import time
from datetime import UTC, datetime

from PIL import Image

# The step's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.constants import DEFAULT_SEED
from mlops_common.dataset_layout import (
    describe_image,
    discover_classes,
    grouped_split,
    groups_overlap,
    list_images,
    read_manifest,
    write_classes,
    write_manifest,
)
from mlops_common.preprocess import STORAGE_SIZE, standardize
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
SPLITS = ("train", "validation", "test")
SPLIT_METRIC_NAMES = {"train": "Training", "validation": "Validation", "test": "Test"}

# Written by the validation step (scripts/validation/data_validator.py).
EXCLUSION_MANIFEST = "exclusion_manifest.json"
IMAGE_INVENTORY = "image_inventory.json"
RESOURCE_CONFIG = "/opt/ml/config/resourceconfig.json"


def cluster_hosts(resource_config=RESOURCE_CONFIG):
    """(this host, all hosts) of the processing job; a single local host outside SageMaker."""
    try:
        with open(resource_config) as f:
            config = json.load(f)
        return config["current_host"], sorted(config["hosts"])
    except (OSError, KeyError, ValueError):
        host = socket.gethostname()
        return host, [host]


def load_validation_report(report_dir):
    """(inventory or None, excluded entries) from the validation step's output.

    The inventory (``class_names`` and ``images``) lists every readable image
    the validation step saw, across all shards, with its group id and
    attributes; the exclusion manifest lists the images it kept out of
    training, each with a reason.
    """
    inventory = None
    excluded = []
    if report_dir:
        inv_path = os.path.join(report_dir, IMAGE_INVENTORY)
        if os.path.exists(inv_path):
            with open(inv_path) as f:
                inventory = json.load(f)
        man_path = os.path.join(report_dir, EXCLUSION_MANIFEST)
        if os.path.exists(man_path):
            with open(man_path) as f:
                excluded = json.load(f)["excluded"]
    return inventory, excluded


def resize_image(src_path, dst_path, target_size):
    """Resize one image to (target_size, target_size) RGB and save it.

    Resolution standardisation only, with the shared resample filter.
    Normalisation happens at train, eval and inference time; baking it in here
    would double-normalise.
    """
    with Image.open(src_path) as img:
        standardize(img, target_size).save(dst_path)


def _local_inventory(input_path):
    """Inventory of the local images when there is no validation report (one instance)."""
    class_names = discover_classes(input_path)
    manifest = read_manifest(input_path)
    images = []
    for label, name in enumerate(class_names):
        for f in list_images(os.path.join(input_path, name)):
            file = f"{name}/{f}"
            images.append({"file": file, "label": label, **describe_image(file, manifest)})
    return {"class_names": list(class_names), "images": images}


def _make_dirs(path):
    for attempt in range(3):
        try:
            os.makedirs(path, exist_ok=True)
            return
        except OSError as e:
            if attempt == 2:
                raise
            logger.warning("Directory creation attempt %d failed: %s. Retrying...", attempt + 1, e)
            time.sleep(2)


def preprocess_images(
    input_path, output_path, target_size=DEFAULT_TARGET_SIZE, validation_report_path=None
):
    """Standardise images and split them into train/validation/test by group.

    With several instances each one holds only its share of the raw images
    (ShardedByS3Key). The split is therefore computed from the validation
    step's inventory of every image, never from the local files, so every
    instance puts a group in the same split; each instance then writes only
    the images it holds. Images in the exclusion manifest are skipped and
    logged. The first instance also writes classes.json and manifest.csv into
    every split, for the training, evaluation and ensemble steps.
    """
    if not input_path or not output_path:
        logger.error("Input path and output path are required")
        return False

    if not os.path.exists(input_path):
        logger.error(f"Input path does not exist: {input_path}")
        return False

    try:
        os.makedirs(output_path, exist_ok=True)
    except OSError as e:
        logger.error(f"Cannot create output directory: {e}")
        return False

    logger.info("Starting preprocessing...")
    logger.info(f"Input path: {input_path}")
    logger.info(f"Output path: {output_path}")

    set_seeds(DEFAULT_SEED)

    host, hosts = cluster_hosts()
    first_host = host == hosts[0]

    inventory, excluded = load_validation_report(validation_report_path)
    if inventory is None:
        if len(hosts) > 1:
            logger.error(
                "%s not found under %s: with %d instances the split needs the validation "
                "step's inventory of every image",
                IMAGE_INVENTORY,
                validation_report_path,
                len(hosts),
            )
            return False
        try:
            inventory = _local_inventory(input_path)
        except ValueError as e:
            logger.error("Cannot read the dataset layout: %s", e)
            return False

    class_names = tuple(inventory["class_names"])
    images = {str(i["file"]): i for i in inventory["images"]}
    groups = {file: image.get("group") for file, image in images.items()}

    # A share may hold images of one class only, so a missing class directory
    # is an empty one; the whole-dataset class check below uses the inventory.
    local_items = {
        (f"{name}/{f}", label)
        for label, name in enumerate(class_names)
        for f in list_images(os.path.join(input_path, name))
    }
    if not local_items:
        logger.error("No images under %s for the classes %s", input_path, class_names)
        return False
    logger.info(
        "Host %s (%d of %d): %d images in this share",
        host,
        hosts.index(host) + 1 if host in hosts else 1,
        len(hosts),
        len(local_items),
    )

    # Every image the validation step excluded is left out of all three splits.
    excluded_keys = {(str(e["file"]), int(e["label"])) for e in excluded}
    for entry in excluded:
        logger.info("Excluded by validation: %s (%s)", entry["file"], entry["reason"])
    inventory_items = {(file, int(image["label"])) for file, image in images.items()}
    all_items = sorted(inventory_items - excluded_keys)
    unvalidated = sorted(local_items - inventory_items - excluded_keys)
    for file, _ in unvalidated:
        logger.warning(
            "Skipped %s: not in the validation inventory (uploaded after validation ran)", file
        )

    if not any(label == 0 for _, label in all_items) or not any(
        label == 1 for _, label in all_items
    ):
        logger.error("No images found in one or both classes")
        return False

    # Clear and create output directories with retry logic
    split_dirs = {split: os.path.join(output_path, split) for split in SPLITS}
    for split_dir in split_dirs.values():
        if os.path.exists(split_dir):
            shutil.rmtree(split_dir, ignore_errors=True)
            logger.info(f"Cleared local directory: {split_dir}")
    for split_dir in split_dirs.values():
        for name in class_names:
            _make_dirs(os.path.join(split_dir, name))

    # Group split: every image of one group lands in one split, so near-
    # duplicate images cannot leak from train into validation or test. It is a
    # deterministic function of the full inventory, so every instance computes
    # the same assignment.
    train_items, val_items, test_items = grouped_split(
        all_items, VAL_FRACTION, TEST_FRACTION, DEFAULT_SEED, groups
    )
    overlap = groups_overlap(train_items, val_items, test_items, groups=groups)
    if overlap:
        logger.error("Groups in more than one split: %s", overlap[:10])
        return False
    logger.info("No group appears in more than one split")
    split_items = dict(zip(SPLITS, (train_items, val_items, test_items)))

    def count(items, label):
        return sum(1 for _, lab in items if lab == label)

    # Whole-dataset sizes, the same on every instance.
    split_sizes = {
        split: {name: count(items, label) for label, name in enumerate(class_names)}
        for split, items in split_items.items()
    }
    for split, sizes in split_sizes.items():
        logger.info("%s split: %s", split, sizes)
    empty = [s for s, sizes in split_sizes.items() if not all(sizes.values())]
    totals = {split: sum(sizes.values()) for split, sizes in split_sizes.items()}
    if empty or totals["train"] < 20 or totals["validation"] < 10 or totals["test"] < 10:
        logger.error("Insufficient data after split: %s, splits missing a class: %s", totals, empty)
        return False

    # Resolution standardization: every image is resized to a fixed square
    # (target_size x target_size) RGB before being written to the split dirs.
    # This instance writes only the images it holds.
    logger.info(f"Standardizing all images to {target_size}x{target_size} RGB")
    failed = []
    written = {}
    for split, items in split_items.items():
        written[split] = dict.fromkeys(class_names, 0)
        for file, label in items:
            if (file, label) not in local_items:
                continue
            src = os.path.join(input_path, file)
            dst = os.path.join(split_dirs[split], file)
            try:
                resize_image(src, dst, target_size)
                written[split][class_names[label]] += 1
            except (OSError, ValueError, Image.DecompressionBombError) as e:
                logger.error(f"Failed to process {src}: {e}")
                failed.append(src)

    logger.info("=== Preprocessing Complete on %s ===", host)
    for split, counts in written.items():
        logger.info("%s: wrote %s", split, counts)
    if failed:
        logger.error("%d image(s) could not be standardised: %s", len(failed), failed[:10])
        return False

    negative, positive = class_names
    if first_host:
        for split, items in split_items.items():
            write_classes(split_dirs[split], class_names)
            write_manifest(
                split_dirs[split],
                (
                    {
                        "file": file,
                        "label": class_names[label],
                        "group": images[file].get("group"),
                        "attributes": images[file].get("attributes"),
                    }
                    for file, label in items
                ),
            )

        # CloudWatch metric filters read these lines. They describe the whole
        # dataset, so only the first instance logs them.
        metrics = {
            "TotalProcessedImages": sum(totals.values()),
            "ExcludedImageCount": len(excluded),
        }
        for split, prefix in SPLIT_METRIC_NAMES.items():
            metrics[f"{prefix}ImageCount"] = totals[split]
            metrics[f"{prefix}NegativeCount"] = split_sizes[split][negative]
            metrics[f"{prefix}PositiveCount"] = split_sizes[split][positive]
        for name, value in metrics.items():
            logger.info(json.dumps({"metric_name": name, "metric_value": value}))

        logger.info(
            json.dumps(
                {
                    "dataset_version": f"v{datetime.now(UTC).strftime('%Y%m%d.%H%M')}",
                    "total_images": sum(totals.values()),
                    "train_images": totals["train"],
                    "val_images": totals["validation"],
                    "test_images": totals["test"],
                    "class_names": list(class_names),
                    "positive_class": positive,
                    "excluded_images": len(excluded),
                    "retraining_reason": os.environ.get("RETRAINING_REASON", "manual"),
                    "status": "Success",
                }
            )
        )

    logger.info(
        "Preprocessing complete: %d images in the dataset, %d excluded by validation, "
        "%d not validated; group split (about 70/15/15 by group), seed %d",
        len(all_items),
        len(excluded),
        len(unvalidated),
        DEFAULT_SEED,
    )

    summary = {
        "host": host,
        "hosts": hosts,
        "class_names": list(class_names),
        "dataset": split_sizes,
        "written_by_this_host": written,
        "excluded_by_validation": len(excluded),
        "not_validated": [file for file, _ in unvalidated],
        "status": "success",
    }

    try:
        with open(os.path.join(output_path, "preprocessing_summary.json"), "w") as f:
            json.dump(summary, f, indent=2)
    except OSError as e:
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
    parser.add_argument(
        "--validation-report-path",
        help="Validation step output with image_inventory.json and exclusion_manifest.json",
    )
    args = parser.parse_args()

    logger.info("=== Data Preprocessing Started ===")

    try:
        success = preprocess_images(
            args.input_path,
            args.output_path,
            target_size=args.target_size,
            validation_report_path=args.validation_report_path,
        )
        if not success:
            logger.error("Preprocessing failed")
            sys.exit(1)
        # Each instance writes only its share, so a split directory may hold
        # one class on one instance; the whole-dataset class check ran above.
        missing_outputs = [
            path
            for path in (
                os.path.join(args.output_path, "train"),
                os.path.join(args.output_path, "validation"),
                os.path.join(args.output_path, "test"),
                os.path.join(args.output_path, "preprocessing_summary.json"),
            )
            if not os.path.exists(path)
        ]
        if missing_outputs:
            logger.error(f"Missing required outputs: {missing_outputs}")
            sys.exit(1)
        logger.info("Preprocessing completed successfully")
    except Exception as e:
        # Top-level boundary of the step: log the failure and exit non-zero so
        # the pipeline marks the step failed.
        logger.error(f"Preprocessing failed with error: {e}")
        sys.exit(1)
