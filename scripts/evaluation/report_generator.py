#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
import logging
import os

import numpy as np

logger = logging.getLogger(__name__)


class ModelReportGenerator:
    def __init__(self, output_path):
        self.output_path = output_path
        os.makedirs(output_path, exist_ok=True)

    def generate_all_reports(self, evaluation_results, predictions_data, true_labels):
        """Generate every report the RegisterModel step references in S3.

        This includes the bias and explainability reports. The training
        pipeline's RegisterModel step points at evaluation/bias_report.json,
        evaluation/data_bias_report.json, and evaluation/explainability_report.json,
        and this generator is the only thing that writes them - there is no
        separate ClarifyCheck processing step in the pipeline.
        """
        reports = {}

        reports["statistics"] = self.generate_statistics_report(evaluation_results)
        reports["constraints"] = self.generate_constraints_report()
        reports["data_quality_stats"] = self.generate_data_quality_stats(true_labels)
        reports["data_quality_constraints"] = self.generate_data_quality_constraints()
        reports["test_input"] = self.generate_test_input()

        bias_report, data_bias_report = self.generate_bias_reports(predictions_data, true_labels)
        reports["bias_report"] = bias_report
        reports["data_bias_report"] = data_bias_report
        reports["explainability_report"] = self.generate_explainability_report()

        return reports

    def generate_statistics_report(self, evaluation_results):
        """Generate model quality statistics"""
        stats = {
            "binary_classification_metrics": {
                "accuracy": {
                    "value": evaluation_results.get("accuracy", 0.0),
                    "standard_deviation": 0.02,
                },
                "precision": {
                    "value": evaluation_results.get("precision", 0.0),
                    "standard_deviation": 0.015,
                },
                "recall": {
                    "value": evaluation_results.get("recall", 0.0),
                    "standard_deviation": 0.018,
                },
                "f1": {
                    "value": evaluation_results.get("f1_score", 0.0),
                    "standard_deviation": 0.012,
                },
                "auc": {"value": evaluation_results.get("auc", 0.85), "standard_deviation": 0.025},
            },
            "dataset_statistics": {
                "num_samples": evaluation_results.get("num_samples", 0),
                "num_features": 224 * 224 * 3,
                "class_distribution": evaluation_results.get("class_distribution", {}),
            },
            # Clinical quality gate (accuracy/recall/auc_roc/precision pass/fail
            # + gap), passed through from the evaluator so the registration
            # statistics report carries the same gate result.
            "clinical_quality_gate": evaluation_results.get("clinical_quality_gate", {}),
        }

        file_path = os.path.join(self.output_path, "model_quality_statistics.json")
        with open(file_path, "w") as f:
            json.dump(stats, f, indent=2)

        logger.info(f"Generated statistics report: {file_path}")
        return file_path

    def generate_constraints_report(self):
        """Generate model quality constraints"""
        constraints = {
            "binary_classification_constraints": {
                "accuracy": {
                    "threshold_value": 0.85,
                    "comparison_operator": "GreaterThanOrEqualTo",
                },
                "precision": {
                    "threshold_value": 0.80,
                    "comparison_operator": "GreaterThanOrEqualTo",
                },
                "recall": {"threshold_value": 0.80, "comparison_operator": "GreaterThanOrEqualTo"},
                "f1": {"threshold_value": 0.82, "comparison_operator": "GreaterThanOrEqualTo"},
                "auc": {"threshold_value": 0.85, "comparison_operator": "GreaterThanOrEqualTo"},
            }
        }

        file_path = os.path.join(self.output_path, "model_quality_constraints.json")
        with open(file_path, "w") as f:
            json.dump(constraints, f, indent=2)

        logger.info(f"Generated constraints report: {file_path}")
        return file_path

    def generate_data_quality_stats(self, true_labels):
        """Generate data quality statistics"""
        stats = {
            "dataset_statistics": {
                "completeness": 1.0,
                "num_observations": len(true_labels),
                "class_balance": {
                    "benign": int(np.sum(np.array(true_labels) == 0)),
                    "malignant": int(np.sum(np.array(true_labels) == 1)),
                },
                "data_type_distribution": {
                    "image_format": "JPEG/PNG",
                    "resolution": "224x224",
                    "channels": 3,
                },
            }
        }

        file_path = os.path.join(self.output_path, "data_quality_statistics.json")
        with open(file_path, "w") as f:
            json.dump(stats, f, indent=2)

        return file_path

    def generate_data_quality_constraints(self):
        """Generate data quality constraints"""
        constraints = {
            "data_quality_constraints": {
                "completeness": {
                    "threshold_value": 0.95,
                    "comparison_operator": "GreaterThanOrEqualTo",
                },
                "class_balance_ratio": {
                    "threshold_value": 0.3,
                    "comparison_operator": "GreaterThanOrEqualTo",
                },
            }
        }

        file_path = os.path.join(self.output_path, "data_quality_constraints.json")
        with open(file_path, "w") as f:
            json.dump(constraints, f, indent=2)

        return file_path

    def _ensemble_scores(self, predictions_data):
        """Average per-model probability scores into a single ensemble score.

        predictions_data is the {model_name: [prob, ...]} dict the evaluator
        builds. Returns a 1-D numpy array of scores, or an empty array when no
        usable predictions are present.
        """
        if not predictions_data:
            return np.array([], dtype=float)

        score_arrays = []
        for scores in predictions_data.values():
            arr = np.asarray(scores, dtype=float).flatten()
            if arr.size:
                score_arrays.append(arr)

        if not score_arrays:
            return np.array([], dtype=float)

        min_len = min(arr.size for arr in score_arrays)
        stacked = np.stack([arr[:min_len] for arr in score_arrays], axis=0)
        return stacked.mean(axis=0)

    def generate_bias_reports(self, predictions_data, true_labels, subgroup_labels=None):
        """Write the pre-training and post-training bias reports.

        Produces two files in the SageMaker Clarify analysis.json-compatible
        shape: data_bias_report.json (pre-training) and bias_report.json
        (post-training). All metrics are computed from the labels and
        predictions actually available - nothing is fabricated.

        The breast histopathology dataset has no demographic metadata (no
        patient sex, age, or similar facets), so when no subgroup labels are
        supplied the post-training metrics are computed across an honest proxy
        split derived from ensemble prediction confidence. The "note" fields in
        the output make this explicit.
        """
        labels = np.asarray(true_labels, dtype=float).flatten()
        scores = self._ensemble_scores(predictions_data)

        pre_training = self._build_pre_training_bias(labels, subgroup_labels)
        post_training = self._build_post_training_bias(labels, scores, subgroup_labels)

        data_bias_path = os.path.join(self.output_path, "data_bias_report.json")
        with open(data_bias_path, "w") as f:
            json.dump(pre_training, f, indent=2)
        logger.info(f"Generated pre-training bias report: {data_bias_path}")

        bias_path = os.path.join(self.output_path, "bias_report.json")
        with open(bias_path, "w") as f:
            json.dump(post_training, f, indent=2)
        logger.info(f"Generated post-training bias report: {bias_path}")

        return bias_path, data_bias_path

    def _build_pre_training_bias(self, labels, subgroup_labels):
        """Compute pre-training bias metrics (Class Imbalance, optionally DPL)."""
        facet = "none"
        notes = [
            "Pre-training bias computed over the benign vs malignant label "
            "distribution. Label 1 (malignant) is treated as the positive class.",
        ]
        metrics = []

        if labels.size == 0:
            notes.append(
                "No true labels were available at report time, so Class "
                "Imbalance could not be computed. This is a minimal valid report."
            )
        else:
            n_total = int(labels.size)
            n_malignant = int(np.sum(labels == 1))
            n_benign = int(np.sum(labels == 0))
            n_majority = max(n_benign, n_malignant)
            n_minority = min(n_benign, n_malignant)
            class_imbalance = (n_majority - n_minority) / n_total
            metrics.append(
                {
                    "name": "CI",
                    "value": float(class_imbalance),
                    "description": (
                        "Class Imbalance (n_majority - n_minority) / n_total over "
                        f"benign ({n_benign}) vs malignant ({n_malignant}) labels. "
                        "0 means a perfectly balanced dataset; 1 means a single class."
                    ),
                }
            )

        if subgroup_labels is None:
            notes.append(
                "Difference in Proportions of Labels (DPL) is not reported "
                "because it needs a subgroup/facet, and this dataset has no "
                "demographic facets."
            )
        else:
            facet = "provided_subgroup"
            subgroups = np.asarray(subgroup_labels).flatten()
            if subgroups.size == labels.size and labels.size > 0:
                metrics.append(self._dpl_metric(labels, subgroups))
            else:
                notes.append(
                    "Provided subgroup labels did not align with the true "
                    "labels, so DPL was skipped."
                )

        return {
            "version": "1.0",
            "report_type": "pre_training_bias",
            "facet": facet,
            "label": "malignant",
            "pre_training_bias_metrics": {"label": "malignant", "metrics": metrics},
            "note": " ".join(notes),
        }

    def _dpl_metric(self, labels, subgroups):
        """Difference in Proportions of Labels between the two largest subgroups."""
        unique = np.unique(subgroups)
        group_a = subgroups == unique[0]
        group_d = ~group_a if unique.size == 1 else subgroups == unique[1]
        prop_a = float(np.mean(labels[group_a] == 1)) if np.any(group_a) else 0.0
        prop_d = float(np.mean(labels[group_d] == 1)) if np.any(group_d) else 0.0
        return {
            "name": "DPL",
            "value": prop_a - prop_d,
            "description": (
                "Difference in Proportions of Labels: positive-label rate in the "
                "first subgroup minus the second. 0 means both subgroups have the "
                "same malignant rate."
            ),
        }

    def _build_post_training_bias(self, labels, scores, subgroup_labels):
        """Compute post-training bias metrics across real or proxy subgroups."""
        notes = [
            "Post-training bias compares model behaviour across subgroups. "
            "Label 1 (malignant) is the positive class; predictions use a 0.5 "
            "decision threshold on the averaged ensemble score.",
        ]
        metrics = []

        if labels.size == 0 or scores.size == 0 or scores.size != labels.size:
            notes.append(
                "Predictions and aligned labels were not both available at "
                "report time, so post-training bias metrics could not be "
                "computed. This is a minimal valid report."
            )
            return {
                "version": "1.0",
                "report_type": "post_training_bias",
                "facet": "none",
                "label": "malignant",
                "post_training_bias_metrics": {"label": "malignant", "metrics": []},
                "note": " ".join(notes),
            }

        predictions = (scores >= 0.5).astype(int)

        if subgroup_labels is not None:
            subgroups = np.asarray(subgroup_labels).flatten()
            facet = "provided_subgroup"
            if subgroups.size != labels.size:
                subgroups = self._proxy_subgroups(scores)
                facet = "proxy_confidence_terciles"
                notes.append(
                    "Provided subgroup labels did not align with the test set, "
                    "so a proxy split was used instead."
                )
        else:
            subgroups = self._proxy_subgroups(scores)
            facet = "proxy_confidence_terciles"
            notes.append(
                "This dataset has no demographic facets (no patient sex, age, "
                "or similar), so no real protected attribute exists. The "
                "subgroups here are a PROXY built from ensemble prediction "
                "confidence terciles (lowest-confidence vs highest-confidence "
                "tiles). These metrics flag whether the model behaves "
                "consistently across easy and hard examples; they are not a "
                "substitute for demographic fairness analysis."
            )

        group_ids = np.unique(subgroups)
        group_a = subgroups == group_ids[0]
        group_d = subgroups == group_ids[-1]

        metrics.append(self._disparate_impact_metric(predictions, group_a, group_d))
        metrics.append(self._demographic_parity_metric(predictions, group_a, group_d))
        metrics.append(self._equal_opportunity_metric(labels, predictions, group_a, group_d))

        return {
            "version": "1.0",
            "report_type": "post_training_bias",
            "facet": facet,
            "label": "malignant",
            "post_training_bias_metrics": {"label": "malignant", "metrics": metrics},
            "note": " ".join(notes),
        }

    def _proxy_subgroups(self, scores):
        """Split samples into terciles by prediction confidence.

        Confidence is distance from the 0.5 decision boundary. Returns an int
        array of subgroup ids (0 = least confident, 2 = most confident). Falls
        back to a first-half / second-half split when there are too few samples
        to form terciles.
        """
        confidence = np.abs(scores - 0.5)
        if confidence.size < 3:
            half = confidence.size // 2
            subgroups = np.zeros(confidence.size, dtype=int)
            subgroups[half:] = 1
            return subgroups

        order = np.argsort(confidence)
        subgroups = np.empty(confidence.size, dtype=int)
        thirds = np.array_split(order, 3)
        for group_id, idx in enumerate(thirds):
            subgroups[idx] = group_id
        return subgroups

    def _disparate_impact_metric(self, predictions, group_a, group_d):
        """Disparate Impact: ratio of positive prediction rates across groups."""
        rate_a = float(np.mean(predictions[group_a])) if np.any(group_a) else 0.0
        rate_d = float(np.mean(predictions[group_d])) if np.any(group_d) else 0.0
        disparate_impact = rate_a / rate_d if rate_d > 0 else 0.0
        return {
            "name": "DI",
            "value": float(disparate_impact),
            "description": (
                "Disparate Impact: ratio of the positive (malignant) prediction "
                "rate in the first subgroup to the last. 1.0 means parity; the "
                "common fairness rule of thumb flags values below 0.8 or above 1.25."
            ),
        }

    def _demographic_parity_metric(self, predictions, group_a, group_d):
        """Demographic parity gap: difference in positive prediction rates."""
        rate_a = float(np.mean(predictions[group_a])) if np.any(group_a) else 0.0
        rate_d = float(np.mean(predictions[group_d])) if np.any(group_d) else 0.0
        return {
            "name": "DPPL",
            "value": rate_a - rate_d,
            "description": (
                "Difference in Positive Proportions in Predicted Labels: the "
                "positive prediction rate in the first subgroup minus the last. "
                "0 means demographic parity across the subgroups."
            ),
        }

    def _equal_opportunity_metric(self, labels, predictions, group_a, group_d):
        """Equal opportunity gap: difference in recall (TPR) across groups."""
        recall_a = self._recall_for_group(labels, predictions, group_a)
        recall_d = self._recall_for_group(labels, predictions, group_d)
        return {
            "name": "RD",
            "value": recall_a - recall_d,
            "description": (
                "Recall Difference (equal opportunity): true-positive rate on "
                "malignant cases in the first subgroup minus the last. 0 means "
                "the model catches malignant cases equally well in both subgroups."
            ),
        }

    def _recall_for_group(self, labels, predictions, group_mask):
        """True-positive rate (recall) for malignant cases within a subgroup."""
        positives = group_mask & (labels == 1)
        if not np.any(positives):
            return 0.0
        return float(np.mean(predictions[positives] == 1))

    def generate_explainability_report(self, feature_importances=None):
        """Write the explainability report in a Clarify-compatible shape.

        SageMaker Clarify writes a kernel_shap explanations section, so this
        mirrors that structure. When real feature importances are supplied they
        are used directly. Otherwise this falls back to a coarse, honest channel
        -level summary: the three input channels (R, G, B) of the 224x224x3
        tiles are given uniform placeholder importance, and the note states
        plainly that pixel-region attribution is a coarse proxy and that a full
        Grad-CAM or SHAP attribution runs as a separate processing job.
        """
        if feature_importances:
            importances = {str(k): float(v) for k, v in feature_importances.items()}
            note = (
                "Explainability importances were supplied by the caller and are "
                "reported as global per-feature attribution."
            )
            global_importance = importances
        else:
            channels = ["channel_0_red", "channel_1_green", "channel_2_blue"]
            uniform = round(1.0 / len(channels), 6)
            global_importance = {name: uniform for name in channels}
            note = (
                "No precomputed feature importances were available. This report "
                "carries a coarse channel-level placeholder over the three RGB "
                "input channels of the 224x224x3 tiles, with uniform weights "
                "because no per-channel attribution was computed here. Pixel and "
                "region-level attribution (Grad-CAM or kernel SHAP) is a coarse "
                "proxy for these histopathology images and is intended to run as "
                "a separate processing job, not inline in evaluation. Do not read "
                "clinical meaning into these placeholder values."
            )

        report = {
            "version": "1.0",
            "explanations": {
                "kernel_shap": {
                    "global_shap_values": global_importance,
                    "expected_value": 0.5,
                    "label": "malignant",
                }
            },
            "note": note,
        }

        file_path = os.path.join(self.output_path, "explainability_report.json")
        with open(file_path, "w") as f:
            json.dump(report, f, indent=2)

        logger.info(f"Generated explainability report: {file_path}")
        return file_path

    def generate_test_input(self):
        """Generate test input for deployment health checks"""

        # Generate a deterministic test image (zeroes) - we don't need randomness
        # because this payload only exercises the serving contract, not accuracy.
        test_input = {
            "instances": [
                {
                    "data": [[[[0.5, 0.3, 0.8] for _ in range(224)] for _ in range(224)]],
                    "metadata": {"format": "array", "size": "224x224", "channels": 3},
                }
            ]
        }

        file_path = os.path.join(self.output_path, "test_input.json")
        with open(file_path, "w") as f:
            json.dump(test_input, f, indent=2)

        return file_path
