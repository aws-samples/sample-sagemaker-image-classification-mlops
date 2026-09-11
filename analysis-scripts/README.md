# analysis-scripts

One-off helpers for analysis, research, and blog content. **Not part of the production MLOps pipeline flow** - none of these are invoked by SageMaker, Lambda, or CI/CD.

## What is in here

### Endpoint testing / evaluation

| Script                         | Purpose                                                           |
| ------------------------------ | ----------------------------------------------------------------- |
| `data_accuracy_test.py`             | Ad-hoc SageMaker endpoint accuracy smoke test                     |
| `data_cross_dataset_eval.py`        | Evaluate deployed endpoint against an out-of-distribution dataset |
| `ops_generate_endpoint_traffic.py` | Send synthetic traffic to the endpoint (seed drift-detection data) |

### Dataset / batch helpers

| Script                    | Purpose                                                             |
| ------------------------- | ------------------------------------------------------------------- |
| `data_download_breakhis.sh`    | Download & organize BreakHis public dataset as a new batch folder   |
| `data_create_bias_scenario.py` | Build a biased-sampling data batch for fairness experiments         |
| `data_rebatch.py`     | Re-chunk all data into N equal batches for pipeline experimentation |

### Training job data collection

| Script                    | Purpose                                                             |
| ------------------------- | ------------------------------------------------------------------- |
| `data_gather_training.sh` | Collect SageMaker training-job metadata for all pipeline executions |
| `ops_launch_hpo.py`       | Launch a SageMaker Hyperparameter Tuning job outside the pipeline   |

### Chart and blog-content generators

| Script                              | Purpose                                                               |
| ----------------------------------- | --------------------------------------------------------------------- |
| `chart_metrics.py`        | Ensemble / per-model accuracy progression charts                      |
| `chart_training_analytics.py`       | Training analytics charts (loss, overfitting gap, throughput)         |
| `chart_misc.py`      | Bias disparity, drift, confidence-over-time charts                    |
| `chart_bias_scenario.py`  | Bias scenario distribution and impact confusion charts                |
| `chart_preprocessing_samples.py` | Before/after preprocessing grid for the blog                          |
| `chart_model_eye_view.py`        | Model's-eye-view visualization (what the network receives)            |
| `chart_gradcam.py`               | Grad-CAM saliency overlay for a single image                          |
| `chart_gradcam_comparison.py`    | Side-by-side Grad-CAM of correct vs incorrect predictions             |
| `chart_blog_visuals.py`          | SMOTE / ROC / learning-rate / early-stopping / CloudWatch mock plots  |
| `chart_amt_placeholder.py`       | Placeholder chart for AMT tuning section                              |
| `chart_real_from_data.py`         | Pull latest real data from AWS and regenerate bias + confusion charts |
| `chart_part2_flows.py`           | Part 2 flow diagrams (two-phase training, HPO to registry)            |

### Blog document helpers

Operate on the Word documents in `blog_docs/` - extracting the embedded figures
and swapping a regenerated one back in without disturbing the rest of the file.

| Script                    | Purpose                                                                       |
| ------------------------- | ----------------------------------------------------------------------------- |
| `docx_extract_images.py`  | Extract every embedded image from the blog `.docx` files                       |
| `docx_replace_figure.py`  | Replace one figure in a `.docx`, fixing the display extent so it is not stretched |

### Monitoring fix-up

| Script                          | Purpose                                                              |
| ------------------------------- | -------------------------------------------------------------------- |
| `ops_fix_monitor_baseline.py` | Upload a synthetic drift baseline (needed for base64 images)          |

## Typical workflows

```bash
# Pull training-job metadata then regenerate chart set
./analysis-scripts/data_gather_training.sh /tmp/training_data
python analysis-scripts/chart_metrics.py
python analysis-scripts/chart_training_analytics.py

# Cross-dataset generalization check against BreakHis
./analysis-scripts/data_download_breakhis.sh data/batch4_breakhis
python analysis-scripts/data_cross_dataset_eval.py --data-dir data/batch4_breakhis

# Regenerate all real-data charts from live AWS
python analysis-scripts/chart_real_from_data.py
```

## Dependencies

Python environment with `matplotlib`, `seaborn`, `pandas`, `numpy`, `boto3`, `Pillow`, and `tensorflow` (for Grad-CAM scripts only). Not used by CodeBuild or SageMaker.
