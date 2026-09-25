#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

OUTPUT_DIR=${1:-"data/batch4_breakhis"}
WORK_DIR=$(mktemp -d)
TARBALL="BreaKHis_v1.tar.gz"
DOWNLOAD_URL="http://www.inf.ufpr.br/vri/databases/BreaKHis_v1.tar.gz"

echo -e "${GREEN}BreakHis Dataset Downloader${NC}"
echo -e "${BLUE}Output directory: ${OUTPUT_DIR}${NC}"
echo -e "${BLUE}Work directory: ${WORK_DIR}${NC}"

# Dependency check
for cmd in curl tar find; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Missing required tool: $cmd${NC}"
        exit 1
    fi
done

cleanup() {
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# Step 1: Download the tarball
echo -e "${BLUE} Downloading BreakHis (~4GB, may take several minutes)...${NC}"
if [ -f "data/${TARBALL}" ]; then
    echo -e "${YELLOW} Found cached tarball at data/${TARBALL}, reusing${NC}"
    cp "data/${TARBALL}" "${WORK_DIR}/"
else
    curl -L --progress-bar -o "${WORK_DIR}/${TARBALL}" "${DOWNLOAD_URL}"
    # Cache for future runs
    mkdir -p data
    cp "${WORK_DIR}/${TARBALL}" "data/${TARBALL}"
    echo -e "${GREEN}Download cached at data/${TARBALL}${NC}"
fi

# Step 2: Extract
echo -e "${BLUE}Extracting tarball...${NC}"
tar -xzf "${WORK_DIR}/${TARBALL}" -C "${WORK_DIR}"

# Step 3: Organize into project's batch structure
# BreakHis structure: BreaKHis_v1/histology_slides/breast/{benign,malignant}/SOB/{tumor_type}/{patient_id}/{magnification}/*.png
# We take all magnifications (40X, 100X, 200X, 400X) for diversity
echo -e "${BLUE} Organizing into ${OUTPUT_DIR}/{breast_benign,breast_malignant}/...${NC}"

BREAKHIS_ROOT=$(find "${WORK_DIR}" -type d -name "histology_slides" | head -1)
if [ -z "$BREAKHIS_ROOT" ]; then
    echo -e "${RED}Could not locate histology_slides directory in extracted tarball${NC}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}/breast_benign"
mkdir -p "${OUTPUT_DIR}/breast_malignant"

BENIGN_COUNT=0
MALIGNANT_COUNT=0

# Copy benign images (rename to match project convention)
while IFS= read -r -d '' src; do
    BENIGN_COUNT=$((BENIGN_COUNT + 1))
    # Keep original filename encoding (magnification, tumor type, patient) for traceability
    fname=$(basename "$src")
    cp "$src" "${OUTPUT_DIR}/breast_benign/breakhis_${fname}"
done < <(find "${BREAKHIS_ROOT}/breast/benign" -type f -iname "*.png" -print0)

# Copy malignant images
while IFS= read -r -d '' src; do
    MALIGNANT_COUNT=$((MALIGNANT_COUNT + 1))
    fname=$(basename "$src")
    cp "$src" "${OUTPUT_DIR}/breast_malignant/breakhis_${fname}"
done < <(find "${BREAKHIS_ROOT}/breast/malignant" -type f -iname "*.png" -print0)

echo -e "${GREEN}BreakHis dataset ready${NC}"
echo -e "   breast_benign:    ${BENIGN_COUNT} images"
echo -e "   breast_malignant: ${MALIGNANT_COUNT} images"
echo -e "   Total:            $((BENIGN_COUNT + MALIGNANT_COUNT)) images"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "   Add to the training pool (triggers pipeline retraining):"
echo -e "      ./scripts/data_uploader.sh ${OUTPUT_DIR}"
echo -e "   Filenames keep the BreakHis patient id and magnification, which the"
echo -e "   patient-grouped split and the fairness gate read."
