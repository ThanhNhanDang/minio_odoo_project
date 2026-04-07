/** @odoo-module **/

import { DocumentsInspector } from "@documents/views/inspector/documents_inspector";
import { patch } from "@web/core/utils/patch";
import { useService } from "@web/core/utils/hooks";

patch(DocumentsInspector.prototype, {
    setup() {
        super.setup();
        this.minioService = useService("minio_service");
    },

    /**
     * @override
     * Intercept permanent deletion to remove files from MinIO.
     */
    onDelete() {
        const records = this.props.documents;
        const minioRecords = records.filter(rec => rec.data.minio_object_name);

        const originalCallback = async () => {
            // First, try to delete from MinIO
            for (const rec of minioRecords) {
                try {
                    // Check if it's a folder or file by mimetype or specific logic
                    const isFolder = rec.data.mimetype === 'application/x-directory';
                    await this.minioService.deleteObject(rec.data.minio_object_name, isFolder);
                    console.log(`MinIO: Deleted object ${rec.data.minio_object_name}`);
                } catch (error) {
                    console.error(`MinIO: Failed to delete ${rec.data.minio_object_name}`, error);
                    // We don't block Odoo deletion if MinIO fails, but we log it
                }
            }

            // Then perform native Odoo deletion
            const model = records[0].model;
            await model.root.deleteRecords(records);
            await model.load(this.env.model.config);
            await model.notify();
        };

        // Call the confirmation dialog with our enhanced callback
        records[0].openDeleteConfirmationDialog(records[0].model.root, originalCallback, true);
    }
});
