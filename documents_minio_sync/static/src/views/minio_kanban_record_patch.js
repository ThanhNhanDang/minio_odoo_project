/** @odoo-module **/

import { DocumentsKanbanRecord } from "@documents/views/kanban/documents_kanban_record";
import { patch } from "@web/core/utils/patch";

patch(DocumentsKanbanRecord.prototype, {
    /**
     * Override onGlobalClick to intercept clicks on MinIO links.
     * By default, Odoo ignores clicks on 'a' tags (CANCEL_GLOBAL_CLICK).
     * We need to prevent the default link behavior (opening in new tab)
     * and instead trigger the internal preview logic.
     * @override
     */
    onGlobalClick(ev) {
        // Check if we clicked a MinIO link inside the preview area
        const link = ev.target.closest("a");
        const isPreviewArea = ev.target.closest("div[name='document_preview']");
        
        if (link && isPreviewArea && link.href && link.href.includes('/api/download')) {
            ev.preventDefault(); // Stop opening in new tab
            ev.stopPropagation(); 
            this.props.record.onClickPreview(ev); // Trigger the preview
            return;
        }
        
        super.onGlobalClick(ev);
    }
});
