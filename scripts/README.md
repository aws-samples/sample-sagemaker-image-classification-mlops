# scripts

Production ML pipeline scripts and CI/CD-consumed utilities. Everything here is either:

- **Run inside a SageMaker step** (validation, preprocessing, training, evaluation, ensemble, bias, inference), OR
- **Run as a scheduled SageMaker Processing job** started by EventBridge Scheduler (`drift/`, `fairness/`), OR
- **Invoked by the CodeBuild buildspecs** (`script_uploader.sh`, `download_pretrained_weights.py`), OR
- **A human-facing production entry point** (`data_uploader.sh`)

Local-dev convenience scripts live in `ops-scripts/`.

## Layout

```
scripts/
|-- mlops_common/           # Shared helpers (see below)
|-- preprocessing/          # Resize to 512, patient-grouped train/val/test split
|   `-- data_preprocessor.py
|-- training/               # VGG16, DenseNet121, EfficientNet trainers
|   |-- vgg16_trainer.py
|   |-- densenet121_trainer.py
|   |-- efficientnet_trainer.py
|   |-- training_config.py
|   `-- training_metrics.py
|-- evaluation/             # Per-model threshold on validation, metrics on test
|   |-- model_evaluator.py
|   `-- report_generator.py
|-- ensemble/               # Weighted ensemble, threshold on validation, gate on test
|   |-- ensemble_creator.py
|   `-- inference.py
|-- validation/             # Data integrity and format checks
|   `-- data_validator.py
|-- bias/                   # In-pipeline fairness gate on the ensemble (Fairlearn)
|   |-- compute_bias.py
|   |-- run_bias_check.sh   # Installs fairlearn, then runs the gate
|   `-- requirements.txt
|-- drift/                  # Scheduled drift job - PSI on live predictions
|   `-- compute_drift.py
|-- fairness/               # Scheduled fairness job - subgroup metrics on live traffic
|   |-- compute_fairness.py
|   |-- run_fairness.sh     # Installs fairlearn, then runs the monitor
|   `-- requirements.txt
|-- utils/                  # CloudWatch metrics helper
|   `-- cloudwatch_metrics.py
|-- data_uploader.sh        # Upload local dataset to the raw-data S3 bucket
|-- download_pretrained_weights.py  # Download ImageNet weights (consumed by CI/CD)
|-- script_uploader.sh      # Upload all scripts above to the S3 scripts bucket (consumed by CI/CD)
|-- sync_mlops_common.sh    # Refresh the inference Lambda's copy of mlops_common
`-- README.md               # This file
```

## Shared helpers: `mlops_common/`

One copy of every rule that must agree across stages:

| Module | What it holds |
|---|---|
| `preprocess.py` | The image transform (explicit resample filters, ImageNet normalisation) for training, evaluation and serving |
| `breakhis.py` | BreakHis filename parsing (patient id, magnification) and the patient-grouped split |
| `gates.py` | Binary metrics, validation-only threshold selection, clinical gate |
| `fairness.py` | Fairlearn subgroup metrics; fewer than two subgroups is "not evaluable" |
| `capture.py`, `scores.py` | Data-capture decoding and score/threshold extraction from endpoint responses |
| `s3io.py` | Paginated listing, capture listing bounded by hour prefix, prefix deletion |
| `safe_tar.py`, `seeds.py`, `datasets.py`, `constants.py` | Safe model extraction, seeding, split loading, shared constants |

`script_uploader.sh` uploads the package next to every step script and bundles it
into the training tarballs. The inference Lambda carries a byte-identical copy in
`stack-inference/lambda/mlops_common/`; after editing the package run
`scripts/sync_mlops_common.sh` (the test suite fails if the copies differ).

The drift and fairness jobs run in the SageMaker scikit-learn image (Python 3.9),
so the package stays 3.9-compatible.

## Tests

```bash
pip install --group dev   # pip 25.1+, from the repo root
pytest -q
```

## Typical usage

```bash
# Upload a new dataset and trigger the pipeline
./scripts/data_uploader.sh data/batch1

# Upload the latest ML scripts to S3 (runs automatically in CI/CD)
(cd scripts && ./script_uploader.sh)
```

## Naming convention

- Python: `snake_case.py` (matches PEP 8).
- Shell: `snake_case.sh`.
- Verb-first for action scripts: `upload_*`, `download_*`.
- Model trainers named `<arch>_trainer.py` (e.g., `vgg16_trainer.py`).
- Step scripts named after the verb+noun of the step (`data_validator.py`, `data_preprocessor.py`, `model_evaluator.py`, `ensemble_creator.py`).

## What does NOT belong here

- Local dev helpers, smoke tests, cleanup utilities -> `ops-scripts/`
- Baseline model creation / CI/CD orchestration -> `stack-cicd/scripts/`
