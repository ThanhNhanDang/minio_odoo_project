/** @odoo-module **/

import { Component, useState } from "@odoo/owl";
import { Dialog } from "@web/core/dialog/dialog";
import { useService } from "@web/core/utils/hooks";
import { _t } from "@web/core/l10n/translation";
import { MinioLoginDialog } from "./minio_login_dialog";

export class MinioBrowserDialog extends Component {
    static template = "documents_minio_sync.MinioBrowserDialog";
    static components = { Dialog };
    static props = {
        folderId: { type: Number },
        close: Function,
        onImport: Function,
    };

    setup() {
        this.notification = useService("notification");
        this.minioService = useService("minio_service");
        this.orm = useService("orm");
        this.dialogService = useService("dialog");

        this.state = useState({
            currentPath: "",
            folders: [],
            files: [],
            selectedItems: {}, // Use object for Owl reactivity
            loading: false,
            uploadProgress: null, // null, or { percent: 0, filename: '' }
            deleteAfterImport: false,
        });

        this.loadPath("");
    }

    // ... (existing methods loadPath, onFolderClick, onItemToggle, goUp) ...

    async onUpload() {
        // Create hidden input
        const input = document.createElement('input');
        input.type = 'file';
        input.multiple = true;

        input.onchange = async (e) => {
            const files = e.target.files;
            if (!files || files.length === 0) return;

            // Generate a task ID for the backend to track this "session"
            // We use specific format or just random string
            const taskId = `upload-${Date.now()}`;

            this.state.uploadProgress = { percent: 0, filename: `Preparing ${files.length} file(s)...` };

            try {
                // Call streaming upload
                await this.minioService.uploadStream(
                    files,
                    this.state.currentPath,
                    taskId,
                    (percent) => {
                        this.state.uploadProgress = {
                            percent,
                            filename: `Uploading ${files.length} file(s)... ${percent}%`
                        };
                    }
                );

                this.notification.add(_t("Upload completed successfully"), { type: 'success' });
                // Refresh
                await this.loadPath(this.state.currentPath);

            } catch (error) {
                console.error("Upload failed", error);
                if (error.auth_required) {
                    this.dialogService.add(MinioLoginDialog, {
                        onLoginSuccess: () => {
                            this.notification.add(_t("Authentication successful. Please retry your upload."), { type: 'success' });
                        }
                    });
                } else {
                    this.notification.add(_t("Upload failed: %s", error.message), { type: 'danger' });
                }
            } finally {
                this.state.uploadProgress = null;
            }
        };

        input.click();
    }

    // ... (rest of methods) ...


    async loadPath(path) {
        this.state.loading = true;
        try {
            const result = await this.minioService.listObjects(path);

            // Standalone service returns an array of objects
            if (Array.isArray(result)) {
                this.state.currentPath = path;
                this.state.folders = result.filter(i => i.type === 'folder');
                this.state.files = result.filter(i => i.type === 'file');
                this.state.selectedItems = {};
            } else if (result.error) {
                this.notification.add(result.error, { type: 'danger' });
            }
        } catch (error) {
            this.notification.add(_t("Failed to browse MinIO service"), { type: 'danger' });
        } finally {
            this.state.loading = false;
        }
    }

    onFolderClick(folder) {
        this.loadPath(folder.path);
    }

    onItemToggle(item) {
        if (this.state.selectedItems[item.path]) {
            delete this.state.selectedItems[item.path];
        } else {
            this.state.selectedItems[item.path] = true;
        }
    }

    goUp() {
        if (!this.state.currentPath) return;
        const parts = this.state.currentPath.split('/');
        parts.pop();
        this.loadPath(parts.join('/'));
    }

    onToggleDeleteAfterImport() {
        this.state.deleteAfterImport = !this.state.deleteAfterImport;
    }

    async onImport() {
        const selectedPaths = Object.keys(this.state.selectedItems).filter(p => this.state.selectedItems[p]);
        if (selectedPaths.length === 0) {
            this.notification.add(_t("Please select at least one item"), { type: 'warning' });
            return;
        }

        this.state.loading = true;
        try {
            let totalFiles = 0;
            let totalFolders = 0;

            for (const path of selectedPaths) {
                const isFolder = path.endsWith('/') || this.state.folders.some(f => f.path === path);
                if (isFolder) {
                    const result = await this._importRecursive(path, this.props.folderId);
                    totalFiles += result.files;
                    totalFolders += result.folders;
                } else {
                    const success = await this._createDocument(path, this.props.folderId);
                    if (success) totalFiles++;
                }
            }

            if (totalFiles > 0 || totalFolders > 0) {
                // Delete from MinIO if the option is enabled
                if (this.state.deleteAfterImport) {
                    let deletedCount = 0;
                    for (const path of selectedPaths) {
                        const isFolder = path.endsWith('/') || this.state.folders.some(f => f.path === path);
                        try {
                            const result = await this.minioService.deleteObject(path, isFolder);
                            if (result.success) deletedCount++;
                        } catch (e) {
                            console.error(`Failed to delete ${path} from MinIO:`, e);
                        }
                    }
                    this.notification.add(
                        _t("Imported %s file(s), created %s workspace(s), deleted %s item(s) from MinIO", totalFiles, totalFolders, deletedCount),
                        { type: 'success' }
                    );
                } else {
                    this.notification.add(_t("Imported %s file(s) and created %s workspace(s)", totalFiles, totalFolders), { type: 'success' });
                }
                if (this.props.onImport) {
                    await this.props.onImport();
                }
                this.props.close();
            } else {
                this.notification.add(_t("Items are already up to date"), { type: 'info' });
                this.props.close();
            }
        } catch (error) {
            console.error("Import error:", error);
            this.notification.add(_t("Critical import error"), { type: 'danger' });
        } finally {
            this.state.loading = false;
        }
    }

    async onDownloadZip() {
        const selectedPaths = Object.keys(this.state.selectedItems).filter(p => this.state.selectedItems[p]);
        if (selectedPaths.length === 0) {
            this.notification.add(_t("Please select at least one item"), { type: 'warning' });
            return;
        }

        this.state.loading = true;
        try {
            const blob = await this.minioService.downloadZip(selectedPaths);
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;

            // Determine filename
            let filename = "minio_download.zip";
            if (selectedPaths.length === 1) {
                const name = selectedPaths[0].split('/').filter(Boolean).pop();
                filename = `${name}.zip`;
            }

            a.download = filename;
            document.body.appendChild(a);
            a.click();
            window.URL.revokeObjectURL(url);
            this.notification.add(_t("Download started"), { type: 'success' });
        } catch (error) {
            console.error("Download Zip error:", error);
            this.notification.add(error.message || _t("Failed to create zip download"), { type: 'danger' });
        } finally {
            this.state.loading = false;
        }
    }

    async onDeleteSelected() {
        const selectedPaths = Object.keys(this.state.selectedItems).filter(p => this.state.selectedItems[p]);
        if (selectedPaths.length === 0) {
            this.notification.add(_t("Please select at least one item to delete"), { type: 'warning' });
            return;
        }

        this.state.loading = true;
        try {
            let deletedCount = 0;
            for (const path of selectedPaths) {
                const isFolder = path.endsWith('/') || this.state.folders.some(f => f.path === path);
                const result = await this.minioService.deleteObject(path, isFolder);

                if (result.success) {
                    deletedCount++;
                    // Find and delete Odoo record if it exists
                    const existing = await this.orm.search("documents.document", [
                        ['minio_object_name', '=', path]
                    ]);
                    if (existing.length > 0) {
                        await this.orm.unlink("documents.document", existing);
                    }
                }
            }

            if (deletedCount > 0) {
                this.notification.add(_t("Deleted %s item(s) from MinIO and Odoo", deletedCount), { type: 'success' });
                // Refresh current view
                await this.loadPath(this.state.currentPath);
                if (this.props.onImport) {
                    await this.props.onImport(); // Trigger reload of parent view
                }
            }
        } catch (error) {
            console.error("Delete error:", error);
            this.notification.add(_t("Failed to delete items"), { type: 'danger' });
        } finally {
            this.state.loading = false;
        }
    }

    async _importRecursive(path, odooParentFolderId) {
        let stats = { files: 0, folders: 0 };
        try {
            const folderName = path.split('/').filter(Boolean).pop();
            const odooFolderId = await this._getOrCreateOdooFolder(folderName, odooParentFolderId);
            stats.folders++;

            const items = await this.minioService.listObjects(path);
            for (const item of items) {
                if (item.type === 'folder') {
                    const subStats = await this._importRecursive(item.path, odooFolderId);
                    stats.files += subStats.files;
                    stats.folders += subStats.folders;
                } else {
                    const success = await this._createDocument(item.path, odooFolderId);
                    if (success) stats.files++;
                }
            }
        } catch (e) {
            console.error(`Failed to list ${path} for recursive import:`, e);
        }
        return stats;
    }

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

    async _createDocument(path, odooFolderId) {
        try {
            const downloadUrl = await this.minioService.getDownloadUrl(path);

            // Check if document already exists to avoid duplicates
            const existing = await this.orm.search("documents.document", [
                ['minio_object_name', '=', path],
                ['folder_id', '=', odooFolderId]
            ], { limit: 1 });

            if (existing.length > 0) {
                await this.orm.write("documents.document", existing, {
                    url: downloadUrl,
                    minio_last_sync: new Date().toISOString().slice(0, 19).replace('T', ' '),
                });
            } else {
                await this.orm.create("documents.document", [{
                    name: path.split('/').pop(),
                    folder_id: odooFolderId,
                    type: 'url',
                    url: downloadUrl,
                    minio_object_name: path,
                    minio_synced: true,
                    minio_last_sync: new Date().toISOString().slice(0, 19).replace('T', ' '),
                }]);
            }
            return true;
        } catch (e) {
            console.error(`Failed to create/update document for ${path}:`, e);
            return false;
        }
    }

    get selectedCount() {
        return Object.keys(this.state.selectedItems).filter(p => this.state.selectedItems[p]).length;
    }

    isImage(file) {
        const ext = (file.name || '').split('.').pop().toLowerCase();
        return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'svg', 'bmp'].includes(ext);
    }

    isVideo(file) {
        const ext = (file.name || '').split('.').pop().toLowerCase();
        return ['mp4', 'webm', 'mov', 'avi', 'mkv', 'flv', 'wmv'].includes(ext);
    }

    getThumbnailUrl(file) {
        return `/minio/api/download?path=${encodeURIComponent(file.path)}`;
    }

    getVideoThumbnailUrl(file) {
        return `/minio/api/thumbnail?path=${encodeURIComponent(file.path)}`;
    }

    getFileIcon(file) {
        const ext = (file.name || '').split('.').pop().toLowerCase();
        const iconMap = {
            pdf: 'fa fa-file-pdf-o text-danger',
            doc: 'fa fa-file-word-o text-primary', docx: 'fa fa-file-word-o text-primary',
            xls: 'fa fa-file-excel-o text-success', xlsx: 'fa fa-file-excel-o text-success',
            ppt: 'fa fa-file-powerpoint-o text-warning', pptx: 'fa fa-file-powerpoint-o text-warning',
            zip: 'fa fa-file-archive-o', rar: 'fa fa-file-archive-o', '7z': 'fa fa-file-archive-o',
            mp3: 'fa fa-file-audio-o', wav: 'fa fa-file-audio-o', flac: 'fa fa-file-audio-o',
            txt: 'fa fa-file-text-o', csv: 'fa fa-file-text-o',
            html: 'fa fa-file-code-o', js: 'fa fa-file-code-o', py: 'fa fa-file-code-o',
        };
        return iconMap[ext] || 'fa fa-file';
    }

    formatSize(bytes) {
        if (!bytes) return "";
        const units = ['B', 'KB', 'MB', 'GB'];
        let size = bytes;
        let unitIndex = 0;
        while (size >= 1024 && unitIndex < units.length - 1) {
            size /= 1024;
            unitIndex++;
        }
        return `${size.toFixed(2)} ${units[unitIndex]}`;
    }
}