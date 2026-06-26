(function () {
  const form = document.getElementById('apkUploadForm');
  if (!form || !window.fetch || !window.File || !window.Blob) {
    return;
  }

  const panel = document.getElementById('apkReleasePanel');
  const button = document.getElementById('apkUploadButton');
  const progress = document.getElementById('apkUploadProgress');
  const bar = document.getElementById('apkUploadBar');
  const statusText = document.getElementById('apkUploadStatus');
  const percentText = document.getElementById('apkUploadPercent');
  const message = document.getElementById('apkUploadMessage');
  const openLink = document.getElementById('apkOpenLink');
  const urlCode = document.getElementById('apkReleaseUrl');
  const metaBox = document.getElementById('apkReleaseMeta');
  const shaBox = document.getElementById('apkReleaseSha');

  const maxMb = Number(panel && panel.dataset.maxMb ? panel.dataset.maxMb : 500);
  const maxBytes = maxMb * 1024 * 1024;

  let activeUploadId = null;

  function formatBytes(bytes) {
    if (!Number.isFinite(bytes)) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    let value = bytes;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
  }

  function setProgress(ratio, label) {
    const safeRatio = Math.max(0, Math.min(1, ratio || 0));
    const percent = Math.round(safeRatio * 1000) / 10;
    progress.hidden = false;
    bar.style.width = `${percent}%`;
    percentText.textContent = `${percent}%`;
    statusText.textContent = label;
  }

  function showMessage(kind, text) {
    message.className = `release-message ${kind}`;
    message.textContent = text;
    message.hidden = false;
  }

  function clearMessage() {
    message.textContent = '';
    message.hidden = true;
  }

  function setBusy(isBusy) {
    button.disabled = isBusy;
    form.querySelectorAll('input').forEach((input) => {
      input.disabled = isBusy;
    });
  }

  async function parseJson(response) {
    const text = await response.text();
    let payload;
    try {
      payload = text ? JSON.parse(text) : {};
    } catch (_error) {
      throw new Error(response.redirected ? '登录状态可能已过期，请刷新后重新登录' : '服务返回了非 JSON 响应');
    }
    if (!response.ok || payload.ok === false) {
      throw new Error(payload.error || `请求失败：HTTP ${response.status}`);
    }
    return payload;
  }

  async function requestJson(url, options) {
    const response = await fetch(url, {
      credentials: 'same-origin',
      ...options,
    });
    return parseJson(response);
  }

  function updateRelease(metadata) {
    if (!metadata) return;
    if (metadata.url) {
      urlCode.textContent = metadata.url;
      openLink.href = metadata.url;
      openLink.hidden = false;
    }
    metaBox.hidden = false;
    shaBox.hidden = false;
    const fields = {
      version_name: metadata.version_name || '未填写',
      build_number: metadata.build_number || '未填写',
      size: formatBytes(metadata.size || 0),
      uploaded_at_iso: metadata.uploaded_at_iso || '未知',
      sha256: metadata.sha256 || '',
    };
    Object.entries(fields).forEach(([key, value]) => {
      const target = document.querySelector(`[data-apk-field="${key}"]`);
      if (target) target.textContent = value;
    });
  }

  async function abortUpload() {
    if (!activeUploadId) return;
    try {
      await fetch(`/api/admin/apk/uploads/${activeUploadId}`, {
        method: 'DELETE',
        credentials: 'same-origin',
      });
    } catch (_error) {
      // Best-effort cleanup only. The next successful upload is independent.
    }
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    clearMessage();

    const fileInput = form.elements.apk;
    const file = fileInput && fileInput.files ? fileInput.files[0] : null;
    if (!file) {
      showMessage('err', '请选择 APK 文件');
      return;
    }
    if (!file.name.toLowerCase().endsWith('.apk')) {
      showMessage('err', '只允许上传 .apk 文件');
      return;
    }
    if (file.size <= 0) {
      showMessage('err', 'APK 文件为空');
      return;
    }
    if (file.size > maxBytes) {
      showMessage('err', `APK 超过上限 ${maxMb} MB`);
      return;
    }

    setBusy(true);
    activeUploadId = null;
    setProgress(0, `准备上传 ${file.name} (${formatBytes(file.size)})`);

    try {
      const created = await requestJson('/api/admin/apk/uploads', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          filename: file.name,
          size: file.size,
          version_name: form.elements.version_name.value || '',
          build_number: form.elements.build_number.value || '',
          release_notes: form.elements.release_notes.value || '',
        }),
      });

      activeUploadId = created.upload_id;
      const chunkSize = created.chunk_size;
      const totalParts = created.total_parts;
      let uploaded = 0;

      for (let index = 0; index < totalParts; index += 1) {
        const start = index * chunkSize;
        const end = Math.min(file.size, start + chunkSize);
        const chunk = file.slice(start, end);
        setProgress(uploaded / file.size, `上传分片 ${index + 1}/${totalParts}`);
        await requestJson(`/api/admin/apk/uploads/${activeUploadId}/chunks/${index}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/octet-stream' },
          body: chunk,
        });
        uploaded += chunk.size;
        setProgress(uploaded / file.size, `上传分片 ${index + 1}/${totalParts}`);
      }

      setProgress(1, '发布到永久 bucket');
      const completed = await requestJson(`/api/admin/apk/uploads/${activeUploadId}/complete`, {
        method: 'POST',
      });
      updateRelease(completed.metadata);
      showMessage('ok', 'APK 已发布，固定下载链接已更新');
      form.reset();
      activeUploadId = null;
      setProgress(1, '完成');
    } catch (error) {
      await abortUpload();
      showMessage('err', error && error.message ? error.message : '上传失败');
      setProgress(0, '上传失败');
    } finally {
      setBusy(false);
    }
  });
})();
