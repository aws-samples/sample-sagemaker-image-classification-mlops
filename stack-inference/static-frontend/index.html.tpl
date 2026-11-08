<!DOCTYPE html>
<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Image Classification</title>
    <link rel="stylesheet" href="app.css">
</head>
<body>
    <header>
        <div class="wrap">
            <h1>Image Classification</h1>
            <p>Binary image classification with per-image explanations</p>
        </div>
    </header>

    <main>
        <div class="notice" role="note">
            <strong>Demo, not for production decisions.</strong> Predictions come from a model trained in a sample
            pipeline. A person reviews low-confidence results before anyone acts on them.
        </div>

        <section class="panel" aria-labelledby="uploadTitle">
            <h2 id="uploadTitle">Analyze images</h2>
            <div class="upload" id="uploadArea" tabindex="0" role="button" aria-label="Choose images to analyze">
                <div><strong>Click to choose</strong> or drag and drop images here</div>
                <div class="hint">JPG or PNG, up to 3.5 MB each, several at once</div>
                <input type="file" id="fileInput" class="file-input" accept="image/png,image/jpeg" multiple>
            </div>
            <div class="thumbs" id="thumbs"></div>
            <div class="controls">
                <label><input type="checkbox" id="explainToggle" checked> Explain each prediction</label>
                <label>Overlay opacity <input type="range" id="opacity" min="0" max="100" value="50" aria-label="Overlay opacity"></label>
                <span class="spacer"></span>
                <button class="btn-ghost" id="clearBtn" type="button" disabled>Clear</button>
                <button class="btn" id="predictBtn" type="button" disabled>Analyze</button>
            </div>
            <div class="progress" id="progress" aria-live="polite"><div class="spinner"></div><span id="progressText">Analyzing...</span></div>
        </section>

        <section id="results" aria-live="polite"></section>

        <section class="panel help">
            <h2>How to read the results</h2>
            <ul>
                <li><strong>Score bar:</strong> the model's probability of the positive class (named in each result). The black line is the decision threshold chosen on validation data: at or above it the image is called the positive class.</li>
                <li><strong>Grad-CAM:</strong> where the model looked. Warm colours are the areas that drove the predicted class; the dashed box marks the strongest region. It is a coarse map (14 x 14) by design.</li>
                <li><strong>Region importance:</strong> region Shapley values on a 4 x 4 grid. Red regions pushed the score towards the positive class, blue towards the other class; together they add up to the change from a blank image to this one.</li>
                <li><strong>Low confidence:</strong> the image is flagged for human review. If enabled, a foundation model adds a short description of the image.</li>
                <li>Explanations take a few extra seconds per image and are computed on the same model servers, so several at once queue up. If one does not finish within the API's 29 s limit, the page still shows the prediction and offers to try the explanation again. The first requests after a deployment are slower while the model warms up.</li>
            </ul>
        </section>
        <footer>Demo purposes only. Review predictions before acting on them.</footer>
    </main>

    <script src="app.js"></script>
</body>
</html>
