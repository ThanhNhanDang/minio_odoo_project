/** @odoo-module **/

import { Attachment } from "@mail/core/common/attachment_model";
import { FileModel } from "@web/core/file_viewer/file_model";
import { patch } from "@web/core/utils/patch";

/**
 * Patch Attachment model (used by mail store and documents preview)
 */
patch(Attachment.prototype, {
    /**
     * Helper to detect MinIO URL
     * Use super.url to avoid recursion with the overridden url getter.
     */
    get _isMinio() {
        const urlValue = super.url || (this.data && this.data.url) || "";
        return urlValue && urlValue.includes('/api/download');
    },

    /**
     * Override isPdf to detect PDF from MinIO URL.
     */
    get isPdf() {
        if (this._isMinio) {
            const name = this.name || this.filename || super.url || "";
            if (name.toLowerCase().includes('.pdf')) return true;
        }
        return super.isPdf;
    },

    /**
     * Override isImage to detect images from MinIO URL.
     */
    get isImage() {
        if (this._isMinio) {
            const name = this.name || this.filename || super.url || "";
            if (/\.(jpg|jpeg|png|gif|webp|bmp|svg)/i.test(name)) return true;
        }
        return super.isImage;
    },

    /**
     * Override isVideo to detect video from MinIO URL.
     */
    get isVideo() {
        if (this._isMinio) {
            const name = this.name || this.filename || super.url || "";
            if (/\.(mp4|webm|ogv|ogg)/i.test(name)) return true;
        }
        return super.isVideo;
    },

    /**
     * Prevent YouTube detection for MinIO URLs.
     */
    get isUrlYoutube() {
        if (this._isMinio) {
            return false;
        }
        return super.isUrlYoutube;
    },

    /**
     * Ensure isViewable is true for MinIO files.
     */
    get isViewable() {
        if (this._isMinio) {
            return true; 
        }
        return super.isViewable;
    },

    /**
     * Fix the URL route.
     * While loading, we return a same-origin path to satisfy PDF.js origin check.
     */
    get urlRoute() {
        if (this._isMinio) {
            if (this.blobUrl) {
                return this.blobUrl;
            }
            if (this.isPdf) {
                return '/web/static/description/icon.png';
            }
            const urlValue = super.url || "";
            return urlValue.split('?')[0];
        }
        return super.urlRoute;
    },

    /**
     * Override url directly to prevent origin corruption for Blobs.
     */
    get url() {
        if (this._isMinio && this.blobUrl) {
            return this.blobUrl;
        }
        return super.url;
    },

    /**
     * Merge MinIO URL parameters with Odoo parameters.
     */
    get urlQueryParams() {
        const res = super.urlQueryParams || {};
        if (this._isMinio) {
            // If we have a blob URL, we don't need parameters
            if (this.blobUrl) {
                return {};
            }
            const urlValue = super.url || "";
            const urlParts = urlValue.split('?');
            if (urlParts.length > 1) {
                const searchParams = new URLSearchParams(urlParts[1]);
                for (const [key, value] of searchParams.entries()) {
                    res[key] = value;
                }
            }
            // Force preview mode for the streaming API
            res['preview'] = 'true';
        }
        return res;
    }
});

/**
 * Patch FileModel (used by core file viewer)
 */
patch(FileModel.prototype, {
    get _isMinio() {
        const urlValue = super.url || this.url; // Use internal property or super if possible
        // Actually for FileModel, super.url is the best bet if it was a getter
        return urlValue && urlValue.includes('/api/download');
    },
    get isPdf() {
        if (this._isMinio) {
            const name = this.name || this.filename || super.url || "";
            if (name.toLowerCase().includes('.pdf')) return true;
        }
        return super.isPdf;
    },
    get url() {
        if (this._isMinio && this.blobUrl) {
            return this.blobUrl;
        }
        return super.url;
    },
    get isImage() {
        if (this._isMinio) {
            const name = this.name || this.filename || super.url || "";
            if (/\.(jpg|jpeg|png|gif|webp|bmp|svg)/i.test(name)) return true;
        }
        return super.isImage;
    },
    get isUrlYoutube() {
        if (this._isMinio) return false;
        return super.isUrlYoutube;
    },
    get isViewable() {
        if (this._isMinio) return true;
        return super.isViewable;
    },
    get urlRoute() {
        if (this._isMinio) {
            if (this.blobUrl) {
                return this.blobUrl;
            }
            if (this.isPdf) {
                return '/web/static/description/icon.png';
            }
            const urlValue = super.url || "";
            return urlValue.split('?')[0];
        }
        return super.urlRoute;
    },
    get urlQueryParams() {
        if (this._isMinio && this.blobUrl) return {};
        const res = super.urlQueryParams || {};
        if (this._isMinio) {
            const urlValue = super.url || "";
            const urlParts = urlValue.split('?');
            if (urlParts.length > 1) {
                const searchParams = new URLSearchParams(urlParts[1]);
                for (const [key, value] of searchParams.entries()) {
                    res[key] = value;
                }
            }
            res['preview'] = 'true';
        }
        return res;
    }
});
