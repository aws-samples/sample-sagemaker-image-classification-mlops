# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""BreakHis filename parsing and the patient-grouped train/validation/test split.

BreakHis names every image after the slide it came from, for example
``SOB_B_A-14-22549AB-40-001.png``: procedure SOB, class B (benign) or M
(malignant), tumour type, year, slide id, magnification, sequence number.
Year plus slide id identifies the patient. Images of one patient are near
duplicates, so a per-image split leaks patients across train and test and
inflates recall and AUC. The split below keeps each patient in one split.
"""

from __future__ import annotations

import logging
import os
import re
from collections import Counter, defaultdict
from collections.abc import Sequence

from .constants import DEFAULT_SEED

logger = logging.getLogger(__name__)

_PATTERN = re.compile(
    r"SOB_(?P<tumor_class>[BM])_(?P<tumor_type>[A-Za-z]+)-(?P<year>\d+)-"
    r"(?P<slide>[0-9A-Za-z]+)-(?P<magnification>\d+)-(?P<seq>\d+)"
)

Item = tuple[str, int]


def parse_filename(name: str) -> dict[str, str] | None:
    """Fields of a BreakHis filename (any prefix such as ``breakhis_`` is fine)."""
    match = _PATTERN.search(os.path.basename(str(name)))
    return match.groupdict() if match else None


def patient_id(name: str) -> str | None:
    fields = parse_filename(name)
    return f"{fields['year']}-{fields['slide']}" if fields else None


def magnification(name: str) -> str | None:
    fields = parse_filename(name)
    return f"{fields['magnification']}X" if fields else None


def group_key(name: str) -> str:
    """Patient id, or the image itself when the filename carries no patient."""
    pid = patient_id(name)
    return pid if pid else f"image:{os.path.basename(str(name))}"


def _split_groups(
    items: list[Item], holdout_fraction: float, seed: int
) -> tuple[list[Item], list[Item]]:
    from sklearn.model_selection import GroupShuffleSplit

    groups = [group_key(f) for f, _ in items]
    if len(set(groups)) < 2 or holdout_fraction <= 0:
        return list(items), []
    splitter = GroupShuffleSplit(n_splits=1, test_size=holdout_fraction, random_state=seed)
    keep_idx, hold_idx = next(splitter.split(items, groups=groups))
    return [items[i] for i in sorted(keep_idx)], [items[i] for i in sorted(hold_idx)]


def patient_grouped_split(
    items: Sequence[Item],
    val_fraction: float = 0.15,
    test_fraction: float = 0.15,
    seed: int = DEFAULT_SEED,
) -> tuple[list[Item], list[Item], list[Item]]:
    """Split (filename, label) items into train/validation/test by patient.

    Groups are split separately per class (stratum = the group's majority
    label) with GroupShuffleSplit, so class balance is kept and no group
    appears in two splits. Fractions are of groups, not images.
    """
    items = sorted((str(f), int(label)) for f, label in items)
    by_group: dict[str, list[Item]] = defaultdict(list)
    for item in items:
        by_group[group_key(item[0])].append(item)

    unparsed = sum(1 for g in by_group if g.startswith("image:"))
    if unparsed:
        logger.warning(
            "%d image(s) have no BreakHis patient id; each is its own group "
            "(no patient-level leakage protection for those)",
            unparsed,
        )

    strata: dict[int, list[Item]] = defaultdict(list)
    for members in by_group.values():
        label = Counter(label for _, label in members).most_common(1)[0][0]
        strata[label].extend(members)

    train: list[Item] = []
    val: list[Item] = []
    test: list[Item] = []
    holdout = val_fraction + test_fraction
    for label in sorted(strata):
        stratum = sorted(strata[label])
        keep, rest = _split_groups(stratum, holdout, seed)
        val_part, test_part = _split_groups(rest, test_fraction / holdout if holdout else 0, seed)
        train.extend(keep)
        val.extend(val_part)
        test.extend(test_part)
    return sorted(train), sorted(val), sorted(test)


def groups_overlap(*splits: Sequence[Item]) -> list[str]:
    """Group keys that appear in more than one split (empty when the split is clean)."""
    seen: dict[str, int] = {}
    overlap = set()
    for index, split in enumerate(splits):
        for name, _ in split:
            key = group_key(name)
            if key in seen and seen[key] != index:
                overlap.add(key)
            seen.setdefault(key, index)
    return sorted(overlap)
