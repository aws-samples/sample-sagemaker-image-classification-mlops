# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Subgroup fairness metrics with Fairlearn, shared by the in-pipeline gate
(scripts/bias) and the scheduled live monitor (scripts/fairness).

A comparison needs at least two subgroups. With fewer, the result is
"not_evaluable": nothing was measured, so the gate fails unless the caller
explicitly allows it. Reporting a disparity of 0 for one group would pass the
gate by construction.
"""

from __future__ import annotations

from collections.abc import Sequence

STATUS_EVALUATED = "evaluated"
STATUS_NOT_EVALUABLE = "not_evaluable"


def _per_group(y_true: list[int], y_pred: list[int], groups: list[str]) -> dict[str, dict]:
    per_group: dict[str, dict] = {}
    for grp in sorted(set(groups)):
        idx = [i for i, g in enumerate(groups) if g == grp]
        n = len(idx)
        pos = sum(1 for i in idx if y_true[i] == 1)
        neg = n - pos
        flagged = sum(1 for i in idx if y_pred[i] == 1)
        tp = sum(1 for i in idx if y_true[i] == 1 and y_pred[i] == 1)
        fp = sum(1 for i in idx if y_true[i] == 0 and y_pred[i] == 1)
        per_group[grp] = {
            "n": n,
            "n_positive": pos,
            "selection_rate": round(flagged / n, 4) if n else None,
            # Recall is the clinically costly rate: a missed malignant case.
            "true_positive_rate": round(tp / pos, 4) if pos else None,
            "false_positive_rate": round(fp / neg, 4) if neg else None,
            # Equalized odds needs both classes in a group.
            "rates_measurable": bool(pos and neg),
        }
    return per_group


def compute_group_fairness(
    y_true: Sequence[int],
    y_pred: Sequence[int],
    groups: Sequence,
    threshold: float,
    allow_not_evaluable: bool = False,
) -> dict:
    """Demographic parity and equalized odds across subgroups.

    ``max_disparity`` is the larger of the two measured differences and is
    what the gate compares against ``threshold``. Groups without both classes
    are left out of the equalized-odds term (Fairlearn would report their
    recall as 0 and fire a false maximal disparity) but still count for
    demographic parity; per_group shows which groups were measurable.
    """
    from fairlearn.metrics import demographic_parity_difference, equalized_odds_difference

    y_true = [int(v) for v in y_true]
    y_pred = [int(v) for v in y_pred]
    groups = [str(g) for g in groups]
    if not (len(y_true) == len(y_pred) == len(groups)):
        raise ValueError("y_true, y_pred and groups must have the same length")

    per_group = _per_group(y_true, y_pred, groups)
    result: dict = {
        "per_group": per_group,
        "n_samples": len(y_true),
        "n_groups": len(per_group),
        "threshold": threshold,
    }

    if len(per_group) < 2:
        result.update(
            {
                "status": STATUS_NOT_EVALUABLE,
                "reason": f"{len(per_group)} subgroup(s); a fairness comparison needs at least 2",
                "demographic_parity_difference": None,
                "equalized_odds_difference": None,
                "equalized_odds_groups": [],
                "max_disparity": None,
                "allow_not_evaluable": allow_not_evaluable,
                "passed": bool(allow_not_evaluable),
            }
        )
        return result

    dp = float(demographic_parity_difference(y_true, y_pred, sensitive_features=groups))

    keep = [i for i, g in enumerate(groups) if per_group[g]["rates_measurable"]]
    eo_groups = sorted({groups[i] for i in keep})
    eo: float | None = None
    if len(eo_groups) >= 2:
        eo = float(
            equalized_odds_difference(
                [y_true[i] for i in keep],
                [y_pred[i] for i in keep],
                sensitive_features=[groups[i] for i in keep],
            )
        )

    max_disparity = max(dp, eo) if eo is not None else dp
    result.update(
        {
            "status": STATUS_EVALUATED,
            "demographic_parity_difference": round(dp, 4),
            "equalized_odds_difference": round(eo, 4) if eo is not None else None,
            "equalized_odds_groups": eo_groups,
            "max_disparity": round(max_disparity, 4),
            "passed": bool(max_disparity <= threshold),
        }
    )
    return result
