# scripts

Production ML pipeline scripts and CI/CD-consumed utilities. Everything here is either:

- **Run inside a SageMaker step** (validation, preprocessing, training, evaluation, ensemble, inference), OR
- **Invoked by the CodeBuild buildspecs** (`script_uploader.sh`, `download_pretrained_weights.py`), OR
- **A human-facing production entry point** (`data_uploader.sh`)

Local-dev convenience scripts live in `ops-scripts/`.

## Layout

```
scripts/
├── preprocessing/          # Image resize, normalize, train/val/test split
│   └── data_preprocessor.py
├── training/               # VGG16, DenseNet121, EfficientNet trainers
│   ├── vgg16_trainer.py
│   ├── densenet121_trainer.py
│   ├── efficientnet_trainer.py
│   ├── training_config.py
│   └── training_metrics.py
├── evaluation/             # Multi-model evaluation and reporting
│   ├── model_evaluator.py
│   └── report_generator.py
├── ensemble/               # Weighted ensemble creation + SageMaker inference handler
│   ├── ensemble_creator.py
│   └── inference.py
├── validation/             # Data integrity and format checks
│   └── data_validator.py
├── utils/                  # CloudWatch metrics helper
│   └── cloudwatch_metrics.py
├── data_uploader.sh        # Upload local dataset to the raw-data S3 bucket
├── download_pretrained_weights.py  # Download ImageNet weights (consumed by CI/CD)
├── script_uploader.sh      # Upload all scripts above to the S3 scripts bucket (consumed by CI/CD)
└── README.md               # This file
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

- Local dev helpers, smoke tests, cleanup utilities → `ops-scripts/`
- Baseline model creation / CI/CD orchestration → `stack-cicd/scripts/`
