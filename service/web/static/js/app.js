// --- Global Helpers ---
function showNotify(message, type = 'primary') {
    const toastEl = document.getElementById('liveToast');
    const toastTitle = document.getElementById('toast-title');
    const toastMsg = document.getElementById('toast-message');
    const toastIcon = document.getElementById('toast-icon');

    toastMsg.textContent = message;

    toastEl.classList.remove('text-bg-primary', 'text-bg-success', 'text-bg-danger', 'text-bg-warning', 'text-bg-info');
    if (type === 'success') {
        toastEl.classList.add('text-bg-success');
        toastIcon.className = 'fas fa-check-circle me-2';
        toastTitle.textContent = 'Success';
    } else if (type === 'error' || type === 'danger') {
        toastEl.classList.add('text-bg-danger');
        toastIcon.className = 'fas fa-exclamation-circle me-2';
        toastTitle.textContent = 'Error';
    } else if (type === 'warning') {
        toastEl.classList.add('text-bg-warning');
        toastIcon.className = 'fas fa-exclamation-triangle me-2';
        toastTitle.textContent = 'Warning';
    } else {
        toastEl.classList.add('text-bg-primary');
        toastIcon.className = 'fas fa-info-circle me-2';
        toastTitle.textContent = 'Notification';
    }

    const toast = new bootstrap.Toast(toastEl, { delay: 3000 });
    toast.show();
}

function formatSize(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function getFileIcon(name) {
    const ext = name.split('.').pop().toLowerCase();
    const icons = {
        'pdf': 'fa-file-pdf text-danger',
        'doc': 'fa-file-word text-primary',
        'docx': 'fa-file-word text-primary',
        'xls': 'fa-file-excel text-success',
        'xlsx': 'fa-file-excel text-success',
        'jpg': 'fa-file-image text-info',
        'png': 'fa-file-image text-info',
        'zip': 'fa-file-archive text-warning',
        'rar': 'fa-file-archive text-warning',
        'txt': 'fa-file-alt text-secondary'
    };
    return icons[ext] || 'fa-file text-secondary';
}

function escapeHtml(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeJsString(str) {
    if (!str) return '';
    return str.replace(/\\/g, '\\\\')
        .replace(/'/g, '\\u0027')
        .replace(/"/g, '\\u0022')
        .replace(/\n/g, '\\n')
        .replace(/\r/g, '\\r');
}

let currentPath = '';
let platformInfo = null;

// --- Init ---
document.addEventListener('DOMContentLoaded', () => {
    try {
        initResizableSidebar();
    } catch (e) { console.error("Sidebar init failed", e); }

    const savedPath = localStorage.getItem('currentPath') || '';
    currentPath = savedPath;

    loadBucketInfo();
    loadSystemStatus();
    loadTree(false).catch(e => console.error("Initial tree load failed", e));
    loadPath(savedPath).catch(e => console.error("Initial path load failed", e));

    setupAutoRefresh();
});

// --- Mobile Sidebar ---
function toggleSidebar() {
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebar-overlay');
    sidebar.classList.toggle('show');
    overlay.classList.toggle('show');
    overlay.classList.toggle('d-none');
}

function initResizableSidebar() {
    const sidebar = document.getElementById('sidebar');
    const resizer = document.getElementById('resizer');
    if (!sidebar || !resizer) return;

    let isResizing = false;
    resizer.addEventListener('mousedown', (e) => {
        isResizing = true;
        document.body.style.cursor = 'col-resize';
        resizer.classList.add('resizing');
    });

    document.addEventListener('mousemove', (e) => {
        if (!isResizing) return;
        const offsetLeft = sidebar.getBoundingClientRect().left;
        const newWidth = e.clientX - offsetLeft;
        if (newWidth > 150 && newWidth < 800) {
            sidebar.style.width = newWidth + 'px';
        }
    });

    document.addEventListener('mouseup', () => {
        if (isResizing) {
            isResizing = false;
            document.body.style.cursor = 'default';
            resizer.classList.remove('resizing');
        }
    });
}

async function loadBucketInfo() {
    try {
        const res = await fetch(`${window.API_BASE_URL}/api/bucket`);
        if (!res.ok) return;
        const data = await res.json();
        if (data.bucket) document.getElementById('bucket-name').textContent = data.bucket;
    } catch (e) {
        console.error("Failed to load bucket info", e);
    }
}

async function loadSystemStatus() {
    try {
        const res = await fetch(`${window.API_BASE_URL}/api/system/status`);
        const data = await res.json();
        platformInfo = data;

        // Show version in footer
        const versionEl = document.getElementById('app-version');
        if (versionEl && data.version) {
            versionEl.textContent = 'v' + data.version;
        }

        // On Android, hide Pick File/Folder buttons (use browser upload instead)
        if (data.platform === 'android') {
            const pickFile = document.getElementById('btn-pick-file');
            const pickFolder = document.getElementById('btn-pick-folder');
            if (pickFile) pickFile.style.display = 'none';
            if (pickFolder) pickFolder.style.display = 'none';
        }
    } catch (e) {
        console.error("Failed to load system status", e);
    }
}

// --- Navigation ---
async function loadPath(path, silent = false) {
    const isNewPath = currentPath !== path;
    currentPath = path;
    localStorage.setItem('currentPath', path);
    updateBreadcrumb(path);
    highlightActiveTreeItem();

    const listEl = document.getElementById('file-list');

    if (isNewPath || !silent) {
        listEl.innerHTML = '<tr><td colspan="6" class="text-center"><i class="fas fa-spinner fa-spin"></i> Loading...</td></tr>';
    }

    try {
        const res = await fetch(`${window.API_BASE_URL}/api/list?path=${encodeURIComponent(path)}`);
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.error || `HTTP ${res.status}`);
        }
        const data = await res.json();
        const items = Array.isArray(data) ? data : [];

        const currentRows = listEl.querySelectorAll('tr').length;
        const hasSpinner = listEl.querySelector('.fa-spinner');
        const isEmptyView = listEl.querySelector('.empty-folder-row');

        if (isNewPath || hasSpinner || currentRows !== items.length || (items.length > 0 && isEmptyView)) {
            renderFiles(items);
        }
    } catch (e) {
        if (!silent) {
            listEl.innerHTML = `<tr><td colspan="6" class="text-danger">Error loading files: ${e.message}</td></tr>`;
        }
    }
}

function updateBreadcrumb(path) {
    const parts = path.split('/').filter(p => p);
    const ol = document.getElementById('breadcrumb');
    let html = '<li class="breadcrumb-item"><a href="#" onclick="loadPath(\'\')">Root</a></li>';

    let buildPath = '';
    parts.forEach((part, index) => {
        buildPath += (buildPath ? '/' : '') + part;
        const escapedPath = escapeJsString(buildPath);
        if (index === parts.length - 1) {
            html += `<li class="breadcrumb-item active">${part}</li>`;
        } else {
            html += `<li class="breadcrumb-item"><a href="#" onclick="loadPath('${escapedPath}')">${part}</a></li>`;
        }
    });
    ol.innerHTML = html;
}

function renderFiles(items) {
    const tbody = document.getElementById('file-list');
    tbody.innerHTML = '';

    if (items.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="text-center text-muted empty-folder-row">Empty folder</td></tr>';
        document.getElementById('select-all').checked = false;
        document.getElementById('select-all').disabled = true;
        return;
    }

    document.getElementById('select-all').disabled = false;
    document.getElementById('select-all').checked = false;
    document.getElementById('btn-bulk-download').disabled = true;

    items.sort((a, b) => (b.type === 'folder') - (a.type === 'folder'));
    items.forEach(item => {
        const row = document.createElement('tr');
        const icon = item.type === 'folder' ? 'fa-folder text-warning' : getFileIcon(item.name);
        const size = item.type === 'folder' ? '-' : formatSize(item.size);
        const date = item.lastModified ? new Date(item.lastModified).toLocaleString() : '-';

        const escapedPath = escapeJsString(item.path);
        const escapedName = escapeJsString(item.name);

        const clickHandler = item.type === 'folder'
            ? `loadPath('${escapedPath}')`
            : `previewFile('${escapedPath}', '${escapedName}')`;

        const isFolder = item.type === 'folder';
        const deleteAction = `deleteItem('${escapedPath}', ${isFolder})`;

        let actionsHtml = `<div class="btn-group btn-group-sm">`;
        if (isFolder) {
            actionsHtml += `<button class="btn btn-light text-primary" onclick="downloadFolder('${escapedPath}')" title="Download Folder"><i class="fas fa-download"></i></button>`;
        } else {
            actionsHtml += `<button class="btn btn-light" onclick="previewFile('${escapedPath}', '${escapedName}')" title="Preview"><i class="fas fa-eye"></i></button>`;
        }
        actionsHtml += `<button class="btn btn-light text-danger" onclick="${deleteAction}" title="Delete"><i class="fas fa-trash-alt"></i></button></div>`;

        row.innerHTML = `
            <td class="text-center">
                <input type="checkbox" class="form-check-input file-checkbox" data-path="${escapedPath}" value="${escapedPath}" onchange="checkSelection()">
            </td>
            <td onclick="${clickHandler}"><i class="fas ${icon} fa-lg"></i></td>
            <td onclick="${clickHandler}" class="${item.type}-item text-truncate" style="max-width: 300px;">${item.name}</td>
            <td class="d-none d-md-table-cell">${size}</td>
            <td class="d-none d-md-table-cell">${date}</td>
            <td>${actionsHtml}</td>
        `;
        tbody.appendChild(row);
    });
}

// --- Bulk Actions ---
function toggleSelectAll() {
    const master = document.getElementById('select-all');
    const checkboxes = document.querySelectorAll('.file-checkbox');
    checkboxes.forEach(cb => cb.checked = master.checked);
    checkSelection();
}

function checkSelection() {
    const checkboxes = document.querySelectorAll('.file-checkbox:checked');
    const btn = document.getElementById('btn-bulk-download');
    btn.disabled = checkboxes.length === 0;

    const all = document.querySelectorAll('.file-checkbox');
    const master = document.getElementById('select-all');
    if (checkboxes.length > 0 && checkboxes.length < all.length) {
        master.indeterminate = true;
    } else {
        master.indeterminate = false;
        master.checked = checkboxes.length > 0 && checkboxes.length === all.length;
    }
}

async function downloadFolder(path) {
    if (!path.endsWith('/')) path += '/';
    const parts = path.replace(/\/$/, '').split('/');
    const name = parts[parts.length - 1] || 'folder';
    const filename = `${name}.zip`;
    await initiateZipDownload([path], filename);
}

function downloadSelected() {
    const checkedBoxes = document.querySelectorAll('.file-checkbox:checked');
    if (checkedBoxes.length === 0) {
        showNotify('Please select items to download', 'warning');
        return;
    }

    const paths = Array.from(checkedBoxes).map(cb => cb.getAttribute('data-path'));
    let filename = 'download.zip';

    if (paths.length === 1) {
        let p = paths[0];
        const cleanPath = p.endsWith('/') ? p.slice(0, -1) : p;
        const parts = cleanPath.split('/');
        const name = parts[parts.length - 1];
        filename = `${name}.zip`;
    } else {
        const now = new Date();
        const pad = (n) => n.toString().padStart(2, '0');
        const timeStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}-${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`;
        filename = `${timeStr}.zip`;
    }

    initiateZipDownload(paths, filename);
}

async function initiateZipDownload(paths, filename = 'download.zip') {
    const btn = document.getElementById('btn-bulk-download');
    const originalText = btn ? btn.innerHTML : '';
    if (btn) {
        btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Zipping...';
        btn.disabled = true;
    }

    showNotify('Requesting zip download...', 'info');

    try {
        const res = await fetch(`${window.API_BASE_URL}/api/download_zip`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ paths: paths })
        });

        if (res.ok) {
            const blob = await res.blob();
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = filename;
            document.body.appendChild(a);
            a.click();
            a.remove();
            showNotify(`Download started: ${filename}`, 'success');
        } else {
            const err = await res.json();
            showNotify('Download failed: ' + (err.error || res.statusText), 'error');
        }
    } catch (e) {
        showNotify('Download error: ' + e.message, 'error');
    } finally {
        if (btn) {
            btn.innerHTML = originalText;
            checkSelection();
        }
    }
}

// --- Tree View ---
async function loadTree(silent = true) {
    const root = document.getElementById('tree-root');
    if (!silent) root.innerHTML = '<div class="text-center text-muted"><i class="fas fa-spinner fa-spin"></i> Loading tree...</div>';

    try {
        const res = await fetch(`${window.API_BASE_URL}/api/tree`);
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.error || `HTTP ${res.status}`);
        }
        const data = await res.json();
        const tree = Array.isArray(data.tree) ? data.tree : [];

        let html = `<div class="tree-item ${currentPath === '' ? 'active' : ''}" onclick="loadPath('')">
            <span class="tree-toggle ${tree.length > 0 ? 'expanded' : 'empty'}" onclick="event.stopPropagation(); toggleFolder(this, '')"></span>
            <i class="fas fa-home"></i> Root
        </div>`;

        html += renderTreeChildren(tree, '');
        root.innerHTML = html;

        restoreTreeState();
        highlightActiveTreeItem();
        if (currentPath === '' && tree.length > 0) {
            const rootItem = document.querySelector('.tree-item[onclick*="loadPath(\'\')"]');
            if (rootItem) {
                const rootToggle = rootItem.querySelector('.tree-toggle');
                const rootChildren = rootItem.nextElementSibling;
                if (rootToggle && rootChildren && rootChildren.classList.contains('tree-children')) {
                    rootToggle.classList.add('expanded');
                    rootToggle.classList.remove('collapsed');
                    rootChildren.style.display = 'block';
                    saveTreeState('', true);
                }
            }
        }
    } catch (e) {
        root.innerHTML = '<div class="text-danger">Error loading tree</div>';
    }
}

function highlightActiveTreeItem() {
    document.querySelectorAll('.tree-item.active').forEach(el => el.classList.remove('active'));

    let activeItem;
    if (currentPath === '') {
        activeItem = document.querySelector('.tree-item[onclick*="loadPath(\'\')"]');
    } else {
        const allItems = document.querySelectorAll('.tree-item[data-path]');
        for (let item of allItems) {
            if (item.getAttribute('data-path') === currentPath) {
                activeItem = item;
                break;
            }
        }
    }

    if (activeItem) {
        activeItem.classList.add('active');

        const itemToggle = activeItem.querySelector('.tree-toggle');
        const itemChildren = activeItem.nextElementSibling;
        if (itemToggle && itemChildren && itemChildren.classList.contains('tree-children') &&
            !itemToggle.classList.contains('empty')) {
            if (itemToggle.classList.contains('collapsed')) {
                itemToggle.classList.add('expanded');
                itemToggle.classList.remove('collapsed');
                itemChildren.style.display = 'block';
                saveTreeState(currentPath, true);
            }
        }

        let parentContent = activeItem.parentElement;
        while (parentContent && parentContent.classList.contains('tree-children')) {
            parentContent.style.display = 'block';
            const toggleItem = parentContent.previousElementSibling;
            if (toggleItem && toggleItem.classList.contains('tree-item')) {
                const toggle = toggleItem.querySelector('.tree-toggle');
                if (toggle && toggle.classList.contains('collapsed')) {
                    toggle.classList.remove('collapsed');
                    toggle.classList.add('expanded');
                }
            }
            parentContent = toggleItem.parentElement;
        }
    }
}

function renderTreeChildren(children, parentPath, level = 0) {
    if (!children || children.length === 0) return '';
    let html = `<div class="tree-children" data-parent="${parentPath}">`;
    children.forEach(item => {
        const hasChildren = item.children && item.children.length > 0;
        const toggleClass = hasChildren ? 'collapsed' : 'empty';
        const isActive = currentPath === item.path ? 'active' : '';
        const escapedPath = escapeJsString(item.path);

        html += `
            <div class="tree-item ${isActive}" data-path="${item.path}">
                <span class="tree-toggle ${toggleClass}" onclick="event.stopPropagation(); toggleTreeNode(event, '${escapedPath}')"></span>
                <span onclick="loadPath('${escapedPath}')">
                    <i class="fas fa-folder text-warning"></i> ${item.name}
                </span>
            </div>
        `;
        if (hasChildren) html += renderTreeChildren(item.children, item.path, level + 1);
    });
    html += '</div>';
    return html;
}

function toggleTreeNode(event, path) {
    event.stopPropagation();
    const toggle = event.target;
    const treeItem = toggle.closest('.tree-item');
    const children = treeItem.nextElementSibling;

    if (toggle.classList.contains('collapsed')) {
        toggle.classList.remove('collapsed');
        toggle.classList.add('expanded');
        if (children && children.classList.contains('tree-children')) children.style.display = 'block';
        saveTreeState(path, true);
    } else if (toggle.classList.contains('expanded')) {
        toggle.classList.remove('expanded');
        toggle.classList.add('collapsed');
        if (children && children.classList.contains('tree-children')) children.style.display = 'none';
        saveTreeState(path, false);
    }
}

function saveTreeState(path, expanded) {
    const state = JSON.parse(localStorage.getItem('treeState') || '{}');
    state[path] = expanded;
    localStorage.setItem('treeState', JSON.stringify(state));
}

function restoreTreeState() {
    const state = JSON.parse(localStorage.getItem('treeState') || '{}');
    Object.keys(state).forEach(path => {
        const item = document.querySelector(`.tree-item[data-path="${path}"]`);
        if (item && state[path]) {
            const toggle = item.querySelector('.tree-toggle');
            const children = item.nextElementSibling;
            if (toggle && toggle.classList.contains('collapsed')) {
                toggle.classList.remove('collapsed');
                toggle.classList.add('expanded');
                if (children && children.classList.contains('tree-children')) children.style.display = 'block';
            }
        }
    });
}

// --- Actions ---
function triggerUpload() { document.getElementById('file-input').click(); }
function triggerFolderUpload() { document.getElementById('folder-input').click(); }

async function handleFileSelect(input) {
    if (!input.files.length) return;
    const formData = new FormData();
    Array.from(input.files).forEach(file => formData.append('file', file));
    formData.append('path', currentPath);

    const btns = document.querySelectorAll('.btn-primary, .btn-success');
    btns.forEach(b => b.disabled = true);

    try {
        const res = await fetch(`${window.API_BASE_URL}/api/upload`, { method: 'POST', body: formData });
        const result = await res.json();
        if (result.success) {
            showNotify('Upload successful!', 'success');
            await loadTree(true);
            loadPath(currentPath, true);
        } else {
            showNotify('Upload failed: ' + result.error, 'error');
        }
    } catch (e) {
        showNotify('Upload error: ' + e.message, 'error');
    } finally {
        btns.forEach(b => b.disabled = false);
        input.value = '';
    }
}

async function deleteItem(path, isFolder) {
    if (!confirm(`Are you sure you want to delete?\n${path}`)) return;
    try {
        const res = await fetch(`${window.API_BASE_URL}/api/delete`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path, is_folder: isFolder })
        });
        const result = await res.json();
        if (result.success) {
            showNotify('Deleted successfully!', 'success');
            await loadTree(true);
            loadPath(currentPath, true);
        } else {
            showNotify('Delete failed: ' + result.error, 'error');
        }
    } catch (e) {
        showNotify('Delete error: ' + e.message, 'error');
    }
}

async function previewFile(path, name) {
    const modal = new bootstrap.Modal(document.getElementById('previewModal'));
    const content = document.getElementById('preview-content');
    const title = document.getElementById('previewTitle');
    const dlBtn = document.getElementById('download-btn');

    title.textContent = name;
    content.innerHTML = '<div class="text-center"><i class="fas fa-spinner fa-spin fa-3x"></i></div>';
    modal.show();

    try {
        const downloadUrl = `${window.API_BASE_URL}/api/download?path=${encodeURIComponent(path)}`;
        const previewUrl = `${window.API_BASE_URL}/api/download?path=${encodeURIComponent(path)}&preview=true`;

        dlBtn.href = downloadUrl;

        const ext = name.split('.').pop().toLowerCase();

        if (['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(ext)) {
            content.innerHTML = `<img src="${previewUrl}" id="preview-image" class="img-fluid">`;
        } else if (['pdf'].includes(ext)) {
            content.innerHTML = `<iframe src="${previewUrl}" width="100%" height="500px"></iframe>`;
        } else if (['txt', 'log', 'md', 'json', 'py', 'js', 'css', 'html'].includes(ext)) {
            const textRes = await fetch(previewUrl);
            if (textRes.ok) {
                const text = await textRes.text();
                content.innerHTML = `<pre class="bg-light p-3 text-start"><code>${escapeHtml(text)}</code></pre>`;
            } else {
                if (textRes.status === 404) throw new Error("File not found (404)");
                if (textRes.status === 403) throw new Error("Access Denied (403)");
                throw new Error(`Error: ${textRes.status}`);
            }
        } else {
            content.innerHTML = `<div class="text-center py-5"><i class="fas fa-file-alt fa-4x text-secondary"></i><p class="mt-3">This file type is not supported for preview.</p></div>`;
        }
    } catch (e) {
        content.innerHTML = `<p class="text-danger">Error: ${e.message}</p>`;
    }
}

function refreshCurrent() {
    loadTree(true);
    loadPath(currentPath, true);
}

function setupAutoRefresh() {
    setInterval(() => {
        loadPath(currentPath, true);
    }, 30000);

    setInterval(() => {
        loadTree(true);
    }, 30000);
}

// --- Sync Logic ---
async function triggerPickAndSync(type, event) {
    if (event) event.preventDefault();
    const btn = event ? event.currentTarget : null;
    const originalContent = btn ? btn.innerHTML : '';
    if (btn) { btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Picking...'; btn.disabled = true; }

    try {
        const res = await fetch(`${window.API_BASE_URL}/api/pick_sync`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type, current_path: currentPath })
        });
        const result = await res.json();

        if (result.success && result.task_id) {
            showNotify('Selection confirmed. Uploading...', 'info');
            await pollTask(result.task_id, btn, originalContent);
        } else if (result.success) {
            showNotify('Sync successful!', 'success');
            await loadTree(true);
            loadPath(currentPath, true);
            if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
        } else {
            if (result.message && (result.message.includes('Cancelled') || result.message.includes('No path') || result.message.includes('No file'))) {
                // Cancelled or no selection
            } else {
                showNotify('Sync failed: ' + result.message, 'error');
            }
            if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
        }
    } catch (e) {
        showNotify('Error: ' + e.message, 'error');
        if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
    }
}

async function pollTask(taskId, btn, originalContent) {
    const pollInterval = setInterval(async () => {
        try {
            const res = await fetch(`${window.API_BASE_URL}/api/task/${taskId}`);
            if (!res.ok) {
                clearInterval(pollInterval);
                if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
                return;
            }
            const task = await res.json();

            if (task.status === 'success') {
                clearInterval(pollInterval);
                showNotify('Sync successful!', 'success');
                await loadTree(true);
                loadPath(currentPath, true);
                await fetch(`${window.API_BASE_URL}/api/task/${taskId}`, { method: 'DELETE' });
                if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
            } else if (task.status === 'failed' || task.status === 'cancelled') {
                clearInterval(pollInterval);
                if (task.status === 'failed') showNotify('Sync failed: ' + task.message, 'error');
                await fetch(`${window.API_BASE_URL}/api/task/${taskId}`, { method: 'DELETE' });
                if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
            } else {
                if (btn) btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Uploading...';
            }
        } catch (e) {
            console.error("Poll error", e);
            clearInterval(pollInterval);
            if (btn) { btn.innerHTML = originalContent; btn.disabled = false; }
        }
    }, 1000);
}

function openSyncModal() { new bootstrap.Modal(document.getElementById('syncModal')).show(); }

async function triggerSync() {
    const pathInput = document.getElementById('sync-path-input');
    const path = pathInput.value.trim();
    if (!path) { showNotify('Please enter a path!', 'warning'); return; }

    try {
        const modalEl = document.getElementById('syncModal');
        bootstrap.Modal.getInstance(modalEl).hide();

        const res = await fetch(`${window.API_BASE_URL}/api/sync`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path })
        });
        const result = await res.json();
        if (result.success) {
            showNotify('Sync request sent!', 'success');
            pathInput.value = '';
            await loadTree(true);
            loadPath(currentPath, true);
        } else {
            showNotify('Failed: ' + result.message, 'error');
        }
    } catch (e) {
        showNotify('Error: ' + e.message, 'error');
    }
}
