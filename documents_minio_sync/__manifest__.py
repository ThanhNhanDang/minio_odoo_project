{
    'name': 'Documents MinIO Sync',
    'version': '17.0.1.0.0',
    'category': 'Document Management',
    'summary': 'Two-way synchronization with MinIO server for Documents',
    'description': """
        This module provides:
        - Upload files/folders from client to MinIO via local service
        - Browse and import files from MinIO to Odoo Documents
        - Two-way synchronization capabilities
    """,
    'author': 'Antigravity',
    'depends': ['documents', 'web','mail'],
    'external_dependencies': {
        'python': ['minio'],
    },
    'data': [
        'security/ir.model.access.csv',
        'views/minio_config_views.xml',
        'views/minio_device_views.xml',
        'views/documents_kanban_views.xml',
        'views/documents_document_views.xml',
        'data/minio_config.xml',
    ],
    'assets': {
        'web.assets_backend': [
            # MinIO Service
            'documents_minio_sync/static/src/services/minio_service.js',
            
            # Download Progress Feature
            'documents_minio_sync/static/src/js/download_progress_service.js',
            'documents_minio_sync/static/src/components/download_progress_bar.js',
            'documents_minio_sync/static/src/components/download_progress_bar.xml',
            'documents_minio_sync/static/src/js/documents_inspector_patch.js',
            'documents_minio_sync/static/src/xml/documents_inspector_patch.xml',
            
            # MinIO Sync Views
            'documents_minio_sync/static/src/views/documents_control_panel.xml',
            'documents_minio_sync/static/src/views/documents_minio_sync.js',
            'documents_minio_sync/static/src/views/minio_config_form_patch.js',
            'documents_minio_sync/static/src/views/minio_file_viewer_patch.js',
            'documents_minio_sync/static/src/views/minio_deletion_patch.js',
            'documents_minio_sync/static/src/views/minio_document_mixin_patch.js',
            'documents_minio_sync/static/src/views/minio_attachment_patch.js',
            'documents_minio_sync/static/src/views/minio_kanban_record_patch.js',
            'documents_minio_sync/static/src/views/minio_device_list_patch.js',
            'documents_minio_sync/static/src/views/minio_browser.js',
            'documents_minio_sync/static/src/views/minio_browser.xml',
            'documents_minio_sync/static/src/views/minio_login_dialog.js',
            'documents_minio_sync/static/src/views/minio_login_dialog.xml',
            'documents_minio_sync/static/src/views/minio_service_offline_dialog.js',
            'documents_minio_sync/static/src/views/minio_service_offline_dialog.xml',
        ],
    },
    'installable': True,
    'application': False,
    'auto_install': False,
    'license': 'LGPL-3',
}