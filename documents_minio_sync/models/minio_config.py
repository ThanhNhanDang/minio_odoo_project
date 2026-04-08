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

        # Use a custom HTTP client with timeouts and skip SSL verification
        # (MinIO behind reverse proxy often uses self-signed or internal certs)
        http_client = urllib3.PoolManager(
            timeout=urllib3.Timeout(connect=5, read=10),
            retries=urllib3.Retry(total=2, backoff_factor=0.2),
            cert_reqs='CERT_NONE',
        )

        return Minio(
            endpoint,
            access_key=access_key,
            secret_key=secret_key,
            secure=secure,
            http_client=http_client,
        )

    def get_presign_client(self):
        """Get a MinIO client using the PUBLIC endpoint — for generating presigned URLs.
        Presigned URLs must be signed with the public host so browsers can access them
        directly (e.g. through Cloudflare). No network call is made during URL generation."""
        self.ensure_one()
        endpoint = (self.endpoint or "").strip()
        access_key = (self.access_key or "").strip()
        secret_key = (self.secret_key or "").strip()
        secure = False

        if endpoint.startswith('https://'):
            endpoint = endpoint.replace('https://', '')
            secure = True
        elif endpoint.startswith('http://'):
            endpoint = endpoint.replace('http://', '')
            secure = False

        endpoint = endpoint.rstrip('/')

        # Presigned URL generation is local (no network), but the library may call
        # _get_region once. Use a short-timeout client with no SSL verification.
        http_client = urllib3.PoolManager(
            timeout=urllib3.Timeout(connect=5, read=5),
            retries=urllib3.Retry(total=1, backoff_factor=0.1),
            cert_reqs='CERT_NONE',
        )

        return Minio(
            endpoint,
            access_key=access_key,
            secret_key=secret_key,
            secure=secure,
            http_client=http_client,
            region='us-east-1',  # skip region lookup
        )

    def get_bucket(self):
        """Return bucket name from config. Falls back to 'odoo-documents'."""
        self.ensure_one()
        return (self.bucket_name or 'odoo-documents').strip()

    def ensure_bucket(self, client=None, bucket=None):
        """Create the bucket if it does not exist. Returns bucket name."""
        self.ensure_one()
        if client is None:
            client = self.get_minio_client()
        if bucket is None:
            bucket = self.get_bucket()
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
            bucket = self.get_bucket()
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