/** @odoo-module **/

import { FormController } from "@web/views/form/form_controller";
import { ListController } from "@web/views/list/list_controller";
import { patch } from "@web/core/utils/patch";
import { useService } from "@web/core/utils/hooks";

/**
 * Patch FormController to intercept Test Connection button.
 */
patch(FormController.prototype, {
    setup() {
        super.setup();
        this.notification = useService("notification");
    },

    /**
     * @override
     */
    async beforeExecuteActionButton(params) {
        if (params.name === 'action_test_connection' && this.props.resModel === 'minio.config') {
            const record = this.model.root;
            const clientServiceUrl = record.data.client_service_url;
            
            if (!clientServiceUrl) {
                this.notification.add("Client Service URL is not configured.", { type: "danger" });
                return false;
            }

            this.notification.add("Testing connection to local service...", { type: "info" });
            
            try {
                // Perform health check to the local service
                const response = await fetch(`${clientServiceUrl}/api/bucket`, {
                    method: 'GET',
                    mode: 'cors',
                    cache: 'no-cache'
                });

                if (response.ok) {
                    const data = await response.json();
                    this.notification.add(`Connection Successful! Bucket: ${data.bucket || 'N/A'}`, {
                        title: "MinIO Local Service",
                        type: "success",
                        sticky: false,
                    });
                } else {
                    throw new Error(`Service responded with status ${response.status}`);
                }
            } catch (error) {
                this.notification.add(`Connection Failed: ${error.message}. Ensure the local MinIO client service is running.`, {
                    title: "MinIO Local Service",
                    type: "danger",
                    sticky: true,
                });
            }
            
            // Return false to prevent the backend original call
            return false;
        }
        return super.beforeExecuteActionButton(...arguments);
    }
});

/**
 * Patch ListController to intercept Test Connection button in Tree view.
 */
patch(ListController.prototype, {
    setup() {
        super.setup();
        this.notification = useService("notification");
    },

    /**
     * @override
     */
    async beforeExecuteActionButton(params) {
        if (params.name === 'action_test_connection' && this.props.resModel === 'minio.config') {
            const record = params.record;
            if (!record) return super.beforeExecuteActionButton(...arguments);

            const clientServiceUrl = record.data.client_service_url;
            
            if (!clientServiceUrl) {
                this.notification.add("Client Service URL is not configured.", { type: "danger" });
                return false;
            }

            this.notification.add("Testing connection to local service...", { type: "info" });
            
            try {
                const response = await fetch(`${clientServiceUrl}/api/bucket`, {
                    method: 'GET',
                    mode: 'cors',
                    cache: 'no-cache'
                });

                if (response.ok) {
                    const data = await response.json();
                    this.notification.add(`Connection Successful! Bucket: ${data.bucket || 'N/A'}`, {
                        title: "MinIO Local Service",
                        type: "success",
                    });
                } else {
                    throw new Error(`Service responded with status ${response.status}`);
                }
            } catch (error) {
                this.notification.add(`Connection Failed: ${error.message}. Ensure the local MinIO client service is running.`, {
                    title: "MinIO Local Service",
                    type: "danger",
                    sticky: true,
                });
            }
            return false;
        }
        return super.beforeExecuteActionButton(...arguments);
    }
});
