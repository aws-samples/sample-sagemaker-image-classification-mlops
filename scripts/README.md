# scripts

Production ML pipeline scripts and CI/CD-consumed utilities. Everything here is either:

- **Run inside an Amazon SageMaker Pipelines step** (validation, preprocessing, training, evaluation, ensemble, bias, inference), OR
- **Run as a scheduled SageMaker Processing job** started by Amazon EventBridge Scheduler (`drift/`, `fairness/`), OR
- **Invoked by the AWS CodeBuild buildspecs** (`script_uploader.sh`), OR
- **A human-facing production entry point** (`data_uploader.sh`)

Local-dev convenience scripts live in `ops-scripts/`.

## Layout

```
scripts/
|-- mlops_common/           # Shared helpers (see below)
|-- preprocessing/          # Resize to 512, group-aware train/val/test split (sharded)
|   `-- data_preprocessor.py
|-- training/               # VGG16, DenseNet121, EfficientNetV2-M trainers, simple CNN baseline
|   |-- vgg16_trainer.py
|   |-- densenet121_trainer.py
|   |-- efficientnet_trainer.py
|   |-- simple_cnn_trainer.py  # From-scratch baseline; never an ensemble member
|   |-- color_jitter.py     # Per-channel colour/intensity jitter for training images
|   |-- training_config.py
|   `-- training_metrics.py
|-- evaluation/             # Per-model threshold on validation, metrics on test
|   |-- model_evaluator.py
|   `-- report_generator.py
|-- ensemble/               # Weighted ensemble, threshold on validation, gate on test
|   |-- ensemble_creator.py
|   |-- explain_export.py   # SavedModel export with gradcam and region_scores signatures
|   `-- inference.py        # Serving handler, packaged as code/inference.py
|-- validation/             # Data integrity, format and quality checks; exclusion manifest
|   `-- data_validator.py
|-- bias/                   # In-pipeline fairness gate on the ensemble (Fairlearn)
|   |-- compute_bias.py
|   |-- run_bias_check.sh   # Installs fairlearn (from bias/wheels/ when present), then runs the gate
|   `-- requirements.txt
|-- drift/                  # Scheduled drift job - PSI on live predictions
|   `-- compute_drift.py
|-- fairness/               # Scheduled fairness job - subgroup metrics on live traffic
|   |-- compute_fairness.py
|   |-- run_fairness.sh     # Installs fairlearn (from fairness/wheels/ when present), then runs the monitor
|   `-- requirements.txt
|-- utils/                  # Amazon CloudWatch metrics helper
|   `-- cloudwatch_metrics.py
|-- data_uploader.sh        # Upload <folder>/<class>/<image> and manifest.csv to s3://<raw-data-bucket>/images/, then the start marker
|-- script_uploader.sh      # Upload all scripts above to the S3 scripts bucket (consumed by CI/CD)
|-- sync_mlops_common.sh    # Refresh the inference Lambda's copy of mlops_common
`-- README.md               # This file
```

## Shared helpers: `mlops_common/`

One copy of every rule that must agree across stages:

| Module | What it holds |
|---|---|
| `preprocess.py` | The image transform (explicit resample filters, a fixed per-channel mean/std normalisation: `CHANNEL_MEAN`, `CHANNEL_STD`, `imagenet_normalize`) for training, evaluation and serving |
| `dataset_layout.py` | Data layout rules: the two class folders and the positive class (`POSITIVE_CLASS`, `classes.json`), group id and subgroup from the file name (`<group>__<name>`, `<group>__<subgroup>__<name>`) or `manifest.csv` (which overrides both), and the group-aware split |
| `gates.py` | Binary metrics, validation-only threshold selection, quality gate (`QUALITY_GATE`) |
| `fairness.py` | Fairlearn subgroup metrics (demographic parity, equalized odds, equal opportunity); `max_disparity` is the larger of the first two; fewer than two subgroups is "not evaluable" |
| `capture.py`, `scores.py` | Data-capture decoding and score/threshold extraction from endpoint responses |
| `s3io.py` | Paginated listing, capture listing bounded by hour prefix |
| `safe_tar.py`, `seeds.py`, `datasets.py`, `constants.py` | Safe model extraction (`tarfile` `filter="data"` on Python 3.12+, its own member checks on older Python), seeding, split loading, shared constants |

`script_uploader.sh` uploads the package next to every step script and bundles it
into the training tarballs. The inference AWS Lambda function carries a byte-identical copy in
`stack-inference/lambda/mlops_common/`; after editing the package run
`scripts/sync_mlops_common.sh` (the test suite fails if the copies differ).

The drift and fairness jobs run in the SageMaker scikit-learn image (Python 3.9),
so the package stays 3.9-compatible.

## Excluded images

The validation step writes three files to `executions/<execution-id>/reports/validation/`
in the processed-data bucket:

- `validation_report.json`: counts, errors and warnings.
- `exclusion_manifest.json`: every image kept out of training, with its reason
  (`quality_check_failed` with its blur, contrast and edge-density values,
  `quality_check_error`, `below_min_resolution`, `unreadable`). Review it there.
- `image_inventory.json`: every readable image with its label, group id and
  `manifest.csv` attributes, plus the two class names.

An image that fails the quality check (`assess_image_quality` returns False) is
logged as a warning, counted (`DataValidation_ExcludedCount`) and listed in the
manifest, and the preprocessing step leaves it out of train, validation and test.
Unreadable and too-small images still fail the validation step. The minimum
per-class count and the class-balance check use the images that remain.

## Sharded preprocessing

The preprocessing step runs on `pipeline_steps.preprocessing.instance_count`
instances (2 in the shipped `terraform.tfvars`). The raw images are spread over
them (`ShardedByS3Key`), and every instance computes the group-aware split
from the same full inventory, so a group's images all land in one split
whichever instance holds them. Each instance writes only its own images, and
their uploads to `executions/<execution-id>/{train,validation,test}/` together
form the splits the trainers read. Each split also gets `classes.json` and its
`manifest.csv`.

## Simple CNN baseline

`training/simple_cnn_trainer.py` is a small CNN trained from scratch (convolution
blocks, global average pooling, one dense layer) with the same data loading,
image transform, class weights, augmentation and callbacks as the other trainers,
in one phase, as the other trainers do when no weights are supplied
(`backbone_weights_s3_uri`; with weights, its file holds the whole model). With a test channel it
also writes `test_metrics.json`. `script_uploader.sh` packages it as
`training/simple_cnn_trainer.tar.gz`. In the pipeline it is off by default; set
`baseline_cnn = { enabled = true, ... }` in `stack-training` to add the
TrainSimpleCnnBaseline step. It is never an ensemble member and is never
registered.

## Offline package installs

The pipeline jobs and the scheduled jobs run in the training Amazon VPC, which has no
route to PyPI. `script_uploader.sh` therefore downloads each pip-installing step's
pinned `requirements.txt` and its dependencies as wheels for the job's container
(Linux x86_64; CPython 3.12 for `validation`, `preprocessing` and `bias`, CPython
3.9 for `fairness`, which runs in the scikit-learn image) and syncs them to
`<step>/wheels/` in the scripts bucket. The step wrappers install from there with
`--no-index` when the folder exists. The machine that runs the uploader (`make
upload-scripts`, or the CI/CD Script-Upload stage) needs `pip` and PyPI access, and
the uploader fails if any wheelhouse is missing from the bucket afterwards.

## Tests

```bash
pip install --group dev   # pip 25.1+, from the repo root
pytest -q
```

## Typical usage

```bash
# Upload data/my-images/<class>/<image> and manifest.csv (if present) to
# s3://<raw-data-bucket>/images/ (--prefix changes it), then write the marker
# that triggers the pipeline. Flags: --prefix, --append, --count N, --no-dvc
./scripts/data_uploader.sh data/my-images

# Upload the latest ML scripts and wheelhouses to S3 (runs automatically in CI/CD;
# SCRIPTS_BUCKET defaults to the stack-training output)
(cd scripts && ./script_uploader.sh)
```

## Naming convention

- Python: `snake_case.py` (matches PEP 8).
- Shell: `snake_case.sh`.
- Verb-first for action scripts: `upload_*`, `download_*`.
- Model trainers named `<arch>_trainer.py` (e.g., `vgg16_trainer.py`).
- Each pip-installing step wrapper (`run_*.sh`) installs from `<step>/wheels/` in the
  scripts bucket when present (see [Offline package installs](#offline-package-installs)).
- Step scripts named after the verb+noun of the step (`data_validator.py`, `data_preprocessor.py`, `model_evaluator.py`, `ensemble_creator.py`).

## What does NOT belong here

- Local dev helpers, smoke tests, cleanup utilities -> `ops-scripts/`
- Baseline model creation / CI/CD orchestration -> `stack-cicd/scripts/`
