# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Bounded, paginated S3 listing and deletion."""

from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime, timedelta, timezone


def iter_keys(
    s3,
    bucket: str,
    prefix: str,
    since: datetime | None = None,
    suffix: str | None = None,
) -> Iterator[str]:
    """Keys under prefix (paginated), optionally modified at or after since."""
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if since is not None and obj["LastModified"] < since:
                continue
            if suffix and not obj["Key"].endswith(suffix):
                continue
            yield obj["Key"]


def hour_prefixes(base: str, since: datetime, until: datetime) -> list[str]:
    """``base/yyyy/mm/dd/hh/`` for every UTC hour from since to until inclusive."""
    since = since.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)
    until = until.astimezone(timezone.utc)
    out = []
    hour = since
    while hour <= until:
        out.append(f"{base.rstrip('/')}/{hour:%Y/%m/%d/%H}/")
        hour += timedelta(hours=1)
    return out


def _child_prefixes(s3, bucket: str, prefix: str) -> list[str]:
    paginator = s3.get_paginator("list_objects_v2")
    out: list[str] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix, Delimiter="/"):
        out.extend(p["Prefix"] for p in page.get("CommonPrefixes", []))
    return out


def iter_capture_keys(
    s3,
    bucket: str,
    capture_prefix: str,
    endpoint_name: str,
    since: datetime,
    until: datetime | None = None,
) -> Iterator[str]:
    """Capture files for one endpoint written in [since, until].

    Data capture writes ``<prefix>/<endpoint>/<variant>/yyyy/mm/dd/hh/*.jsonl``,
    so listing only the hour prefixes in the window keeps each run bounded no
    matter how much history the bucket holds.
    """
    until = until or datetime.now(timezone.utc)
    endpoint_prefix = f"{capture_prefix.strip('/')}/{endpoint_name}/"
    for variant_prefix in _child_prefixes(s3, bucket, endpoint_prefix):
        for prefix in hour_prefixes(variant_prefix, since, until):
            yield from iter_keys(s3, bucket, prefix, since=since, suffix=".jsonl")


def delete_prefix(s3, bucket: str, prefix: str) -> int:
    """Delete every object under prefix in one named bucket; returns the count."""
    if not prefix:
        raise ValueError("refusing to delete an empty prefix")
    deleted = 0
    batch: list[dict] = []
    for key in iter_keys(s3, bucket, prefix):
        batch.append({"Key": key})
        if len(batch) == 1000:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": batch, "Quiet": True})
            deleted += len(batch)
            batch = []
    if batch:
        s3.delete_objects(Bucket=bucket, Delete={"Objects": batch, "Quiet": True})
        deleted += len(batch)
    return deleted
