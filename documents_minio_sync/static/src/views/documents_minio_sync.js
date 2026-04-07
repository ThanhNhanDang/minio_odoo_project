/** @odoo-module **/

import { patch } from "@web/core/utils/patch";
import { DocumentsKanbanController } from "@documents/views/kanban/documents_kanban_controller";
import { DocumentsListController } from "@documents/views/list/documents_list_controller";
import { _t } from "@web/core/l10n/translation";
import { useService } from "@web/core/utils/hooks";
import { MinioBrowserDialog } from "./minio_browser";
import { MinioLoginDialog } from "./minio_login_dialog";
import { useState, onMounted } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { browser } from "@web/core/browser/browser";

// Register Client Action for Preview
registry.category("actions").add("documents_minio_sync.preview", (env, action) => {
    const resId = action.context.active_id || (action.params && action.params.resId);
    if (resId) {
        env.bus.trigger("MINIO_DOC_PREVIEW", { resId });
    }
});

const minioSyncMethods = {
    _addTask(name) {
        const id = Date.now();
        const externalId = (typeof crypto !== 'undefined' && crypto.randomUUID) ? crypto.randomUUID() : id.toString();
        this.minioState.tasks.unshift({
            id,
            externalId,
            name,
            status: 'running',
            info: _t('Starting...')
        });
        return id;
    },

    onClickRemoveTask(taskId) {
        this.minioState.tasks = this.minioState.tasks.filter(t => t.id !== taskId);
    },

    onClickClearCompletedTasks() {
        this.clearCompletedTasks();
    },

    async _refreshAfterSync() {
        await this.model.load();
        // Reload folder tree in the search panel so newly created folders appear
        const searchModel = this.env.searchModel;
        const folderSections = searchModel.getSections(
            (s) => s.type === 'category' && s.fieldName === 'folder_id'
        );
        if (folderSections.length) {
            await searchModel._fetchSections(folderSections, []);
        }
        await searchModel._notify();
        this.model.notify();
    },

    async onClickMinioPickFile() {
        return this._triggerMinioSync('file');
    },

    async onClickMinioPickFolder() {
        return this._triggerMinioSync('folder');
    },

    async onMinioFileSelected(ev) {
        const files = ev.target.files;
        if (!files || files.length === 0) return;
        const paths = Array.from(files).map(f => f.path).filter(Boolean);
        if (paths.length > 0) {
            await this._handleNativePathUpload(paths, 'file');
        } else {
            console.warn("No paths found in input files. Are you in browser?");
            // Fallback to legacy stream upload? No, we refactored backend.
            // We must inform user.
            this.notification.add(_t("Cannot access file paths. This feature requires the Desktop/Electron app."), { type: 'danger' });
        }
        ev.target.value = ""; // Reset
    },

    async onMinioFolderSelected(ev) {
        const files = ev.target.files;
        if (!files || files.length === 0) return;
        const paths = Array.from(files).map(f => f.path).filter(Boolean);
        // Note: For folder upload via input, we get ALL files recursively.
        // We can just send this list of paths!
        if (paths.length > 0) {
            // For folder, we might want to infer the root folder name from the first file?
            // files[0].webkitRelativePath -> "Folder/Sub/File". Root is "Folder".
            // We can pass that if needed, or backend preserves relative path.
            await this._handleNativePathUpload(paths, 'folder');
        }
        ev.target.value = ""; // Reset
    },

    async _handleNativePathUpload(paths, type, folderNameHint = null) {
        const folder = this.env.searchModel.getSelectedFolder();
        if (!folder || !folder.id) {
            this.notification.add(_t("Please select a workspace first."), { type: 'warning' });
            return;
        }

        const taskName = type === 'folder' ? _t("Upload Folder (Native)") : _t("Upload File (Native)");
        const uiTaskId = this._addTask(taskName);
        const task = this.minioState.tasks.find(t => t.id === uiTaskId);
        const externalId = task ? task.externalId : null;

        try {
            this._updateTask(uiTaskId, { info: _t("Sending paths to service..."), percent: 0, localControlled: true });
            const remotePath = this._getFolderPath(folder);

            // Create AbortController for this task
            const controller = new AbortController();
            if (externalId) {
                this.uploadControllers.set(externalId, controller);
            }

            // Call the new path-based upload method
            const result = await this.minioService.uploadStream(
                paths,
                remotePath,
                null,
                (percent) => {
                    this._updateTask(uiTaskId, { percent: percent, info: _t("Uploading %s%", percent) });
                },
                controller.signal
            );

            // Success - cleanup controller
            if (externalId) this.uploadControllers.delete(externalId);

            if (result.success) {
                this._updateTask(uiTaskId, { status: 'success', info: _t("Upload complete"), percent: 100 });
                // Trigger import
                if (type === 'folder') {
                    // Import logic:
                    // If we uploaded a folder, result.remote_path is the prefix.
                    // We need to import the folder created.
                    // If we passed paths, we need to know the "Root" folder name.
                    // If using showDirectoryPicker, we have folderNameHint.
                    // If using input, we can guess from paths (common prefix?).

                    let importPath = result.remote_path || remotePath;
                    let subFolder = folderNameHint;

                    if (!subFolder && paths.length > 0) {
                        // Guess from first path?
                        // If path is C:/A/B/File.txt and we upload C:/A/B
                        // Backend logic uploads "B/File.txt".
                        // So we want to import "B".
                        // Hard to guess "B" from absolute path "C:/A/B/File.txt" without knowing we picked "B".
                        // But typically users pick the folder name.
                        // Let's rely on backend returning "paths" (uploaded paths).
                        // result.paths -> ["Prefix/Folder/File.txt"]
                        if (result.paths && result.paths.length > 0) {
                            const firstRemote = result.paths[0]; // "Prefix/Folder/File"
                            // Remove prefix
                            const rel = firstRemote.substring((result.remote_path ? result.remote_path.length : 0)).replace(/^\//, '');
                            // "Folder/File"
                            subFolder = rel.split('/')[0];
                        }
                    }

                    if (subFolder) {
                        importPath = `${importPath}/${subFolder}`.replace(/\/+/g, '/').replace(/\/$/, '');
                    }
                    await this._importFromMinioPath(importPath, folder.id);
                } else {
                    for (const path of result.paths) {
                        // path is full remote path
                        await this._importSingleFile(path, folder.id);
                    }
                }
                await this._refreshAfterSync();
            } else {
                this._updateTask(uiTaskId, { status: 'failed', info: result.error || _t("Upload failed") });
            }
        } catch (error) {
            // Cleanup controller on error
            if (externalId) this.uploadControllers.delete(externalId);

            if (error.auth_required) {
                this._updateTask(uiTaskId, { status: 'failed', info: _t("Authentication required") });
                this.dialogService.add(MinioLoginDialog, {
                    onLoginSuccess: () => {
                        this.notification.add(_t("Authentication successful. Please retry your upload."), { type: 'success' });
                    }
                });
                return;
            }

            if (error.name === 'AbortError') {
                this._updateTask(uiTaskId, { status: 'cancelled', info: _t("Cancelled by user") });
            } else {
                this._updateTask(uiTaskId, { status: 'failed', info: error.message || _t("Upload error") });
            }
        }
    },

    onClickBrowseMinIO() {
        return this._openMinioBrowser();
    },

    async onClickCancelTask(externalId) {
        if (!externalId) return;

        // Check if we have a local controller (Local Upload)
        if (this.uploadControllers && this.uploadControllers.has(externalId)) {
            try {
                this.uploadControllers.get(externalId).abort();
                this.uploadControllers.delete(externalId);
                this.notification.add(_t("Upload cancelled locally."), { type: 'info' });

                // Manually update task status since the abort handler in _handleNativePickUpload might catch it
                // but we want immediate feedback
                const task = this.minioState.tasks.find(t => t.externalId === externalId);
                if (task) {
                    Object.assign(task, { status: 'cancelled', info: _t("Cancelled") });
                }
            } catch (e) {
                console.warn("Error aborting local upload:", e);
            }
            return; // Don't call backend if it was a local upload
        }

        try {
            // Always tell backend to cleanup too (in case it started)
            await this.notification.add(_t("Cancelling task..."));
            await this.minioService.cancelTask(externalId);
            this._checkPendingTasks();
        } catch (error) {
            console.error("Cancel task error:", error);
        }
    },

    async onClickMinioSyncToLocal() {
        const selectedRecords = (this.model.root && this.model.root.selection) || [];
        if (selectedRecords.length === 0) {
            this.notification.add(_t("No items selected."), { type: 'warning' });
            return;
        }

        const paths = selectedRecords
            .filter(r => r.data.minio_object_name)
            .map(r => r.data.minio_object_name);

        if (paths.length === 0) {
            this.notification.add(_t("Selected items are not synced with MinIO."), { type: 'warning' });
            return;
        }

        const taskName = paths.length === 1 ? _t("Sync to Local: %s", paths[0].split('/').pop()) : _t("Sync %s items to Local", paths.length);
        const uiTaskId = this._addTask(taskName);

        try {
            const result = await this.minioService.startDownloadTask(paths);
            if (result.success && result.task_id) {
                this._updateTask(uiTaskId, {
                    info: _t("Started download task..."),
                    externalId: result.task_id
                });
                this._checkPendingTasks();
            } else {
                this._updateTask(uiTaskId, { status: 'failed', info: result.message || _t("Failed starting") });
            }
        } catch (error) {
            this._updateTask(uiTaskId, { status: 'failed', info: _t("Service error") });
        }
    },

    _updateTask(id, updates) {
        const task = this.minioState.tasks.find(t => t.id === id);
        if (task) {
            Object.assign(task, updates);
        }
    },

    clearCompletedTasks() {
        this.minioState.tasks = this.minioState.tasks.filter(t => t.status === 'running');
    },

    async _checkPendingTasks() {
        try {
            const tasks = await this.minioService.getTasks();
            if (!tasks || tasks.length === 0) return;

            // Map of current backend tasks
            const activeBackendTaskIds = new Set(tasks.map(t => t.id));

            // Cleanup listeners for finished tasks
            for (const [taskId, closeFunc] of this.uploadControllers.entries()) {
                // If it's a function, it's an SSE closer. If it's AbortController, it's local.
                if (typeof closeFunc === 'function') {
                    // Check if task is still active in backend
                    if (!activeBackendTaskIds.has(taskId)) {
                        closeFunc(); // Close SSE
                        this.uploadControllers.delete(taskId);
                    }
                }
            }

            for (const task of tasks) {
                // Find or create UI task
                let uiTask = this.minioState.tasks.find(t => t.externalId === task.id);
                let uiTaskId = uiTask?.id;

                // Skip local controlled tasks (managed by uploadStream callback)
                if (uiTask && uiTask.localControlled) continue;

                if (!uiTaskId) {
                    const taskName = task.task_name || (task.type === 'folder' ? _t("Upload Folder") : _t("Upload File"));
                    uiTaskId = this._addTask(taskName);
                    // Get reference to the new task
                    uiTask = this.minioState.tasks.find(t => t.id === uiTaskId);
                    uiTask.externalId = task.id;
                    uiTask.info = task.message || _t("Syncing...");
                }

                // Attach SSE Listener if running and not listening yet
                if (task.status === 'running' && !this.uploadControllers.has(task.id)) {
                    console.log(`[Frontend] Attaching SSE for task ${task.id}`);
                    const closeSSE = this.minioService.listenToTaskProgress(task.id, (percent) => {
                        this._updateTask(uiTaskId, { percent: percent, info: _t("Uploading %s%", percent) });
                    });
                    this.uploadControllers.set(task.id, closeSSE);
                }

                const uiTaskDetails = {};

                if (task.status === 'running') {
                    if (task.percent) {
                        uiTaskDetails.info = `Running ${task.percent}%`;
                        uiTaskDetails.percent = task.percent; // Sync backend progress for other tasks
                    } else {
                        uiTaskDetails.info = task.message || _t("Running...");
                    }
                } else if (task.status === 'success') {
                    uiTaskDetails.status = 'success';
                    uiTaskDetails.info = _t("Finalizing...");
                    uiTaskDetails.percent = 100;
                    this._updateTask(uiTaskId, uiTaskDetails);

                    // Close listener
                    if (this.uploadControllers.has(task.id)) {
                        const closer = this.uploadControllers.get(task.id);
                        if (typeof closer === 'function') closer();
                        this.uploadControllers.delete(task.id);
                    }

                    // Create documents in Odoo for each uploaded file.
                    // JS has a valid Odoo session (it runs inside Odoo), so this always works.
                    const folderId = task.odoo_folder_id;
                    const uploadedPaths = task.uploaded_paths || [];

                    if (uploadedPaths.length > 0 && folderId) {
                        if (task.type === 'folder') {
                            // Folder upload: create subfolder hierarchy then documents
                            for (const objPath of uploadedPaths) {
                                try {
                                    const targetFolderId = await this._getOrCreateSubfoldersFromPath(objPath, folderId);
                                    await this._importSingleFile(objPath, targetFolderId);
                                } catch (err) {
                                    console.error("Import error for", objPath, err);
                                }
                            }
                        } else {
                            for (const objPath of uploadedPaths) {
                                try {
                                    await this._importSingleFile(objPath, folderId);
                                } catch (err) {
                                    console.error("Import error for", objPath, err);
                                }
                            }
                        }
                        this.notification.add(
                            _t("Uploaded %s file(s)", uploadedPaths.length),
                            { type: 'success' }
                        );
                    } else if (uploadedPaths.length > 0) {
                        // No folder ID — just notify, files are on MinIO
                        this.notification.add(
                            _t("Uploaded %s file(s) to MinIO (no folder selected)", uploadedPaths.length),
                            { type: 'warning' }
                        );
                    } else {
                        this.notification.add(_t("Upload complete"), { type: 'success' });
                    }

                    await this.minioService.deleteTask(task.id);

                    await this._refreshAfterSync();

                    uiTaskDetails.info = _t("Completed");
                } else if (task.status === 'failed' || task.status === 'cancelled') {
                    uiTaskDetails.status = 'failed';
                    uiTaskDetails.info = task.message || _t("Failed");

                    // Close listener
                    if (this.uploadControllers.has(task.id)) {
                        const closer = this.uploadControllers.get(task.id);
                        if (typeof closer === 'function') closer();
                        this.uploadControllers.delete(task.id);
                    }

                    await this.minioService.deleteTask(task.id);
                }

                this._updateTask(uiTaskId, uiTaskDetails);
            }
        } catch (error) {
            // Silent catch/log
            console.warn("Check pending tasks error:", error);
        }
    },

    async _triggerMinioSync(type) {
        const folder = this.env.searchModel.getSelectedFolder();
        if (!folder || !folder.id || folder.id === 'TRASH') {
            this.notification.add(_t("Please select a workspace first."), { type: 'warning' });
            return;
        }

        const taskName = type === 'folder' ? _t("Upload Folder") : _t("Upload File");
        const uiTaskId = this._addTask(taskName);
        this._updateTask(uiTaskId, { info: _t("Contacting service...") });

        try {
            const folderId = parseInt(folder.id);
            const extras = {
                odoo_folder_id: folderId,
                task_name: taskName
            };

            const result = await this.minioService.pickAndSync(type, this._getFolderPath(folder), extras);

            if (result.success && result.task_id) {
                // Async mode started
                this._updateTask(uiTaskId, {
                    info: _t("Started background task..."),
                    externalId: result.task_id
                });

                this._checkPendingTasks();

            } else if (result.success) {
                this._updateTask(uiTaskId, { status: "success", info: _t("Done (Sync)") });
            } else {
                this._updateTask(uiTaskId, { status: 'failed', info: result.message || _t("Failed starting") });
            }
        } catch (error) {
            if (error.auth_required) {
                this._updateTask(uiTaskId, { status: 'failed', info: _t("Authentication required") });
                this.dialogService.add(MinioLoginDialog, {
                    onLoginSuccess: () => {
                        this.notification.add(_t("Authentication successful. Please retry."), { type: 'success' });
                    }
                });
                return;
            }
            console.error("Sync Start Error:", error);
            this._updateTask(uiTaskId, { status: 'failed', info: _t("Service error") });
            this.notification.add(_t("Could not connect to MinIO service."), {
                type: 'danger',
                sticky: true
            });
        }
    },

    async _getOrCreateSubfoldersFromPath(objPath, baseFolderId) {
        // objPath e.g. "Internal/Screenshots/file.png"
        // baseFolderId is the Odoo folder (e.g. Internal)
        // We need to create "Screenshots" under baseFolderId
        // The remote_path prefix (e.g. "Internal") was already the target,
        // so subfolders are the parts between remote_path prefix and filename.
        const parts = objPath.split('/').filter(Boolean);
        if (parts.length <= 1) return baseFolderId;

        // Skip the first part (remote prefix = folder name) and last part (filename)
        // e.g. ["Internal", "Screenshots", "file.png"] → subfolders = ["Screenshots"]
        const subfolderParts = parts.slice(1, -1);
        if (subfolderParts.length === 0) return baseFolderId;

        let currentParentId = baseFolderId;
        for (const folderName of subfolderParts) {
            currentParentId = await this._getOrCreateOdooFolder(folderName, currentParentId);
        }
        return currentParentId;
    },

    async _importSingleFile(path, odooFolderId) {
        try {
            // Extract file name from path
            const fileName = path.split('/').filter(Boolean).pop();
            const cleanPath = path.replace(/^\/+/, '');

            // Check if file already exists in Odoo
            const existing = await this.orm.search("documents.document", [
                ['minio_object_name', '=', cleanPath],
                ['folder_id', '=', odooFolderId]
            ], { limit: 1 });

            if (existing.length === 0) {
                // Get download URL from MinIO
                const downloadUrl = await this.minioService.getDownloadUrl(cleanPath);
                // Create new document record
                const [newDocId] = await this.orm.create("documents.document", [{
                    name: fileName,
                    folder_id: odooFolderId,
                    type: 'url',
                    url: downloadUrl,
                    minio_object_name: cleanPath,
                    minio_synced: true,
                    minio_last_sync: new Date().toISOString().slice(0, 19).replace('T', ' '),
                }]);
                return newDocId;
            } else {
                // Update existing record with latest URL and sync time
                const downloadUrl = await this.minioService.getDownloadUrl(cleanPath);
                await this.orm.write("documents.document", existing, {
                    url: downloadUrl,
                    minio_last_sync: new Date().toISOString().slice(0, 19).replace('T', ' '),
                });
                return existing[0];
            }
        } catch (error) {
            console.error("Single file import failed:", error);
            this.notification.add(_t("Failed to import file to Odoo: %s", error.message || "Unknown error"), { type: 'danger' });
            return null;
        }
    },

    _openMinioBrowser() {
        const folder = this.env.searchModel.getSelectedFolder();
        if (!folder || !folder.id || folder.id === 'TRASH') {
            this.notification.add(_t("Please select a workspace first."), { type: 'warning' });
            return;
        }

        this.dialogService.add(MinioBrowserDialog, {
            folderId: folder.id,
            onImport: async () => {
                await this._refreshAfterSync();
            }
        });
    },

    _getFolderPath(folder) {
        const folderSection = this.env.searchModel.getSections((s) => s.type === "category" && s.fieldName === "folder_id")[0];
        if (!folderSection) return folder.display_name;
        const path = [];
        let current = folder;
        while (current && current.id !== 'TRASH') {
            path.unshift(current.display_name);
            if (current.parentId && folderSection.values.has(current.parentId)) {
                current = folderSection.values.get(current.parentId);
            } else {
                current = null;
            }
        }
        return path.join('/');
    },

    async _importFromMinioPath(path, odooParentFolderId, isRoot = true) {
        let stats = { files: 0, folders: 0 };
        try {
            const folderName = path.split('/').filter(Boolean).pop();
            const odooFolderId = await this._getOrCreateOdooFolder(folderName, odooParentFolderId);
            stats.folders++;

            const items = await this.minioService.listObjects(path);
            const minioPaths = new Set(items.map(i => i.path));

            // Cleanup: remove Odoo documents that are no longer in MinIO
            const existingDocs = await this.orm.searchRead("documents.document", [
                ['folder_id', '=', odooFolderId],
                ['minio_object_name', '!=', false]
            ], ['minio_object_name']);

            for (const doc of existingDocs) {
                if (!minioPaths.has(doc.minio_object_name)) {
                    await this.orm.unlink("documents.document", [doc.id]);
                }
            }

            for (const item of items) {
                if (item.type === 'folder') {
                    const subStats = await this._importFromMinioPath(item.path, odooFolderId, false);
                    stats.files += subStats.files;
                    stats.folders += subStats.folders;
                } else {
                    const downloadUrl = await this.minioService.getDownloadUrl(item.path);
                    const existing = await this.orm.search("documents.document", [
                        ['minio_object_name', '=', item.path],
                        ['folder_id', '=', odooFolderId]
                    ], { limit: 1 });

                    if (existing.length === 0) {
                        await this.orm.create("documents.document", [{
                            name: item.name,
                            folder_id: odooFolderId,
                            type: 'url',
                            url: downloadUrl,
                            minio_object_name: item.path,
                            minio_synced: true,
                            minio_last_sync: new Date().toISOString().slice(0, 19).replace('T', ' '),
                        }]);
                        stats.files++;
                    }
                }
            }
            if (isRoot && (stats.files > 0 || stats.folders > 0)) {
                this.notification.add(_t("Integrated %s file(s) and %s folder(s) from MinIO at %s", stats.files, stats.folders, folderName), { type: 'success' });
            }
        } catch (e) {
            console.error("Auto-import failed:", e);
        }
        return stats;
    },

    async _getOrCreateOdooFolder(name, parentId) {
        // Ensure parentId is a single integer if it's an array
        const pId = (Array.isArray(parentId) ? parentId[0] : parentId) || false;

        const existing = await this.orm.search("documents.folder", [
            ['name', '=', name],
            ['parent_folder_id', '=', pId]
        ], { limit: 1 });

        if (existing.length > 0) {
            return existing[0];
        } else {
            const results = await this.orm.create("documents.folder", [{
                name: name,
                parent_folder_id: pId
            }]);
            return results[0];
        }
    }
};


const mixinSetup = function () {
    this.minioService = useService("minio_service");
    this.notification = useService("notification");
    this.dialogService = useService("dialog");
    this.ui = useService("ui");
    this.ui = useService("ui");

    // Load persisted tasks
    let initialTasks = [];
    try {
        const saved = browser.localStorage.getItem('minio_odoo_tasks');
        if (saved) {
            initialTasks = JSON.parse(saved).map(t => {
                // Mark client-side running tasks as interrupted
                if (t.status === 'running' && !t.externalId) {
                    return { ...t, status: 'failed', info: _t("Interrupted by reload") };
                }
                return t;
            });
        }
    } catch (e) {
        console.warn("Failed to load tasks:", e);
    }

    this.minioState = useState({ tasks: initialTasks });

    // Helper to save tasks (available on the component)
    this._saveTasks = () => {
        try {
            browser.localStorage.setItem('minio_odoo_tasks', JSON.stringify(this.minioState.tasks));
        } catch (e) {
            console.error("Failed to save tasks:", e);
        }
    };

    // Bind new handlers
    this.onMinioFileSelected = this.onMinioFileSelected.bind(this);
    this.onMinioFolderSelected = this.onMinioFolderSelected.bind(this);

    // Setup interval for polling
    const intervalId = setInterval(() => this._checkPendingTasks(), 3000);
    // Initial check
    this._checkPendingTasks();

    // Global Preview Handler (triggered by Client Action)
    const onGlobalPreview = (ev) => {
        const { resId } = ev.detail;
        const record = (this.model.root.records || []).find(r => r.resId === resId);
        if (record) {
            this.env.documentsView.bus.trigger("documents-open-preview", {
                documents: [record],
                mainDocument: record,
            });
        }
    };
    this.env.bus.addEventListener("MINIO_DOC_PREVIEW", onGlobalPreview);

    // Unified Cleanup
    const { onWillDestroy } = owl;
    onWillDestroy(() => {
        clearInterval(intervalId);
        this.env.bus.removeEventListener("MINIO_DOC_PREVIEW", onGlobalPreview);
    });

    this.onClickClearCompletedTasks = this.onClickClearCompletedTasks.bind(this);
    this.onClickRemoveTask = this.onClickRemoveTask.bind(this);
    this.onClickMinioPickFile = this.onClickMinioPickFile.bind(this);
    this.onClickMinioPickFolder = this.onClickMinioPickFolder.bind(this);
    this.onClickBrowseMinIO = this.onClickBrowseMinIO.bind(this);
    this.onClickMinioSyncToLocal = this.onClickMinioSyncToLocal.bind(this);
    this.onClickCancelTask = this.onClickCancelTask.bind(this);

    // Initialize map for abort controllers
    this.uploadControllers = new Map();
};

patch(DocumentsKanbanController.prototype, {
    setup() {
        super.setup();
        mixinSetup.call(this);
    },
    ...minioSyncMethods
});

patch(DocumentsListController.prototype, {
    setup() {
        super.setup();
        mixinSetup.call(this);
    },
    ...minioSyncMethods
});
