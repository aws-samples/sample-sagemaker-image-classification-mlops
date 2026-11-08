# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Dataset layout: class folders, group ids, subgroups, the optional manifest and the group split.

A dataset is ``<root>/<class>/<image>`` with exactly two class folders. Label 1
is the positive class (``POSITIVE_CLASS``, default the second folder in
alphabetical order), label 0 the other one.

File names carry the group id and, optionally, a subgroup:
``<group>__<name>`` or ``<group>__<subgroup>__<name>``, for example
``g01__site-a__img_0001.jpg`` (group ``g01``, subgroup ``site-a``). Images of one
group (same source, subject, session or device) are usually near duplicates,
so a per-image split leaks them across train and test and inflates the
metrics; the split below keeps every group in one split. An image whose name
carries no group is its own group. The subgroup (a capture setting such as a
camera, site or zoom level) is what the fairness gate compares.

An optional ``manifest.csv`` at the root, with the columns ``file,label,group``
plus any attribute columns, overrides the file names: ``file`` is
``<class>/<image>``, ``label`` the class folder name, ``group`` the group id,
and an attribute column (``subgroup`` by default) the fairness subgroup.
"""

from __future__ import annotations

import csv
import json
import logging
import os
from collections import Counter, defaultdict
from collections.abc import Iterable, Mapping, Sequence

from .constants import DEFAULT_SEED, IMAGE_EXTENSIONS

logger = logging.getLogger(__name__)

MANIFEST_FILE = "manifest.csv"
CLASSES_FILE = "classes.json"
NAME_SEPARATOR = "__"
MANIFEST_COLUMNS = ("file", "label", "group")
SUBGROUP_ATTRIBUTE = "subgroup"

Item = tuple[str, int]


def discover_classes(root: str, positive_class: str | None = None) -> tuple[str, str]:
    """(negative, positive) class folder names under root.

    Raises ValueError unless there are exactly two class folders and the
    positive class is one of them.
    """
    names = sorted(
        name
        for name in os.listdir(root)
        if os.path.isdir(os.path.join(root, name)) and not name.startswith(".")
    )
    if len(names) != 2:
        raise ValueError(f"expected exactly 2 class folders under {root}, found {names}")
    positive = positive_class or os.environ.get("POSITIVE_CLASS") or names[-1]
    if positive not in names:
        raise ValueError(f"positive class {positive!r} is not one of the class folders {names}")
    negative = names[0] if positive == names[1] else names[1]
    return negative, positive


def write_classes(directory: str, class_names: Sequence[str]) -> None:
    """Write classes.json: the class names in label order and the positive class."""
    with open(os.path.join(directory, CLASSES_FILE), "w") as f:
        json.dump({"class_names": list(class_names), "positive_class": class_names[1]}, f)


def load_classes(directory: str) -> tuple[str, str]:
    """(negative, positive) from directory/classes.json, else from its class folders."""
    path = os.path.join(directory, CLASSES_FILE)
    if os.path.exists(path):
        with open(path) as f:
            names = json.load(f)["class_names"]
        if len(names) != 2:
            raise ValueError(f"{path} must list exactly 2 class names")
        return names[0], names[1]
    return discover_classes(directory)


def list_images(folder: str) -> list[str]:
    """Image file names in folder, sorted; none when the folder does not exist."""
    if not os.path.isdir(folder):
        return []
    return sorted(f for f in os.listdir(folder) if f.lower().endswith(IMAGE_EXTENSIONS))


def parse_filename(name: str) -> dict[str, str | None]:
    """``{"group", "subgroup"}`` from a ``<group>__[<subgroup>__]<name>`` file name.

    Both are None when the name carries no ``__`` separated prefix.
    """
    parts = os.path.basename(str(name)).split(NAME_SEPARATOR)
    if len(parts) < 2 or not all(parts):
        return {"group": None, "subgroup": None}
    return {"group": parts[0], "subgroup": parts[1] if len(parts) > 2 else None}


def read_manifest(root: str) -> dict[str, dict]:
    """``{"<class>/<image>": {"label", "group", "attributes"}}`` from root/manifest.csv.

    Empty when there is no manifest. Raises ValueError when the header lacks
    the required columns.
    """
    path = os.path.join(root, MANIFEST_FILE)
    if not os.path.exists(path):
        return {}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames or []
        missing = [c for c in MANIFEST_COLUMNS if c not in fields]
        if missing:
            raise ValueError(f"{path} is missing column(s) {missing}")
        attribute_names = [c for c in fields if c not in MANIFEST_COLUMNS]
        rows = {}
        for row in reader:
            file = (row["file"] or "").strip().strip("/")
            if not file:
                continue
            rows[file] = {
                "label": (row["label"] or "").strip(),
                "group": (row["group"] or "").strip() or None,
                "attributes": {
                    name: value for name in attribute_names if (value := (row[name] or "").strip())
                },
            }
    return rows


def describe_image(file: str, manifest: Mapping[str, Mapping] | None = None) -> dict:
    """Group id and attributes of ``<class>/<image>``: the manifest first, then the file name."""
    row = (manifest or {}).get(file) or {}
    parsed = parse_filename(file)
    attributes = dict(row.get("attributes") or {})
    if parsed["subgroup"] and SUBGROUP_ATTRIBUTE not in attributes:
        attributes[SUBGROUP_ATTRIBUTE] = parsed["subgroup"]
    return {"group": row.get("group") or parsed["group"], "attributes": attributes}


def write_manifest(directory: str, rows: Iterable[Mapping]) -> None:
    """Write directory/manifest.csv from rows with file, label, group and attributes."""
    rows = list(rows)
    attribute_names = sorted({name for row in rows for name in (row.get("attributes") or {})})
    with open(os.path.join(directory, MANIFEST_FILE), "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([*MANIFEST_COLUMNS, *attribute_names])
        for row in rows:
            attributes = row.get("attributes") or {}
            writer.writerow(
                [row["file"], row["label"], row.get("group") or ""]
                + [attributes.get(name, "") for name in attribute_names]
            )


def group_key(name: str, groups: Mapping[str, str | None] | None = None) -> str:
    """Group id of an image: the manifest group, the file name group, or the image itself."""
    group = (groups or {}).get(name) or parse_filename(name)["group"]
    return group if group else f"image:{name}"


def _split_groups(
    items: list[Item], holdout_fraction: float, seed: int, groups: Mapping | None
) -> tuple[list[Item], list[Item]]:
    from sklearn.model_selection import GroupShuffleSplit

    keys = [group_key(f, groups) for f, _ in items]
    if len(set(keys)) < 2 or holdout_fraction <= 0:
        return list(items), []
    splitter = GroupShuffleSplit(n_splits=1, test_size=holdout_fraction, random_state=seed)
    keep_idx, hold_idx = next(splitter.split(items, groups=keys))
    return [items[i] for i in sorted(keep_idx)], [items[i] for i in sorted(hold_idx)]


def grouped_split(
    items: Sequence[Item],
    val_fraction: float = 0.15,
    test_fraction: float = 0.15,
    seed: int = DEFAULT_SEED,
    groups: Mapping[str, str | None] | None = None,
) -> tuple[list[Item], list[Item], list[Item]]:
    """Split (file, label) items into train/validation/test so no group spans two splits.

    Groups are split per class (stratum = the group's majority label) with
    GroupShuffleSplit, so class balance is kept. Fractions are of groups, not
    images. ``groups`` maps a file to its group id (from describe_image).
    """
    items = sorted((str(f), int(label)) for f, label in items)
    by_group: dict[str, list[Item]] = defaultdict(list)
    for item in items:
        by_group[group_key(item[0], groups)].append(item)

    ungrouped = sum(1 for g in by_group if g.startswith("image:"))
    if ungrouped:
        logger.warning(
            "%d image(s) have no group id; each is its own group (no leakage protection for those)",
            ungrouped,
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
        keep, rest = _split_groups(stratum, holdout, seed, groups)
        val_part, test_part = _split_groups(
            rest, test_fraction / holdout if holdout else 0, seed, groups
        )
        train.extend(keep)
        val.extend(val_part)
        test.extend(test_part)
    return sorted(train), sorted(val), sorted(test)


def groups_overlap(
    *splits: Sequence[Item], groups: Mapping[str, str | None] | None = None
) -> list[str]:
    """Group ids that appear in more than one split (empty when the split is clean)."""
    seen: dict[str, int] = {}
    overlap = set()
    for index, split in enumerate(splits):
        for name, _ in split:
            key = group_key(name, groups)
            if key in seen and seen[key] != index:
                overlap.add(key)
            seen.setdefault(key, index)
    return sorted(overlap)


def subgroups(
    files: Sequence[str], manifest: Mapping[str, Mapping] | None, attribute: str
) -> list[str] | None:
    """Value of one attribute per ``<class>/<image>``, or None when no image carries it.

    The value comes from the manifest, else (for ``subgroup``) the file name;
    an image without one is ``unknown``.
    """
    values = [describe_image(f, manifest)["attributes"].get(attribute) for f in files]
    if not any(values):
        return None
    return [value or "unknown" for value in values]
