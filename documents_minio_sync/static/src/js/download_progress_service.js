/** @odoo-module **/

import { reactive } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { EventBus } from "@odoo/owl";

/**
 * Download Progress Service
 * Tracks file downloads and provides progress feedback
 * Similar to file_upload service but for downloads
 */
export const downloadProgressService = {
    dependencies: [],

    start() {
        const bus = new EventBus();
        const downloads = reactive({});
        let downloadId = 0;

        /**
         * Download a file with progress tracking
         * @param {string} url - URL to download from
         * @param {string} filename - Name for the downloaded file
         * @param {Object} options - Additional options
         */
        async function downloadWithProgress(url, filename, options = {}) {
            const id = ++downloadId;
            const download = {
                id,
                filename,
                url,
                loaded: 0,
                total: 0,
                progress: 0,
                error: null,
            };

            downloads[id] = download;
            bus.trigger("FILE_DOWNLOAD_ADDED", { download });

            try {
                const response = await fetch(url, {
                    method: options.method || 'GET',
                    headers: options.headers || {},
                });

                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }

                const contentLength = response.headers.get('Content-Length');
                download.total = contentLength ? parseInt(contentLength, 10) : 0;

                const reader = response.body.getReader();
                const chunks = [];
                let receivedLength = 0;

                while (true) {
                    const { done, value } = await reader.read();

                    if (done) break;

                    chunks.push(value);
                    receivedLength += value.length;
                    download.loaded = receivedLength;

                    if (download.total > 0) {
                        download.progress = Math.round((receivedLength / download.total) * 100);
                    }

                    bus.trigger("FILE_DOWNLOAD_PROGRESS", { download });
                }

                // Create blob and trigger download
                const blob = new Blob(chunks);
                const link = document.createElement('a');
                const blobUrl = URL.createObjectURL(blob);

                link.href = blobUrl;
                link.download = filename;
                link.style.display = 'none';
                document.body.appendChild(link);
                link.click();
                document.body.removeChild(link);

                // Clean up blob URL after a delay
                setTimeout(() => URL.revokeObjectURL(blobUrl), 100);

                bus.trigger("FILE_DOWNLOAD_LOADED", { download });
                delete downloads[id];

            } catch (error) {
                download.error = error.message;
                bus.trigger("FILE_DOWNLOAD_ERROR", { download, error });
                delete downloads[id];
                throw error;
            }
        }

        /**
         * Download using standard method (for POST requests with data)
         * This doesn't track progress but maintains consistency
         */
        function downloadStandard(url, data = {}, filename = null) {
            const form = document.createElement('form');
            form.method = 'POST';
            form.action = url;
            form.style.display = 'none';

            for (const [key, value] of Object.entries(data)) {
                const input = document.createElement('input');
                input.type = 'hidden';
                input.name = key;
                input.value = typeof value === 'object' ? JSON.stringify(value) : value;
                form.appendChild(input);
            }

            document.body.appendChild(form);
            form.submit();
            document.body.removeChild(form);
        }

        return {
            bus,
            downloads,
            downloadWithProgress,
            downloadStandard,
        };
    },
};

registry.category("services").add("download_progress", downloadProgressService);
