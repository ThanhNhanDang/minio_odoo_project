/** @odoo-module **/

import { DocumentsInspector } from "@documents/views/inspector/documents_inspector";
import { patch } from "@web/core/utils/patch";
import { useService } from "@web/core/utils/hooks";
import { DownloadProgressBar } from "@documents_minio_sync/components/download_progress_bar";
import { serializeDate } from "@web/core/l10n/dates";

const { DateTime } = luxon;

// Patch DocumentsInspector to add download progress
patch(DocumentsInspector.prototype, {
    setup() {
        super.setup(...arguments);
        this.downloadProgress = useService("download_progress");
    },

    async download(records) {
        if (records.length === 1) {
            const record = records[0];
            const filename = record.data.name || `document_${record.resId}`;

            // For MinIO documents: download directly via /minio/api/download
            // to avoid redirect issues (mixed content, CORS, etc.)
            const minioPath = record.data.minio_object_name;
            const url = minioPath
                ? `/minio/api/download?path=${encodeURIComponent(minioPath)}`
                : `/documents/content/${record.resId}`;

            try {
                await this.downloadProgress.downloadWithProgress(url, filename);
            } catch (error) {
                console.error("Download failed:", error);
                this.notificationService.add(
                    `Failed to download ${filename}`,
                    { type: "danger" }
                );
            }
        } else {
            // Multiple files — check if any are MinIO documents
            const minioRecords = records.filter(r => r.data.minio_object_name);
            const normalRecords = records.filter(r => !r.data.minio_object_name);

            // Download MinIO files via /minio/api/download_zip
            if (minioRecords.length > 0) {
                const paths = minioRecords.map(r => r.data.minio_object_name);
                this.downloadProgress.downloadStandard(
                    "/minio/api/download_zip",
                    { paths }
                );
            }

            // Download normal files via standard Odoo zip
            if (normalRecords.length > 0) {
                this.downloadProgress.downloadStandard(
                    "/document/zip",
                    {
                        file_ids: normalRecords.map((rec) => rec.resId),
                        zip_name: `documents-${serializeDate(DateTime.now())}.zip`,
                    }
                );
            }
        }
    },
});

// Add DownloadProgressBar to components
if (!DocumentsInspector.components.DownloadProgressBar) {
    DocumentsInspector.components = {
        ...DocumentsInspector.components,
        DownloadProgressBar,
    };
}
