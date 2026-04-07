/** @odoo-module **/

import { FileViewer } from "@documents/attachments/document_file_viewer";
import { patch } from "@web/core/utils/patch";
import { useEffect } from "@odoo/owl";

patch(FileViewer.prototype, {
    setup() {
        super.setup();
        
        /**
         * Watch for PDF files from MinIO and load them as Blobs
         * This bypasses the "file origin does not match viewer's" error in pdf.js
         * because Blob URLs share the same origin as Odoo.
         */
        useEffect(
            (file) => {
                if (file && file._isMinio && file.isPdf && !file.blobUrl) {
                    this._loadMinioPdfAsBlob(file);
                }
                return () => {
                    // Cleanup: Ideally we would revokeObjectURL here, 
                    // but since the file object might persist in the store, 
                    // we keep it for the session or manage it more carefully.
                    // For now, we just ensure we don't leak too much.
                };
            },
            () => [this.state.file]
        );
    },

    async _loadMinioPdfAsBlob(file) {
        if (file._loadingBlob) return;
        file._loadingBlob = true;
        try {
            console.log("MinIO: Fetching PDF as blob...", file.url);
            // Reconstruct the full local URL with preview=true
            let url = file.url;
            if (!url.includes('preview=true')) {
                url += (url.includes('?') ? '&' : '?') + 'preview=true';
            }

            const response = await fetch(url);
            if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
            
            const blob = await response.blob();
            // Create the Blob URL (same origin as Odoo)
            const blobUrl = URL.createObjectURL(blob);
            file.blobUrl = blobUrl;
            
            console.log("MinIO: Blob URL created:", blobUrl);
            
            // Re-render the component to update the iframe src
            this.render();

            // SNEAKY FIX: Odoo might mangle the blob URL in the iframe src
            // We fix it immediately after the render cycle
            setTimeout(() => {
                const iframe = this.root.el && this.root.el.querySelector('iframe');
                if (iframe && iframe.src.includes('viewer.html')) {
                    const origin = window.location.origin;
                    // The corruption looks like: origin + "blob:"
                    const corrupted = encodeURIComponent(origin) + 'blob%3A';
                    if (iframe.src.includes(corrupted)) {
                        console.log("MinIO: Fixing corrupted iframe src in DOM");
                        iframe.src = iframe.src.replace(corrupted, 'blob%3A');
                    }
                }
            }, 0);
        } catch (error) {
            console.error("Failed to load MinIO PDF as blob:", error);
        } finally {
            file._loadingBlob = false;
        }
    }
});
