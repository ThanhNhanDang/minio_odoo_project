/** @odoo-module **/

import { ListController } from "@web/views/list/list_controller";
import { patch } from "@web/core/utils/patch";
import { onWillStart } from "@odoo/owl";

patch(ListController.prototype, {
    setup() {
        super.setup(...arguments);
        if (this.props.resModel === "minio.device") {
            onWillStart(() => {
                this.env.services.bus_service.addChannel("minio.device.updated");
                this.env.services.bus_service.subscribe("status_changed", (payload) => {
                    console.log("MinIO Device updated via Bus, refreshing view...", payload);
                    // Refresh the model to update the list view rows dynamically
                    if (this.model && typeof this.model.load === 'function') {
                        this.model.load();
                    }
                });
            });
        }
    }
});
