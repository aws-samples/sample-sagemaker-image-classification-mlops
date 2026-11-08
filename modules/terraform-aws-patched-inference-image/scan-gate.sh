#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Scan gate for the patched inference image, run by the build after the push.
# The image must have a completed Amazon ECR scan with no finding at or above
# SCAN_BLOCK_SEVERITY. Otherwise it is deleted, so neither an apply nor the
# weekly endpoint refresh can pin it, and the build fails.
#
# Environment: TARGET_REPO_NAME, DATE_TAG, SCAN_BLOCK_SEVERITY (CRITICAL,
# HIGH, MEDIUM, LOW or NONE) and SCAN_WAIT_SECONDS (default 1200).

set -euo pipefail

case "${SCAN_BLOCK_SEVERITY}" in
    NONE) echo "Scan gate off (SCAN_BLOCK_SEVERITY=NONE)"; exit 0 ;;
    CRITICAL) LEVELS=1 ;;
    HIGH) LEVELS=2 ;;
    MEDIUM) LEVELS=3 ;;
    LOW) LEVELS=4 ;;
    *) echo "Unknown SCAN_BLOCK_SEVERITY: ${SCAN_BLOCK_SEVERITY}" >&2; exit 1 ;;
esac

IMAGE_ID="imageTag=${DATE_TAG}"
WAIT_SECONDS="${SCAN_WAIT_SECONDS:-1200}"
ERRORS="$(mktemp)"

reject() {
    echo "Scan gate: $1. Deleting ${TARGET_REPO_NAME}:${DATE_TAG}." >&2
    aws ecr batch-delete-image --repository-name "${TARGET_REPO_NAME}" --image-ids "${IMAGE_ID}" >/dev/null \
        || echo "Could not delete ${TARGET_REPO_NAME}:${DATE_TAG}; delete it before the next apply." >&2
    exit 1
}

findings() {
    aws ecr describe-image-scan-findings --repository-name "${TARGET_REPO_NAME}" \
        --image-id "${IMAGE_ID}" --no-paginate --output text --query "$1" 2>"${ERRORS}"
}

# Starts a basic scan where the registry scans this repository manually. It is
# refused when scan on push or enhanced scanning already covers the image.
aws ecr start-image-scan --repository-name "${TARGET_REPO_NAME}" --image-id "${IMAGE_ID}" >/dev/null 2>&1 || true

DEADLINE=$(($(date +%s) + WAIT_SECONDS))
while :; do
    if ! STATE="$(findings '[imageScanStatus.status, imageScanFindings.imageScanCompletedAt]')"; then
        grep -q ScanNotFoundException "${ERRORS}" || reject "$(cat "${ERRORS}")"
        STATE="NOT_STARTED None"
    fi
    read -r STATUS COMPLETED <<<"${STATE}"
    case "${STATUS}" in
        COMPLETE | ACTIVE) [ "${COMPLETED}" = "None" ] || break ;;
        IN_PROGRESS | PENDING | NOT_STARTED | None) ;;
        *) reject "scan status ${STATUS}" ;;
    esac
    [ "$(date +%s)" -lt "${DEADLINE}" ] || reject "no completed scan within ${WAIT_SECONDS} s"
    sleep 20
done

COUNTS_QUERY='[imageScanFindings.findingSeverityCounts.CRITICAL, imageScanFindings.findingSeverityCounts.HIGH, imageScanFindings.findingSeverityCounts.MEDIUM, imageScanFindings.findingSeverityCounts.LOW]'
COUNTS_TEXT="$(findings "${COUNTS_QUERY}")" || reject "$(cat "${ERRORS}")"
read -r -a COUNTS <<<"${COUNTS_TEXT}"
echo "Scan findings: CRITICAL=${COUNTS[0]} HIGH=${COUNTS[1]} MEDIUM=${COUNTS[2]} LOW=${COUNTS[3]}"

BLOCKING=0
for ((i = 0; i < LEVELS; i++)); do
    [ "${COUNTS[i]}" = "None" ] || BLOCKING=$((BLOCKING + COUNTS[i]))
done
[ "${BLOCKING}" -eq 0 ] || reject "${BLOCKING} finding(s) at ${SCAN_BLOCK_SEVERITY} or above"
echo "Scan gate passed for ${TARGET_REPO_NAME}:${DATE_TAG}"
