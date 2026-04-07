/** @odoo-module **/

import { Component } from "@odoo/owl";

export class DownloadProgressBar extends Component {
    static template = "documents_minio_sync.DownloadProgressBar";
    static props = {
        download: Object,
    };

    get progressStyle() {
        return `width: ${this.props.download.progress}%`;
    }

    get formattedSize() {
        const bytes = this.props.download.loaded;
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
    }

    get totalSize() {
        const bytes = this.props.download.total;
        if (bytes === 0) return '?';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
    }
}
