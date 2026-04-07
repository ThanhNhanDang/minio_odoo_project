/** @odoo-module **/

import { DocumentsKanbanRecord } from "@documents/views/kanban/documents_kanban_model";
import { DocumentsListModel } from "@documents/views/list/documents_list_model";
import { patch } from "@web/core/utils/patch";

const patchObj = {
    /**
     * Helper to detect MinIO URL
     */
    _isMinio() {
        return this.data.url && this.data.url.includes('/api/download');
    },

    /**
     * Override isViewable to include MinIO URL documents.
     * @override
     */
    isViewable() {
        if (this._isMinio()) {
            return true;
        }
        return super.isViewable();
    },

    /**
     * Override type checks for MinIO URLs based on filename.
     */
    isPdf() {
        if (this._isMinio() && this.data.name.toLowerCase().endsWith('.pdf')) {
            return true;
        }
        return super.isPdf();
    },

    isImage() {
        if (this._isMinio() && /\.(jpe?g|png|gif|webp|bmp|svg)$/i.test(this.data.name)) {
            return true;
        }
        return super.isImage();
    }
};

patch(DocumentsKanbanRecord.prototype, patchObj);
patch(DocumentsListModel.Record.prototype, patchObj);
