// Injected by Terraform. The API key meters and rate-limits callers; it
// is visible to anyone who loads this page, so it is not authentication.
const API_ENDPOINT = '${api_url}/predict';
const API_KEY = '${api_key}';
// The API rejects bodies over about 5 MB of base64, about 3.7 MB of image.
const MAX_FILE_BYTES = 3.5 * 1024 * 1024;

const uploadArea = document.getElementById('uploadArea');
const fileInput = document.getElementById('fileInput');
const thumbs = document.getElementById('thumbs');
const predictBtn = document.getElementById('predictBtn');
const clearBtn = document.getElementById('clearBtn');
const progress = document.getElementById('progress');
const progressText = document.getElementById('progressText');
const results = document.getElementById('results');
const explainToggle = document.getElementById('explainToggle');
const opacityInput = document.getElementById('opacity');

let selectedFiles = [];
let items = [];

uploadArea.addEventListener('click', () => fileInput.click());
uploadArea.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); } });
uploadArea.addEventListener('dragover', e => { e.preventDefault(); uploadArea.classList.add('dragover'); });
uploadArea.addEventListener('dragleave', () => uploadArea.classList.remove('dragover'));
uploadArea.addEventListener('drop', e => { e.preventDefault(); uploadArea.classList.remove('dragover'); addFiles(Array.from(e.dataTransfer.files)); });
fileInput.addEventListener('change', e => { addFiles(Array.from(e.target.files)); fileInput.value = ''; });
predictBtn.addEventListener('click', analyzeAll);
clearBtn.addEventListener('click', clearAll);
opacityInput.addEventListener('input', () => items.forEach(drawItem));

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = String(text);
    return div.innerHTML;
}

function addFiles(files) {
    const problems = [];
    for (const file of files) {
        if (!/^image\/(png|jpeg)$/.test(file.type)) { problems.push(`$${escapeHtml(file.name)}: only JPG and PNG are supported`); continue; }
        if (file.size > MAX_FILE_BYTES) { problems.push(`$${escapeHtml(file.name)}: larger than 3.5 MB`); continue; }
        if (!selectedFiles.some(f => f.name === file.name && f.size === file.size)) selectedFiles.push(file);
    }
    renderThumbs();
    if (problems.length) showNotice(problems.join('<br>'));
}

function renderThumbs() {
    thumbs.innerHTML = selectedFiles.map(f =>
        `<div class="thumb"><img src="$${URL.createObjectURL(f)}" alt="$${escapeHtml(f.name)}">$${escapeHtml(f.name)}</div>`).join('');
    predictBtn.disabled = selectedFiles.length === 0;
    clearBtn.disabled = selectedFiles.length === 0 && items.length === 0;
    predictBtn.textContent = selectedFiles.length > 1 ? `Analyze $${selectedFiles.length} images` : 'Analyze';
}

function clearAll() {
    selectedFiles = [];
    items = [];
    results.innerHTML = '';
    renderThumbs();
}

function showNotice(html) {
    const div = document.createElement('div');
    div.className = 'notice';
    div.innerHTML = html;
    results.prepend(div);
}

function fileToBase64(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(',')[1]);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
}

async function callApi(file, explain) {
    const headers = { 'Content-Type': 'application/json' };
    if (API_KEY) headers['x-api-key'] = API_KEY;
    const started = performance.now();
    const response = await fetch(API_ENDPOINT, {
        method: 'POST',
        headers,
        body: JSON.stringify({ image: await fileToBase64(file), explain })
    });
    const elapsed = (performance.now() - started) / 1000;
    if (!response.ok) {
        let detail = '';
        try { const body = await response.json(); detail = body.detail || body.error || body.message || ''; } catch (_) { /* not JSON */ }
        const hint = (response.status === 502 || response.status === 504)
            ? ' The model may be warming up after a deployment; try again in a minute.' : '';
        throw new Error(`API error $${response.status}$${detail ? ': ' + detail : ''}.$${hint}`);
    }
    const result = await response.json();
    result._elapsed = elapsed;
    return result;
}

async function analyzeAll() {
    if (!selectedFiles.length) return;
    predictBtn.disabled = true;
    progress.style.display = 'flex';
    const batch = selectedFiles.splice(0);
    renderThumbs();
    predictBtn.disabled = true;
    for (let i = 0; i < batch.length; i++) {
        progressText.textContent = `Analyzing $${i + 1} of $${batch.length}: $${batch[i].name}`;
        await analyzeOne({ file: batch[i] });
        renderSummary();
    }
    progress.style.display = 'none';
    renderThumbs();
}

// A request that gets no answer within API Gateway's 29 s limit reaches
// the page as a bare network error, so name the likely cause.
function describeError(err) {
    const msg = err && err.message ? err.message : String(err);
    if (/NetworkError|Failed to fetch|Load failed/i.test(msg)) {
        return 'No answer within 29 s (the API limit). The model endpoint is busy or warming up.';
    }
    return msg;
}

async function analyzeOne(item) {
    const explain = explainToggle.checked;
    item.explainFailed = null;
    try {
        item.result = await callApi(item.file, explain);
        item.error = null;
    } catch (err) {
        if (explain) {
            // Explanations are the slow part; still give the prediction.
            item.explainFailed = describeError(err);
            try {
                item.result = await callApi(item.file, false);
                item.error = null;
            } catch (err2) {
                item.result = null;
                item.error = describeError(err2);
            }
        } else {
            item.result = null;
            item.error = describeError(err);
        }
    }
    if (!items.includes(item)) items.push(item);
    renderCard(item);
}

async function explainAgain(item) {
    const btn = item.el.querySelector('[data-act="explain"]');
    if (btn) { btn.disabled = true; btn.textContent = 'Explaining...'; }
    try {
        item.result = await callApi(item.file, true);
        item.explainFailed = null;
    } catch (err) {
        item.explainFailed = describeError(err);
    }
    renderCard(item);
}

function classNames(r) {
    const positive = r && r.positive_class ? String(r.positive_class) : 'positive';
    const others = r && r.probabilities ? Object.keys(r.probabilities).filter(k => k !== positive) : [];
    return { positive, negative: others.length ? others[0] : 'negative' };
}

function renderSummary() {
    const done = items.filter(i => i.result);
    const positives = done.filter(i => i.result.prediction === classNames(i.result).positive).length;
    const flagged = done.filter(i => String(i.result.routing || '').startsWith('low-confidence')).length;
    const failed = items.filter(i => i.error).length;
    let el = document.getElementById('summary');
    if (!el) { el = document.createElement('div'); el.id = 'summary'; el.className = 'summary'; results.prepend(el); }
    el.innerHTML = [
        ['Analyzed', done.length], ['Positive class', positives], ['Other class', done.length - positives],
        ['Flagged for review', flagged], ['Failed', failed]
    ].map(([k, v]) => `<div class="stat"><div class="k">$${k}</div><div class="v">$${v}</div></div>`).join('');
}

function renderCard(item) {
    if (!item.el) {
        item.el = document.createElement('article');
        results.appendChild(item.el);
    }
    const r = item.result;
    if (!r) {
        item.el.className = 'card error';
        item.el.innerHTML = `
            <div class="viewer"><canvas width="448" height="448" aria-label="$${escapeHtml(item.file.name)}"></canvas></div>
            <div>
                <div class="name">$${escapeHtml(item.file.name)}</div>
                <div class="error-text">$${escapeHtml(item.error)}</div>
                <div class="actions"><button class="btn-ghost" data-act="retry">Try again</button></div>
            </div>`;
        item.el.querySelector('[data-act="retry"]').onclick = () => analyzeOne(item).then(renderSummary);
        item.view = 'original';
        loadImage(item);
        return;
    }
    const e = r.explanations && !r.explanations.status ? r.explanations : null;
    const hasCam = !!(e && e.gradcam && Array.isArray(e.gradcam.grid));
    const hasShap = !!(e && e.region_shapley && Array.isArray(e.region_shapley.values));
    if (!item.view || (item.view === 'gradcam' && !hasCam)) item.view = hasCam ? 'gradcam' : 'original';
    const names = classNames(r);
    const raw = r.probabilities ? r.probabilities[names.positive] : null;
    const pm = typeof raw === 'number' ? raw : null;
    const thr = typeof r.threshold_used === 'number' ? r.threshold_used : null;
    const isPos = r.prediction === names.positive;
    const flagged = String(r.routing || '').startsWith('low-confidence');
    const gauge = pm === null ? '' : `
        <div class="gauge" role="img" aria-label="Score for $${escapeHtml(names.positive)} $${pm.toFixed(2)}$${thr !== null ? ', threshold ' + thr.toFixed(2) : ''}">
            <div class="fill $${isPos ? 'positive' : 'negative'}"></div>
            $${thr !== null ? `<div class="thr"><span>threshold $${thr.toFixed(2)}</span></div>` : ''}
        </div>
        <div class="gauge-labels"><span>0 $${escapeHtml(names.negative)}</span><span>score $${pm.toFixed(3)}</span><span>1 $${escapeHtml(names.positive)}</span></div>`;
    const explainNote = item.explainFailed
        ? `<div class="chips"><span class="chip warn">Explanation not available: $${escapeHtml(item.explainFailed)} The prediction above came from a second, faster request.</span></div><div class="actions"><button class="btn-ghost" data-act="explain">Try the explanation again</button></div>`
        : (r.explanations && r.explanations.status
            ? `<div class="chips"><span class="chip">Explanations $${escapeHtml(r.explanations.status)}$${r.explanations.reason ? ': ' + escapeHtml(r.explanations.reason) : ''}</span></div>` : '');
    const camTarget = hasCam ? escapeHtml(e.gradcam.target === 'negative' ? names.negative : names.positive) : '';
    item.el.className = 'card';
    item.el.innerHTML = `
        <div class="viewer">
            <div class="tabs" role="tablist">
                <button class="tab" role="tab" data-view="original">Original</button>
                <button class="tab" role="tab" data-view="gradcam" $${hasCam ? '' : 'disabled'}>Grad-CAM</button>
                <button class="tab" role="tab" data-view="regions" $${hasShap ? '' : 'disabled'}>Region importance</button>
            </div>
            <canvas width="448" height="448" aria-label="$${escapeHtml(item.file.name)}"></canvas>
            <div class="legend" data-legend></div>
        </div>
        <div>
            <div class="name">$${escapeHtml(item.file.name)}</div>
            <div class="verdict $${isPos ? 'positive' : 'negative'}">$${escapeHtml(r.prediction)}</div>
            $${gauge}
            <div class="explain-text">
                $${pm === null ? '' : `The score for $${escapeHtml(names.positive)} is <strong>$${pm.toFixed(3)}</strong>, $${isPos ? 'at or above' : 'below'} the threshold of $${thr !== null ? thr.toFixed(2) : '?'}, so the model calls it <strong>$${escapeHtml(r.prediction)}</strong> with $${Math.round((r.confidence || 0) * 100)}% confidence in that class.`}
                $${hasCam ? ` Grad-CAM shows the areas that drove the $${camTarget} call.` : ''}
            </div>
            <div class="chips">
                $${flagged ? '<span class="chip warn">Low confidence: flagged for human review</span>' : '<span class="chip">Confidence above the review cut-off</span>'}
                $${e && typeof e.explain_ms === 'number' ? `<span class="chip">Explanations $${(e.explain_ms / 1000).toFixed(1)} s</span>` : ''}
                $${typeof r._elapsed === 'number' ? `<span class="chip">Round trip $${r._elapsed.toFixed(1)} s</span>` : ''}
            </div>
            $${explainNote}
            $${r.reasoning ? `<div class="reasoning"><strong>Foundation model description (low-confidence case)</strong>$${escapeHtml(r.reasoning)}</div>` : ''}
            <div class="actions">
                <button class="btn-ghost" data-act="json">Download JSON</button>
                $${r.request_id ? `<button class="btn-ghost" data-act="copy">Copy request id</button>` : ''}
            </div>
            <details><summary>Raw response</summary><pre>$${escapeHtml(JSON.stringify(stripPrivate(r), null, 2))}</pre></details>
            $${r.request_id ? `<div class="muted request-id">Request id $${escapeHtml(r.request_id)}</div>` : ''}
        </div>`;
    const fill = item.el.querySelector('.gauge .fill');
    if (fill) fill.style.width = `$${(pm * 100).toFixed(1)}%`;
    const marker = item.el.querySelector('.gauge .thr');
    if (marker) marker.style.left = `calc($${(thr * 100).toFixed(1)}% - 1px)`;
    item.el.querySelectorAll('.tab').forEach(tab => {
        tab.onclick = () => { if (!tab.disabled) { item.view = tab.dataset.view; drawItem(item); } };
    });
    item.el.querySelector('[data-act="json"]').onclick = () => downloadJson(item);
    const again = item.el.querySelector('[data-act="explain"]');
    if (again) again.onclick = () => explainAgain(item);
    const copy = item.el.querySelector('[data-act="copy"]');
    if (copy) copy.onclick = () => navigator.clipboard && navigator.clipboard.writeText(r.request_id);
    loadImage(item);
}

function stripPrivate(r) {
    const out = Object.assign({}, r);
    delete out._elapsed;
    return out;
}

function downloadJson(item) {
    const blob = new Blob([JSON.stringify(stripPrivate(item.result), null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = item.file.name.replace(/\.[^.]+$/, '') + '.prediction.json';
    a.click();
}

function loadImage(item) {
    if (item.image) { drawItem(item); return; }
    const image = new Image();
    image.onload = () => { item.image = image; drawItem(item); };
    image.src = URL.createObjectURL(item.file);
}

// Jet-like colour map for Grad-CAM values in [0, 1].
function jet(v) {
    const x = Math.max(0, Math.min(1, v));
    const ch = k => Math.max(0, Math.min(1, 1.5 - Math.abs(4 * x - k))) * 255;
    return [ch(3), ch(2), ch(1)];
}

// Diverging blue-white-red for values in [-1, 1].
function diverging(v) {
    const x = Math.max(-1, Math.min(1, v));
    const white = [247, 247, 247], to = x < 0 ? [33, 102, 172] : [178, 24, 43];
    return white.map((w, i) => w + (to[i] - w) * Math.abs(x));
}

function gridCanvas(grid, colour) {
    const rows = grid.length, cols = grid[0].length;
    const small = document.createElement('canvas');
    small.width = cols; small.height = rows;
    const ctx = small.getContext('2d');
    const img = ctx.createImageData(cols, rows);
    for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
            const [cr, cg, cb] = colour(grid[r][c]);
            const o = (r * cols + c) * 4;
            img.data[o] = cr; img.data[o + 1] = cg; img.data[o + 2] = cb; img.data[o + 3] = 255;
        }
    }
    ctx.putImageData(img, 0, 0);
    return small;
}

// The model input is the whole upload resized to a square, so the
// explanation grids map onto the image stretched to the same square.
function drawItem(item) {
    if (!item.el || !item.image) return;
    const canvas = item.el.querySelector('canvas');
    const legend = item.el.querySelector('[data-legend]');
    const ctx = canvas.getContext('2d');
    const W = canvas.width, H = canvas.height;
    const alpha = Number(opacityInput.value) / 100;
    const e = item.result && item.result.explanations && !item.result.explanations.status ? item.result.explanations : null;
    item.el.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', String(t.dataset.view === item.view)));
    ctx.globalAlpha = 1;
    ctx.clearRect(0, 0, W, H);
    ctx.drawImage(item.image, 0, 0, W, H);
    if (legend) legend.innerHTML = '';
    if (item.view === 'gradcam' && e && e.gradcam) {
        ctx.globalAlpha = alpha;
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(gridCanvas(e.gradcam.grid, jet), 0, 0, W, H);
        ctx.globalAlpha = 1;
        const region = e.gradcam.top_region;
        const box = region && (Array.isArray(region) ? region : region.box);
        if (Array.isArray(box) && box.length === 4) {
            ctx.lineWidth = 4;
            ctx.strokeStyle = '#ffffff';
            ctx.setLineDash([10, 6]);
            ctx.strokeRect(box[0] * W, box[1] * H, (box[2] - box[0]) * W, (box[3] - box[1]) * H);
            ctx.setLineDash([]);
        }
        const camNames = classNames(item.result);
        const camClass = e.gradcam.target === 'negative' ? camNames.negative : camNames.positive;
        if (legend) legend.innerHTML = `<div class="bar bar-cam"></div>Low to high attention for the $${escapeHtml(camClass)} class. Dashed box: strongest region.`;
    } else if (item.view === 'regions' && e && e.region_shapley) {
        const values = e.region_shapley.values;
        const peak = Math.max(1e-6, ...values.flat().map(v => Math.abs(v)));
        ctx.globalAlpha = alpha;
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(gridCanvas(values.map(row => row.map(v => v / peak)), diverging), 0, 0, W, H);
        ctx.globalAlpha = 1;
        const n = values.length, cw = W / n, ch = H / n;
        ctx.font = 'bold 30px -apple-system, Segoe UI, sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        for (let r = 0; r < n; r++) {
            for (let c = 0; c < n; c++) {
                ctx.strokeStyle = 'rgba(255,255,255,0.9)';
                ctx.lineWidth = 1.5;
                ctx.strokeRect(c * cw, r * ch, cw, ch);
                const label = (values[r][c] >= 0 ? '+' : '') + values[r][c].toFixed(2);
                ctx.lineWidth = 5;
                ctx.strokeText(label, c * cw + cw / 2, r * ch + ch / 2);
                ctx.fillStyle = '#111827';
                ctx.fillText(label, c * cw + cw / 2, r * ch + ch / 2);
            }
        }
        const rs = e.region_shapley;
        const extra = typeof rs.baseline_score === 'number' && typeof rs.full_score === 'number'
            ? ` Score moves from $${rs.baseline_score.toFixed(2)} (blank image) to $${rs.full_score.toFixed(2)} (this image).` : '';
        const shapNames = classNames(item.result);
        if (legend) legend.innerHTML = `<div class="bar bar-shap"></div>Blue pushes towards $${escapeHtml(shapNames.negative)}, red towards $${escapeHtml(shapNames.positive)}.$${extra}`;
    }
}

document.addEventListener('DOMContentLoaded', () => {
    if (API_ENDPOINT.includes('your-api-gateway-url')) {
        showNotice('API endpoint not configured.');
    }
});
