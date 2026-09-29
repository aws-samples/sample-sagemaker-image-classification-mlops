# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Endpoint explanations: the ensemble handler and the exported signatures.

The handler tests need no TensorFlow: a fake stands in for TensorFlow Serving.
The export tests build a tiny Keras model, export it with the explanation
signatures and serve it through the same fake, so they run only where
TensorFlow is installed (CI skips them).
"""

import io
import json
import math
from types import SimpleNamespace

import numpy as np
import pytest
from conftest import ROOT, load_module

inference = load_module("scripts/ensemble/inference.py", "ensemble_inference")

GRID = inference.REGION_GRID
N = GRID * GRID


def _masks(body):
    return json.loads(body)["inputs"]["masks"]


def _additive_call(region_weights, bias=0.1):
    """Fake member whose score is bias + sum of kept regions' weights."""

    def call(model_name, body):
        request = json.loads(body)
        if request.get("signature_name") == "region_scores":
            scores = [
                bias
                + sum(
                    region_weights[r * GRID + c] * m[r][c] for r in range(GRID) for c in range(GRID)
                )
                for m in _masks(body)
            ]
            return {"outputs": scores}
        if request.get("signature_name") == "gradcam":
            cam = [[0.0] * 14 for _ in range(14)]
            cam[3][4] = 2.0
            cam[3][5] = 1.5
            cam[9][9] = 0.4
            return {"outputs": {"cam_malignant": [cam], "cam_benign": [cam], "score": [0.7]}}
        return {"predictions": [[bias + sum(region_weights)]]}

    return call


CONFIG = {"models": ["a", "b"], "weights": [0.25, 0.75], "optimal_threshold": 0.5}


def test_plan_is_deterministic_and_antithetic():
    first = inference.plan_permutations(N, 64, seed=7)
    assert first == inference.plan_permutations(N, 64, seed=7)
    assert first != inference.plan_permutations(N, 64, seed=8)
    assert len(first) == 4
    assert first[1] == first[0][::-1]
    assert all(sorted(p) == list(range(N)) for p in first)


def test_plan_respects_the_evaluation_cap():
    for max_evals in (17, 31, 32, 47, 64):
        perms = inference.plan_permutations(N, max_evals, seed=0)
        assert 2 + len(perms) * (N - 1) <= max_evals


def test_region_shapley_recovers_additive_contributions():
    weights = [0.01 * i for i in range(N)]
    result = inference.region_shapley(
        "[0]", CONFIG, _additive_call(weights), max_evals=32, seed=0, deadline=math.inf
    )
    flat = [v for row in result["values"] for v in row]
    assert flat == pytest.approx(weights, abs=1e-4)
    assert result["baseline_score"] == pytest.approx(0.1)
    assert result["sum"] == pytest.approx(result["full_score"] - result["baseline_score"], abs=1e-3)
    assert result["evaluations"] == 32
    assert result["permutations"] == 2


def test_time_budget_stops_after_first_permutation():
    result = inference.region_shapley(
        "[0]", CONFIG, _additive_call([0.0] * N), max_evals=64, seed=0, deadline=0.0
    )
    assert result["permutations"] == 1
    assert result["evaluations"] == 2 + (N - 1)
    assert result["sum"] == pytest.approx(result["full_score"] - result["baseline_score"], abs=1e-3)


def test_top_region_is_the_connected_hot_area():
    grid = [[0.0] * 14 for _ in range(14)]
    grid[3][4], grid[3][5], grid[9][9] = 1.0, 0.75, 0.2
    region = inference.top_region(grid)
    assert region["peak_cell"] == [3, 4]
    assert region["cells"] == 2
    assert region["box"] == [round(4 / 14, 4), round(3 / 14, 4), round(6 / 14, 4), round(4 / 14, 4)]
    assert inference.top_region([[0.0] * 14 for _ in range(14)]) is None


def test_gradcam_combines_normalised_maps():
    out = inference.gradcam("[0]", CONFIG, "malignant", _additive_call([0.0] * N))
    assert out["grid_size"] == 14
    flat = [v for row in out["grid"] for v in row]
    assert max(flat) == 1.0
    assert min(flat) >= 0.0
    assert out["grid"][3][5] == 0.75


def test_response_without_explain_keeps_the_existing_shape():
    call = _additive_call([0.05] * N)
    response = inference.run({"instances": [[0]]}, CONFIG, call)
    assert list(response) == ["predictions", "predicted_class", "threshold_used"]
    assert response["predictions"] == [[pytest.approx(0.9)]]
    assert response["predicted_class"] == [[1]]
    assert response["threshold_used"] == 0.5


def test_response_with_explain_adds_explanations():
    call = _additive_call([0.05] * N)
    response = inference.run({"instances": [[0]], "explain": True}, CONFIG, call)
    explanations = response["explanations"]
    assert set(explanations) == {"gradcam", "region_shapley", "explain_ms"}
    assert explanations["gradcam"]["target"] == "malignant"
    assert isinstance(explanations["explain_ms"], int)


@pytest.mark.parametrize(
    "raw",
    [{"methods": []}, {"methods": ["lime"]}, {"max_evals": 5}, "yes", {"methods": "gradcam"}],
)
def test_invalid_explain_options_are_rejected(raw):
    with pytest.raises(ValueError):
        inference._explain_options(raw)


def test_explain_options_are_capped():
    _, max_evals, budget, _ = inference._explain_options(
        {"max_evals": 10_000, "time_budget_ms": 10_000_000}
    )
    assert max_evals == inference.MAX_EVALS_CAP
    assert budget == inference.MAX_TIME_BUDGET_MS


def test_missing_signature_is_reported_not_raised():
    def old_package(model_name, body):
        if "signature_name" in json.loads(body):
            raise inference.SignatureUnavailable("Serving signature name: gradcam not found")
        return {"predictions": [[0.2]]}

    response = inference.run({"instances": [[0]], "explain": True}, CONFIG, old_package)
    assert response["predicted_class"] == [[0]]
    assert response["explanations"]["gradcam"]["status"] == "unavailable"
    assert response["explanations"]["region_shapley"]["status"] == "unavailable"


def test_handler_reads_the_stream_and_returns_json(monkeypatch, tmp_path):
    config_path = tmp_path / "ensemble_config.json"
    config_path.write_text(json.dumps(CONFIG))
    monkeypatch.setenv("ENSEMBLE_CONFIG_PATH", str(config_path))
    monkeypatch.setattr(inference, "tfs_transport", lambda uri: _additive_call([0.0] * N))
    body, content_type = inference.handler(
        io.BytesIO(json.dumps({"instances": [[0]]}).encode()),
        SimpleNamespace(rest_uri="http://localhost:8501/v1/models/a_model:predict"),
    )
    assert content_type == "application/json"
    assert json.loads(body)["predicted_class"] == [[0]]


# --- Exported signatures (TensorFlow only) ----------------------------------


@pytest.fixture(scope="module")
def served(tmp_path_factory):
    """Two tiny exported members behind a fake TensorFlow Serving REST API."""
    tf = pytest.importorskip("tensorflow")
    import sys

    sys.path.insert(0, str(ROOT / "scripts" / "ensemble"))
    from explain_export import export_with_explanations

    tf.keras.utils.set_random_seed(0)
    root = tmp_path_factory.mktemp("models")
    keras_models, loaded = {}, {}
    for name in ("a", "b"):
        inputs = tf.keras.Input((32, 32, 3))
        x = tf.keras.layers.Conv2D(4, 3, padding="same", activation="relu")(inputs)
        x = tf.keras.layers.Conv2D(8, 3, strides=2, padding="same", activation="relu")(x)
        x = tf.keras.layers.GlobalAveragePooling2D()(x)
        x = tf.keras.layers.Dense(4, activation="relu")(x)
        x = tf.keras.layers.Dropout(0.3)(x)
        outputs = tf.keras.layers.Dense(1, activation="sigmoid")(x)
        model = tf.keras.Model(inputs, outputs)
        export_with_explanations(model, str(root / f"{name}_model" / "1"))
        keras_models[name] = model
        loaded[f"{name}_model"] = tf.saved_model.load(str(root / f"{name}_model" / "1"))

    def tfs(model_name, body):
        request = json.loads(body)
        signatures = loaded[model_name].signatures
        name = request.get("signature_name", "serving_default")
        if name not in signatures:
            raise inference.SignatureUnavailable(name)
        fn = signatures[name]
        if "instances" in request:
            (arg,) = fn.structured_input_signature[1]
            out = fn(**{arg: tf.constant(request["instances"], tf.float32)})
            (value,) = out.values()
            return {"predictions": value.numpy().tolist()}
        out = fn(**{k: tf.constant(v, tf.float32) for k, v in request["inputs"].items()})
        out = {k: v.numpy().tolist() for k, v in out.items()}
        return {"outputs": next(iter(out.values())) if len(out) == 1 else out}

    rng = np.random.default_rng(0)
    image = rng.normal(size=(32, 32, 3)).astype("float32")
    return SimpleNamespace(tf=tf, call=tfs, models=keras_models, image=image)


def _expected_ensemble(served, image):
    return sum(
        w * float(served.models[n](image[None], training=False)[0, 0])
        for n, w in zip(CONFIG["models"], CONFIG["weights"])
    )


def test_serving_signature_matches_the_keras_model(served):
    response = inference.run({"instances": [served.image.tolist()]}, CONFIG, served.call)
    assert response["predictions"][0][0] == pytest.approx(
        _expected_ensemble(served, served.image), abs=1e-5
    )


def test_exported_gradcam_grid_is_normalised(served):
    image_json = json.dumps(served.image.tolist())
    for target in ("malignant", "benign"):
        out = inference.gradcam(image_json, CONFIG, target, served.call)
        grid = out["grid"]
        assert len(grid) == 14
        assert all(len(row) == 14 for row in grid)
        flat = [v for row in grid for v in row]
        assert min(flat) >= 0.0
        assert max(flat) in (0.0, 1.0)


def test_exported_gradcam_matches_a_direct_gradient_tape(served):
    tf = served.tf
    model = served.models["a"]
    x = tf.constant(served.image[None])
    pool = next(
        layer for layer in model.layers if isinstance(layer, tf.keras.layers.GlobalAveragePooling2D)
    )
    features = tf.keras.Model(model.inputs, pool.input)
    with tf.GradientTape() as tape:
        acts = features(x)
        tape.watch(acts)
        h = acts
        for layer in model.layers[model.layers.index(pool) : -1]:
            h = layer(h, training=False)
        logit = tf.matmul(h, model.layers[-1].kernel) + model.layers[-1].bias
    grads = tape.gradient(logit, acts)
    cam = tf.nn.relu(tf.reduce_sum(acts * tf.reduce_mean(grads, axis=[1, 2], keepdims=True), -1))
    expected = tf.image.resize(cam[..., None], [14, 14])[0, ..., 0].numpy()

    body = json.dumps({"signature_name": "gradcam", "inputs": {"image": [served.image.tolist()]}})
    got = served.call("a_model", body)["outputs"]
    assert np.allclose(got["cam_malignant"][0], expected, atol=1e-6)
    assert got["score"][0] == pytest.approx(float(model(x)[0, 0]), abs=1e-5)


def test_exported_region_shapley_satisfies_efficiency_and_is_seeded(served):
    image_json = json.dumps(served.image.tolist())
    first = inference.region_shapley(image_json, CONFIG, served.call, 32, 0, math.inf)
    again = inference.region_shapley(image_json, CONFIG, served.call, 32, 0, math.inf)
    assert first["values"] == again["values"]

    flat = [v for row in first["values"] for v in row]
    assert len(flat) == N
    expected_full = _expected_ensemble(served, served.image)
    expected_empty = _expected_ensemble(served, served.image * 0.0)
    assert first["full_score"] == pytest.approx(expected_full, abs=1e-4)
    assert first["baseline_score"] == pytest.approx(expected_empty, abs=1e-4)
    assert sum(flat) == pytest.approx(expected_full - expected_empty, abs=N * 1e-4)


def test_package_puts_the_handler_where_the_serving_container_looks(tmp_path):
    import tarfile

    creator = load_module("scripts/ensemble/ensemble_creator.py", "ensemble_creator")
    for name in ("a", "b"):
        version = tmp_path / f"{name}_model" / "1"
        version.mkdir(parents=True)
        (version / "saved_model.pb").write_bytes(b"pb")
    creator.create_ensemble_package(str(tmp_path), {"a": 0.4, "b": 0.6}, 0.45)
    with tarfile.open(tmp_path / "model.tar.gz") as tar:
        names = set(tar.getnames())
    assert names == {
        "ensemble_config.json",
        "code/inference.py",
        "a_model/1/saved_model.pb",
        "b_model/1/saved_model.pb",
    }
    config = json.loads((tmp_path / "ensemble_config.json").read_text())
    assert config["models"] == ["a", "b"]
    assert config["weights"] == [0.4, 0.6]
