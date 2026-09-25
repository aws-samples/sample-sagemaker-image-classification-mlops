# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

from datetime import UTC, datetime, timedelta

import boto3
from mlops_common.s3io import delete_prefix, hour_prefixes, iter_capture_keys
from moto import mock_aws

BUCKET = "monitoring-test"


def test_hour_prefixes_cover_window():
    since = datetime(2026, 9, 24, 22, 30, tzinfo=UTC)
    until = datetime(2026, 9, 25, 1, 5, tzinfo=UTC)
    assert hour_prefixes("dc/ep/v1/", since, until) == [
        "dc/ep/v1/2026/09/24/22/",
        "dc/ep/v1/2026/09/24/23/",
        "dc/ep/v1/2026/09/25/00/",
        "dc/ep/v1/2026/09/25/01/",
    ]


@mock_aws
def test_capture_listing_reads_only_the_window_and_endpoint():
    s3 = boto3.client("s3")
    s3.create_bucket(Bucket=BUCKET)
    now = datetime.now(UTC)
    recent = now - timedelta(hours=1)
    old = now - timedelta(days=30)
    keys = {
        f"data-capture/ep/AllTraffic/{recent:%Y/%m/%d/%H}/a.jsonl": True,
        f"data-capture/ep/AllTraffic/{recent:%Y/%m/%d/%H}/notes.txt": False,
        f"data-capture/ep/AllTraffic/{old:%Y/%m/%d/%H}/old.jsonl": False,
        f"data-capture/other-ep/AllTraffic/{recent:%Y/%m/%d/%H}/b.jsonl": False,
    }
    for key in keys:
        s3.put_object(Bucket=BUCKET, Key=key, Body=b"{}")
    since = now - timedelta(hours=24)
    found = list(iter_capture_keys(s3, BUCKET, "data-capture", "ep", since))
    assert found == [k for k, want in keys.items() if want]


@mock_aws
def test_delete_prefix_paginates_and_stays_in_prefix():
    s3 = boto3.client("s3")
    s3.create_bucket(Bucket=BUCKET)
    for i in range(1005):
        s3.put_object(Bucket=BUCKET, Key=f"train/{i:05d}.png", Body=b"x")
    s3.put_object(Bucket=BUCKET, Key="keep/me.txt", Body=b"x")
    assert delete_prefix(s3, BUCKET, "train/") == 1005
    remaining = [o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET).get("Contents", [])]
    assert remaining == ["keep/me.txt"]
