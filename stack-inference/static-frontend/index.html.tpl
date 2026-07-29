<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Medical Image Classification</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 15px; box-shadow: 0 20px 40px rgba(0,0,0,0.1); overflow: hidden; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; text-align: center; }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .header p { font-size: 1.1em; opacity: 0.9; }
        .content { padding: 40px; }
        .upload-area { border: 3px dashed #667eea; border-radius: 10px; padding: 40px; text-align: center; margin-bottom: 30px; transition: all 0.3s ease; cursor: pointer; }
        .upload-area:hover { border-color: #764ba2; background: #f8f9ff; }
        .upload-area.dragover { border-color: #764ba2; background: #f0f4ff; }
        .upload-icon { font-size: 3em; color: #667eea; margin-bottom: 15px; }
        .upload-text { font-size: 1.2em; color: #666; margin-bottom: 15px; }
        .file-input { display: none; }
        .btn { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 12px 30px; border-radius: 25px; font-size: 1em; cursor: pointer; transition: all 0.3s ease; }
        .btn:hover { transform: translateY(-2px); box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4); }
        .btn:disabled { opacity: 0.6; cursor: not-allowed; transform: none; }
        .preview-area { margin: 20px 0; text-align: center; }
        .preview-img { max-width: 300px; max-height: 300px; border-radius: 10px; box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
        .result-area { margin-top: 30px; padding: 20px; border-radius: 10px; display: none; }
        .result-success { background: #d4edda; border: 1px solid #c3e6cb; color: #155724; }
        .result-error { background: #f8d7da; border: 1px solid #f5c6cb; color: #721c24; }
        .prediction { font-size: 1.5em; font-weight: bold; margin-bottom: 10px; }
        .confidence { font-size: 1.2em; margin-bottom: 15px; }
        .confidence-bar { width: 100%; height: 20px; background: #e9ecef; border-radius: 10px; overflow: hidden; margin: 10px 0; }
        .confidence-fill { height: 100%; border-radius: 10px; transition: width 0.5s ease; }
        .confidence-benign { background: linear-gradient(90deg, #28a745, #20c997); }
        .confidence-malignant { background: linear-gradient(90deg, #dc3545, #fd7e14); }
        .loading { display: none; text-align: center; margin: 20px 0; }
        .spinner { border: 4px solid #f3f3f3; border-top: 4px solid #667eea; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 0 auto 15px; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
        .info-box { background: #e7f3ff; border: 1px solid #b8daff; border-radius: 8px; padding: 15px; margin-bottom: 20px; }
        .info-box h3 { color: #004085; margin-bottom: 8px; }
        .info-box p { color: #004085; font-size: 0.9em; }
        .batch-results { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-top: 20px; }
        .result-card { border: 1px solid #ddd; border-radius: 10px; padding: 15px; background: white; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .result-card img { width: 100%; max-height: 150px; object-fit: cover; border-radius: 5px; margin-bottom: 10px; }
        .file-counter { background: #667eea; color: white; padding: 5px 10px; border-radius: 15px; font-size: 0.8em; margin-top: 10px; display: inline-block; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔬 Medical Image Classification</h1>
            <p>AI-powered medical image analysis using deep learning</p>
        </div>

        <div class="content">
            <div class="info-box">
                <h3>How it works:</h3>
                <p>Upload a medical histopathology image and our AI model will analyze it to predict whether the tissue is benign or malignant with confidence scores.</p>
            </div>

            <div class="upload-area" id="uploadArea">
                <div class="upload-icon">📁</div>
                <div class="upload-text">Click to upload or drag and drop images</div>
                <div style="font-size: 0.9em; color: #999; margin-top: 10px;">Supported formats: JPG, JPEG, PNG | Select multiple files</div>
                <input type="file" id="fileInput" class="file-input" accept="image/*" multiple>
            </div>

            <div class="preview-area" id="previewArea"></div>

            <div class="loading" id="loading">
                <div class="spinner"></div>
                <div>Analyzing image...</div>
            </div>

            <div class="result-area" id="resultArea"></div>

            <div style="text-align: center; margin-top: 30px;">
                <button class="btn" id="predictBtn" disabled>🔍 Analyze Images</button>
                <div id="fileCounter" class="file-counter" style="display: none;">0 files selected</div>
            </div>
        </div>
    </div>

    <script>
        // Configuration - Automatically injected by Terraform
        const API_ENDPOINT = '${api_url}/predict';

        let selectedFiles = [];

        // DOM elements
        const uploadArea = document.getElementById('uploadArea');
        const fileInput = document.getElementById('fileInput');
        const previewArea = document.getElementById('previewArea');
        const predictBtn = document.getElementById('predictBtn');
        const loading = document.getElementById('loading');
        const resultArea = document.getElementById('resultArea');
        const fileCounter = document.getElementById('fileCounter');

        // File upload handlers
        uploadArea.addEventListener('click', () => fileInput.click());
        uploadArea.addEventListener('dragover', handleDragOver);
        uploadArea.addEventListener('dragleave', handleDragLeave);
        uploadArea.addEventListener('drop', handleDrop);
        fileInput.addEventListener('change', handleFileSelect);
        predictBtn.addEventListener('click', predictImage);

        function handleDragOver(e) {
            e.preventDefault();
            uploadArea.classList.add('dragover');
        }

        function handleDragLeave(e) {
            e.preventDefault();
            uploadArea.classList.remove('dragover');
        }

        function handleDrop(e) {
            e.preventDefault();
            uploadArea.classList.remove('dragover');
            const files = Array.from(e.dataTransfer.files);
            handleFiles(files);
        }

        function handleFileSelect(e) {
            const files = Array.from(e.target.files);
            handleFiles(files);
        }

        function handleFiles(files) {
            const validFiles = [];

            for (const file of files) {
                // Validate file type
                if (!file.type.startsWith('image/')) {
                    showError(`$${file.name}: Please select valid image files (JPG, JPEG, PNG)`);
                    continue;
                }

                // Validate file size (max 10MB)
                if (file.size > 10 * 1024 * 1024) {
                    showError(`$${file.name}: File size must be less than 10MB`);
                    continue;
                }

                validFiles.push(file);
            }

            if (validFiles.length > 0) {
                selectedFiles = validFiles;
                showPreviews(validFiles);
                updateFileCounter();
                predictBtn.disabled = false;
                hideResult();
            }
        }

        function showPreviews(files) {
            previewArea.innerHTML = '';

            files.forEach((file, index) => {
                const reader = new FileReader();
                reader.onload = function(e) {
                    const previewDiv = document.createElement('div');
                    previewDiv.style.cssText = 'display: inline-block; margin: 10px; text-align: center;';
                    previewDiv.innerHTML = `
                        <img src="$${e.target.result}" alt="Preview" style="max-width: 150px; max-height: 150px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                        <div style="margin-top: 8px; color: #666; font-size: 0.8em; max-width: 150px; word-wrap: break-word;">
                            <strong>$${file.name}</strong><br>
                            $${(file.size / 1024).toFixed(1)} KB
                        </div>
                    `;
                    previewArea.appendChild(previewDiv);
                };
                reader.readAsDataURL(file);
            });
        }

        function updateFileCounter() {
            const count = selectedFiles.length;
            fileCounter.textContent = `$${count} file$${count !== 1 ? "s" : ""} selected`;
            fileCounter.style.display = count > 0 ? "inline-block" : "none";
        }

        async function predictImage() {
            if (selectedFiles.length === 0) {
                showError('Please select at least one image first');
                return;
            }

            // Show loading
            loading.style.display = 'block';
            predictBtn.disabled = true;
            hideResult();

            const results = [];

            try {
                // Process each file
                for (let i = 0; i < selectedFiles.length; i++) {
                    const file = selectedFiles[i];

                    // Update loading text
                    document.querySelector("#loading div:last-child").textContent =
                        `Analyzing image $${i + 1} of $${selectedFiles.length}...`;

                    try {
                        // Convert image to base64
                        const base64Image = await fileToBase64(file);

                        // Send base64 - Lambda will decode and convert to model format
                        const response = await fetch(API_ENDPOINT, {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/json',
                            },
                            body: JSON.stringify({
                                image: base64Image.split(',')[1] // Remove data:image/jpeg;base64, prefix
                            })
                        });

                        if (!response.ok) {
                            throw new Error(`API Error: $${response.status} $${response.statusText}`);
                        }

                        const result = await response.json();
                        results.push({ file, result, success: true });

                    } catch (error) {
                        console.error(`Prediction error for $${file.name}:`, error);
                        results.push({ file, error: error.message, success: false });
                    }
                }

                showBatchResults(results);

            } catch (error) {
                console.error('Batch prediction error:', error);
                showError(`Batch prediction failed: $${error.message}`);
            } finally {
                loading.style.display = 'none';
                predictBtn.disabled = false;
            }
        }

        function fileToBase64(file) {
            return new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.readAsDataURL(file);
                reader.onload = () => resolve(reader.result);
                reader.onerror = error => reject(error);
            });
        }

        function showBatchResults(results) {
            const successCount = results.filter(r => r.success).length;
            const totalCount = results.length;

            let summaryHtml = `
                <div style="text-align: center; margin-bottom: 20px; padding: 15px; background: #f8f9fa; border-radius: 8px;">
                    <h3>Batch Analysis Complete</h3>
                    <p>Successfully analyzed $${successCount} of $${totalCount} images</p>
                </div>
            `;

            let cardsHtml = '<div class="batch-results">';

            results.forEach((item, index) => {
                if (item.success) {
                    const prediction = item.result.prediction || 'Unknown';
                    const confidence = item.result.confidence || 0;
                    const isMalignant = prediction.toLowerCase().includes('malignant');
                    const confidencePercent = Math.round(confidence * 100);
                    const confidenceClass = isMalignant ? 'confidence-malignant' : 'confidence-benign';
                    const emoji = isMalignant ? '⚠️' : '✅';

                    cardsHtml += `
                        <div class="result-card">
                            <img src="$${URL.createObjectURL(item.file)}" alt="$${item.file.name}">
                            <div style="font-weight: bold; margin-bottom: 8px;">$${item.file.name}</div>
                            <div style="font-size: 1.1em; margin-bottom: 5px;">$${emoji} $${prediction}</div>
                            <div style="margin-bottom: 8px;">Confidence: $${confidencePercent}%</div>
                            <div class="confidence-bar">
                                <div class="confidence-fill $${confidenceClass}" style="width: $${confidencePercent}%"></div>
                            </div>
                        </div>
                    `;
                } else {
                    cardsHtml += `
                        <div class="result-card" style="border-color: #dc3545;">
                            <img src="$${URL.createObjectURL(item.file)}" alt="$${item.file.name}">
                            <div style="font-weight: bold; margin-bottom: 8px;">$${item.file.name}</div>
                            <div style="color: #dc3545;">❌ Error: $${item.error}</div>
                        </div>
                    `;
                }
            });

            cardsHtml += '</div>';

            const noteHtml = `
                <div style="font-size: 0.9em; margin-top: 20px; text-align: center; color: #666;">
                    <strong>Note:</strong> These are AI predictions for research purposes only.
                    Always consult with medical professionals for actual diagnosis.
                </div>
            `;

            resultArea.className = 'result-area result-success';
            resultArea.innerHTML = summaryHtml + cardsHtml + noteHtml;
            resultArea.style.display = 'block';
        }

        function showError(message) {
            resultArea.className = 'result-area result-error';
            resultArea.innerHTML = `
                <div class="prediction">❌ Error</div>
                <div>$${message}</div>
            `;
            resultArea.style.display = 'block';
        }

        function hideResult() {
            resultArea.style.display = 'none';
        }

        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            console.log('Medical Image Classification UI loaded');

            // Check if API endpoint is configured
            if (API_ENDPOINT.includes('your-api-gateway-url') || API_ENDPOINT.includes('$${api_url}')) {
                showError('API endpoint not configured. Please update the API_ENDPOINT variable in the script.');
            }
        });
    </script>
</body>
</html>
