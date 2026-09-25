# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Helpers shared by the pipeline steps, the scheduled monitoring jobs and the
inference Lambda.

One copy of each rule that must agree everywhere: the image transform, the
data-capture decoding, score extraction from an endpoint response, the
clinical and fairness gates, safe tar extraction and bounded S3 listing.

scripts/script_uploader.sh uploads this package next to every step script and
bundles it into the training tarballs. The inference Lambda ships a
byte-identical copy in stack-inference/lambda/mlops_common/ (refresh it with
scripts/sync_mlops_common.sh; tests/test_vendored_copy.py fails on drift).

The scheduled drift and fairness jobs run in the SageMaker scikit-learn image
(Python 3.9), so this package stays 3.9-compatible: no ``X | Y`` at runtime,
no ``match``, no ``datetime.UTC``. Heavy dependencies (scikit-learn, Fairlearn)
are imported inside the functions that need them so the Lambda, which only
carries numpy and Pillow, can import the package.
"""
