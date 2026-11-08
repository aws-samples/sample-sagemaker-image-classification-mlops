#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Arg parsing ----------------------------------------------------------
DATA_FOLDER="../data"
PREFIX="images"
IMAGE_COUNT="all"
APPEND_MODE=0
SKIP_DVC=0

usage() {
    echo "Usage: $0 [data-folder] [--prefix images] [--append] [--count N] [--no-dvc]"
    echo "  data-folder holds one folder per class (<data-folder>/<class>/<image>) and an"
    echo "  optional manifest.csv; everything goes to s3://<raw-data-bucket>/<prefix>/."
}

# First positional argument (if it doesn't start with --) is the data folder
if [ -n "${1:-}" ] && [[ "$1" != --* ]]; then
    DATA_FOLDER="$1"
    shift
fi

# Remaining args are flags
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="${2%/}"
            shift 2
            ;;
        --append)
            APPEND_MODE=1
            shift
            ;;
        --count)
            IMAGE_COUNT="$2"
            shift 2
            ;;
        --no-dvc)
            SKIP_DVC=1
            shift
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

echo -e "${GREEN}Image classification dataset upload${NC}"
echo -e "${BLUE}Data folder: ${DATA_FOLDER}${NC}"
if [ "$IMAGE_COUNT" = "all" ]; then
    echo -e "${BLUE}Uploading all images${NC}"
else
    echo -e "${BLUE}Uploading ${IMAGE_COUNT} images per class${NC}"
fi
if [ "$APPEND_MODE" -eq 1 ]; then
    echo -e "${YELLOW}Append mode: existing data will be preserved${NC}"
else
    echo -e "${YELLOW}Replace mode: the existing ${PREFIX}/ prefix will be overwritten${NC}"
fi

# --- Get bucket name ------------------------------------------------------
echo -e "${BLUE}Getting bucket name...${NC}"
RAW_DATA_BUCKET=$(cd stack-training && terraform output -raw raw_data_bucket 2>/dev/null)

if [ -z "$RAW_DATA_BUCKET" ]; then
    echo -e "${RED}Error: Could not get bucket name from stack-training${NC}"
    exit 1
fi

echo -e "${GREEN}Target bucket: ${RAW_DATA_BUCKET}${NC}"

# --- Validate data structure ---------------------------------------------
if [ ! -d "$DATA_FOLDER" ]; then
    echo -e "${RED}Error: Data folder '$DATA_FOLDER' does not exist${NC}"
    exit 1
fi

CLASSES=()
while IFS= read -r dir; do
    CLASSES+=("$(basename "$dir")")
done < <(find "$DATA_FOLDER" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)

if [ "${#CLASSES[@]}" -ne 2 ]; then
    echo -e "${RED}Error: expected exactly 2 class folders in '$DATA_FOLDER', found ${#CLASSES[@]}${NC}"
    usage
    exit 1
fi

# --- Stage data into a temp directory -------------------------------------
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT   # always cleanup, even on error

copy_images() {
    local src_dir="$1"
    local dst_dir="$2"
    local limit="$3"

    local find_cmd=(find "$src_dir" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \))

    if [ "$limit" = "all" ]; then
        "${find_cmd[@]}" | while read -r file; do
            cp "$file" "$dst_dir/"
        done
    else
        "${find_cmd[@]}" | sort | head -"$limit" | while read -r file; do
            cp "$file" "$dst_dir/"
        done
    fi
}

echo -e "${BLUE}Staging images...${NC}"
for class in "${CLASSES[@]}"; do
    mkdir -p "$TEMP_DIR/$PREFIX/$class"
    copy_images "$DATA_FOLDER/$class" "$TEMP_DIR/$PREFIX/$class" "$IMAGE_COUNT"
    echo -e "   ${class}: $(find "$TEMP_DIR/$PREFIX/$class" -type f | wc -l | tr -d ' ') images"
done
if [ -f "$DATA_FOLDER/manifest.csv" ]; then
    cp "$DATA_FOLDER/manifest.csv" "$TEMP_DIR/$PREFIX/manifest.csv"
    echo -e "   manifest.csv included"
fi

# --- Upload ---------------------------------------------------------------
BATCH_ID=$(date +%Y%m%d-%H%M%S)

if [ "$APPEND_MODE" -eq 1 ]; then
    echo -e "${BLUE}Appending to existing S3 data (no delete)...${NC}"
    # sync WITHOUT --delete: keeps existing objects, adds/overwrites only the
    # staged ones. Matches README "append to existing dataset" semantics.
    aws s3 sync "$TEMP_DIR/$PREFIX" "s3://$RAW_DATA_BUCKET/$PREFIX"
else
    echo -e "${BLUE}Replacing S3 data (--delete)...${NC}"
    aws s3 sync "$TEMP_DIR/$PREFIX" "s3://$RAW_DATA_BUCKET/$PREFIX" --delete
fi

# --- DVC snapshot (optional) ---------------------------------------------
# When DVC is installed and .dvc/ is initialized, snapshot the dataset so
# the git repo can point to this exact content hash. Skipped silently when
# DVC isn't available - this script still works without it.
#
# This runs AFTER the S3 sync because we want the DVC content hash to
# match what SageMaker will actually train against.

if [ "$SKIP_DVC" -eq 0 ] && command -v dvc >/dev/null 2>&1 && [ -d ".dvc" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [ -d "$REPO_ROOT/data" ]; then
        echo -e "${BLUE}DVC snapshot: tracking data/ at this commit...${NC}"
        (
            cd "$REPO_ROOT"
            dvc add data
            # Push blobs to the DVC remote (S3 dvc-cache prefix). This may
            # be a no-op if the blobs are already there - DVC deduplicates
            # by content hash.
            if dvc push; then
                echo -e "${GREEN}DVC push complete${NC}"
                echo -e "${YELLOW}Commit the pointer to lock this dataset to a git SHA:${NC}"
                echo "     cd $REPO_ROOT"
                echo "     git add data.dvc .gitignore"
                echo "     git commit -m 'data: batch $BATCH_ID'"
                echo -e "${YELLOW}SageMaker will tag the model with this git SHA (see training pipeline).${NC}"
            else
                echo -e "${YELLOW} DVC push failed - check 'dvc remote list' and .dvc/config${NC}"
            fi
        )
    fi
elif [ "$SKIP_DVC" -eq 0 ]; then
    echo -e "${YELLOW} DVC not installed or not initialized - skipping dataset snapshot${NC}"
    echo -e "${YELLOW}   Install DVC for git-linked dataset versioning:${NC}"
    echo -e "${YELLOW}     pip install 'dvc[s3]==3.67.1' && dvc init && dvc remote add -d storage s3://\$RAW_DATA_BUCKET/dvc-cache${NC}"
fi

# Completion marker triggers the EventBridge -> SageMaker pipeline rule.
# Include the git SHA + batch ID so Model Registry entries are traceable
# back to the exact dataset snapshot (via DVC) and code version (via git).
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
MARKER_CONTENT=$(cat <<EOF
batch_id: $BATCH_ID
uploaded_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
git_sha: $GIT_SHA
append_mode: $APPEND_MODE
dvc_tracked: $([ -f "$(git rev-parse --show-toplevel 2>/dev/null)/data.dvc" ] && echo "true" || echo "false")
EOF
)
echo "$MARKER_CONTENT" | aws s3 cp - "s3://$RAW_DATA_BUCKET/$PREFIX/.batch_complete"

echo -e "${GREEN}Upload complete${NC}"

echo -e "${BLUE}Final S3 contents:${NC}"
aws s3 ls "s3://$RAW_DATA_BUCKET/$PREFIX/" --recursive --human-readable --summarize | tail -20

echo -e "${GREEN}Pipeline will start automatically via EventBridge!${NC}"
