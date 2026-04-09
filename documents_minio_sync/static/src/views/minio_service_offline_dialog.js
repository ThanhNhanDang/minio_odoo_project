/** @odoo-module **/

import { Component } from "@odoo/owl";
import { Dialog } from "@web/core/dialog/dialog";
import { _t } from "@web/core/l10n/translation";

export class MinioServiceOfflineDialog extends Component {
    get downloadUrl() {
        return "/documents_minio_sync/static/installer/MinIOSync-Setup.exe";
    }

    get githubUrl() {
        return "https://github.com/ThanhNhanDang/minio_odoo_project/releases/latest";
    }
}

MinioServiceOfflineDialog.template = "documents_minio_sync.MinioServiceOfflineDialog";
MinioServiceOfflineDialog.components = { Dialog };
MinioServiceOfflineDialog.props = {
    close: Function,
};
