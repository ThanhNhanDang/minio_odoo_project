/** @odoo-module **/

import { Component, useState, onWillStart } from "@odoo/owl";
import { Dialog } from "@web/core/dialog/dialog";
import { useService } from "@web/core/utils/hooks";
import { _t } from "@web/core/l10n/translation";

export class MinioLoginDialog extends Component {
    setup() {
        this.minioService = useService("minio_service");
        this.notification = useService("notification");

        this.state = useState({
            url: window.location.origin,
            db: "odoo", // Default placeholder
            username: "",
            password: "",
            error: null,
            loading: false
        });

        onWillStart(async () => {
            // Check if service is reachable and pre-fill if possible
            try {
                const status = await this.minioService.getAuthStatus();
                if (status) {
                    if (status.url) this.state.url = status.url;
                    if (status.db) this.state.db = status.db;

                    // If service is already authenticated, don't ask for login again
                    if (status.authenticated) {
                        if (this.props.onLoginSuccess) {
                            this.props.onLoginSuccess();
                        }
                        this.props.close();
                    }
                }
            } catch (e) {
                // Ignore
            }
        });
    }

    async onLogin() {
        this.state.error = null;
        if (!this.state.url || !this.state.db || !this.state.username || !this.state.password) {
            this.state.error = _t("All fields are required.");
            return;
        }

        this.state.loading = true;
        try {
            const result = await this.minioService.login(
                this.state.url,
                this.state.db,
                this.state.username,
                this.state.password
            );

            if (result.success) {
                this.notification.add(_t("Login successful. Tray App is now authenticated."), { type: "success" });
                this.props.close();
                if (this.props.onLoginSuccess) {
                    this.props.onLoginSuccess();
                }
            } else {
                this.state.error = result.error || _t("Login failed. Check credentials.");
            }
        } catch (e) {
            this.state.error = _t("Connection error: ") + e.message;
        } finally {
            this.state.loading = false;
        }
    }
}

MinioLoginDialog.template = "documents_minio_sync.MinioLoginDialog";
MinioLoginDialog.components = { Dialog };
MinioLoginDialog.props = {
    close: Function,
    onLoginSuccess: { type: Function, optional: true },
};
