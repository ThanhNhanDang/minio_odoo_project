from odoo import models, fields, api
from odoo.exceptions import ValidationError
from odoo.exceptions import ValidationError
import logging
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
from minio import Minio

_logger = logging.getLogger(__name__)


class MinioConfig(models.Model):
    _name = 'minio.config'
    _description = 'MinIO Configuration'
    _rec_name = 'name'

    name = fields.Char(string='Configuration Name', required=True)
    endpoint = fields.Char(string='MinIO Endpoint', required=True, default='localhost:9000', help="Public endpoint for external clients (Tray App, Browser).")
    backend_endpoint = fields.Char(string='Backend Endpoint', help="Optional. Internal endpoint for Odoo backend connection (e.g. http://192.168.x.x:9000). Leave empty to use MinIO Endpoint.")
    access_key = fields.Char(string='Access Key', required=True)
    secret_key = fields.Char(string='Secret Key', required=True)
    bucket_name = fields.Char(string='Bucket Name', required=True, default='odoo-documents')
    active = fields.Boolean(string='Active', default=True)
    is_default = fields.Boolean(string='Default Configuration', default=False)
    
    # Client service settings
    client_service_url = fields.Char(
        string='Client Service URL', 
        default='http://localhost:9999',
        help='URL of the MinIO client upload service'
    )

    @api.model
    def get_default_config(self):
        """Get the default MinIO configuration"""
        config = self.search([('is_default', '=', True), ('active', '=', True)], limit=1)
        if not config:
            config = self.search([('active', '=', True)], limit=1)
        return config.id if config else False

    def get_minio_client(self):
        """Get an initialized MinIO client instance."""
        self.ensure_one()
        
        # Prefer backend_endpoint if set, otherwise use public endpoint
        endpoint = (self.backend_endpoint or self.endpoint or "").strip()
        
        access_key = (self.access_key or "").strip()
        secret_key = (self.secret_key or "").strip()
        bucket_name = (self.bucket_name or "").strip()
        secure = False
        
        # Handle cases where endpoint includes protocol
        if endpoint.startswith('https://'):
            endpoint = endpoint.replace('https://', '')
            secure = True
        elif endpoint.startswith('http://'):
            endpoint = endpoint.replace('http://', '')
            secure = False
            
        # Strip trailing slashes
        endpoint = endpoint.rstrip('/')
        
        _logger.info("Initializing MinIO Client: Endpoint=%s, Secure=%s, Bucket=%s", 
                    endpoint, secure, bucket_name)

        return Minio(
            endpoint,
            access_key=access_key,
            secret_key=secret_key,
            secure=secure,
            region='us-east-1',  # Thêm region
        )

    def get_bucket_for_domain(self):
        """Return bucket name.
        If bucket_name is explicitly configured, always use it.
        Otherwise derive from the current HTTP domain:
        e.g. erp.company.com → erp-company-com-documents
        Falls back to 'odoo-documents' if nothing available.
        """
        # If bucket_name is explicitly set in config, use it directly
        if self.bucket_name and self.bucket_name.strip():
            return self.bucket_name.strip()
        # Auto-derive from domain only when no explicit bucket configured
        try:
            from odoo.http import request
            if request and request.httprequest:
                host = request.httprequest.host.split(':')[0]  # strip port
                sanitized = host.replace('.', '-').lower()
                return f"{sanitized}-documents"
        except Exception:
            pass
        return 'odoo-documents'

    def ensure_bucket(self, client=None, bucket=None):
        """Create the bucket if it does not exist. Returns bucket name."""
        self.ensure_one()
        if client is None:
            client = self.get_minio_client()
        if bucket is None:
            bucket = self.get_bucket_for_domain()
        if not client.bucket_exists(bucket):
            client.make_bucket(bucket)
            _logger.info("Auto-created bucket: %s", bucket)
        return bucket

    def action_test_connection(self):
        """
        Test MinIO connection.
        """
        self.ensure_one()
        try:
            bucket = self.get_bucket_for_domain()
            _logger.info("Testing MinIO connection for %s on bucket %s", self.name, bucket)
            client = self.get_minio_client()
            # Try to check if bucket exists
            if not client.bucket_exists(bucket):
                client.make_bucket(bucket)
                message = f"Connected successfully! Bucket '{bucket}' created."
            else:
                message = f"Connected successfully! Bucket '{bucket}' exists."
            
            return {
                'type': 'ir.actions.client',
                'tag': 'display_notification',
                'params': {
                    'title': 'Connection Successful',
                    'message': message,
                    'type': 'success',
                    'sticky': False,
                }
            }
        except Exception as e:
            return {
                'type': 'ir.actions.client',
                'tag': 'display_notification',
                'params': {
                    'title': 'Connection Failed',
                    'message': str(e),
                    'type': 'danger',
                    'sticky': True,
                }
            }

    @api.model
    def create(self, vals):
        if vals.get('is_default'):
            # Remove default flag from other configs
            self.search([('is_default', '=', True)]).write({'is_default': False})
        if vals.get('active'):
            # Archive other configs
            self.search([('active', '=', True)]).write({'active': False})
        return super().create(vals)

    def write(self, vals):
        if vals.get('is_default'):
            # Remove default flag from other configs
            self.search([('id', 'not in', self.ids), ('is_default', '=', True)]).write({'is_default': False})
        if vals.get('active'):
            # Archive other configs
            self.search([('id', 'not in', self.ids), ('active', '=', True)]).write({'active': False})
        return super().write(vals)