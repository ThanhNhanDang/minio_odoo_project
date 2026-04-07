import mimetypes
from odoo import models, fields, api, _
import logging
from urllib.parse import quote, unquote
_logger = logging.getLogger(__name__)


def _get_base_url():
    """Get base URL with correct protocol (handles reverse proxy HTTPS termination)."""
    try:
        from odoo.http import request
        if request and request.httprequest:
            # Reverse proxies set X-Forwarded-Proto when terminating SSL
            proto = request.httprequest.headers.get('X-Forwarded-Proto', '').strip()
            if not proto:
                proto = request.httprequest.scheme
            host = request.httprequest.host  # includes port if non-standard
            return f'{proto}://{host}'
    except Exception:
        pass
    return ''


class DocumentsDocument(models.Model):
    _inherit = 'documents.document'

    minio_object_name = fields.Char(string='MinIO Object Path', index=True)
    minio_synced = fields.Boolean(string='Synced with MinIO', default=False)
    minio_last_sync = fields.Datetime(string='Last Sync Time')

    @api.model_create_multi
    def create(self, vals_list):
        _logger.info("DocumentsDocument.create vals_list: %s", vals_list)
        for vals in vals_list:
            try:
                if vals.get('type') == 'url' and vals.get('url') and isinstance(vals.get('url'), str) and '/api/download' in vals.get('url'):
                    # Extract clean name and path
                    clean_name = vals.get('name')
                    minio_path = vals.get('minio_object_name')
                    
                    # If path missing in vals, try to extract from Tray App URL
                    if not minio_path and vals.get('url'):
                        try:
                            extracted_path = vals.get('url').split('path=')[-1].split('&')[0]
                            minio_path = unquote(extracted_path)
                        except Exception:
                            pass
                    
                    if minio_path and isinstance(minio_path, str):
                        clean_name = minio_path.split('/')[-1]
                        # Create absolute internal MinIO download URL
                        new_url = f'{_get_base_url()}/minio/api/download?path={quote(minio_path)}'
                        vals['url'] = new_url
                        _logger.info("Corrected creation URL to relative: %s", new_url)
                    
                    # Force the name in vals so Odoo uses it from the start
                    if clean_name:
                        vals['name'] = clean_name

                    if not vals.get('attachment_id') and minio_path:
                        mimetype = self._guess_minio_mimetype(vals.get('url', ''), clean_name)
                        attachment = self.env['ir.attachment'].create({
                            'name': clean_name or _('MinIO Document'),
                            'type': 'url',
                            'url': vals.get('url'),
                            'mimetype': mimetype,
                        })
                        vals['attachment_id'] = attachment.id
                        _logger.debug("Created internal attachment %s for MinIO doc", attachment.id)
            except Exception as e:
                _logger.error("Error in DocumentsDocument.create MinIO logic: %s", e, exc_info=True)
                # We continue to allow super().create to run even if our logic failed
        return super(DocumentsDocument, self).create(vals_list)


    def write(self, vals):
        try:
            # Pre-process vals to catch any incoming localhost URLs for MinIO docs
            if 'url' in vals and vals.get('url') and isinstance(vals.get('url'), str) and '/api/download' in vals.get('url'):
                for record in self:
                    if record.minio_object_name and isinstance(record.minio_object_name, str):
                        new_url = f'{_get_base_url()}/minio/api/download?path={quote(record.minio_object_name)}'
                        vals['url'] = new_url
                        break # Take the first one for vals, individual records handled below
        except Exception as e:
            _logger.error("Error in DocumentsDocument.write Pre-process: %s", e)

        res = super(DocumentsDocument, self).write(vals)
        
        try:
            # Re-verify and force for each record
            for record in self:
                if record.type == 'url' and record.minio_object_name and isinstance(record.minio_object_name, str):
                    new_url = f'{_get_base_url()}/minio/api/download?path={quote(record.minio_object_name)}'
                    if record.url != new_url:
                        _logger.info("Forcing internal MinIO URL for doc %s on write: %s", record.id, new_url)
                        record.with_context(no_document=True).write({'url': new_url})
                        if record.attachment_id:
                            record.attachment_id.with_context(no_document=True).write({'url': new_url})
                        else:
                            mimetype = self._guess_minio_mimetype(new_url, record.name)
                            attachment = self.env['ir.attachment'].create({
                                'name': record.name or _('MinIO Document'),
                                'type': 'url',
                                'url': new_url,
                                'mimetype': mimetype,
                                'res_model': 'documents.document',
                                'res_id': record.id,
                            })
                            record.with_context(no_document=True).write({'attachment_id': attachment.id})
        except Exception as e:
            _logger.error("Error in DocumentsDocument.write Post-process: %s", e)
            
        return res

    def unlink(self):
        """Delete corresponding MinIO objects when documents are deleted."""
        minio_paths = []
        for record in self:
            if record.minio_object_name:
                minio_paths.append(record.minio_object_name)

        res = super().unlink()

        # Delete from MinIO after successful Odoo deletion
        if minio_paths:
            try:
                config_id = self.env['minio.config'].get_default_config()
                if config_id:
                    config = self.env['minio.config'].browse(config_id)
                    client = config.get_minio_client()
                    bucket = config.get_bucket()
                    for path in minio_paths:
                        try:
                            client.remove_object(bucket, path)
                            _logger.info('Deleted MinIO object: %s', path)
                        except Exception as e:
                            _logger.warning('Failed to delete MinIO object %s: %s', path, e)
            except Exception as e:
                _logger.error('MinIO cleanup failed: %s', e)

        return res

    @api.depends('attachment_id', 'attachment_id.name', 'url', 'minio_object_name', 'mimetype')
    def _compute_name_and_preview(self):
        super()._compute_name_and_preview()
        for record in self:
            if record.minio_object_name:
                # Force name to be the base filename from MinIO path
                clean_name = record.minio_object_name.split('/')[-1]
                record.name = clean_name
                
                # Also ensure the attachment name is updated if it differs
                if record.attachment_id and record.attachment_id.name != clean_name:
                    record.attachment_id.with_context(no_document=True).name = clean_name
                
                if record.mimetype and record.mimetype.startswith('image/'):
                    minio_path = record.minio_object_name if isinstance(record.minio_object_name, str) else ""
                    expected_url = f'{_get_base_url()}/minio/api/download?path={quote(minio_path)}'
                    if record.url != expected_url:
                         record.url = expected_url
                    record.url_preview_image = record.url

    def _guess_minio_mimetype(self, url, name):
        """Guess mimetype from MinIO URL or name"""
        filename = (name or "").strip()
        if 'path=' in url:
            # Extract filename from URL path parameter
            try:
                filename = url.split('path=')[-1].split('&')[0]
            except Exception:
                pass
        
        mimetype = mimetypes.guess_type(filename)[0]
        return mimetype or 'application/octet-stream'

    def _get_folder_path(self, folder):
        """Get full folder path"""
        if not folder:
            return ""
        
        path = []
        current = folder
        while current:
            path.insert(0, current.name)
            current = current.parent_folder_id
        
        return '/'.join(path)


    def get_minio_stream(self):
        """
        Get a stream of the file content from MinIO.
        Returns:
            urllib3.response.HTTPResponse: Stream of the file content.
        Raises:
            UserError: If not synced or connection fails.
        """
        self.ensure_one()
        if not self.minio_object_name:
            return None

        config_id = self.env['minio.config'].get_default_config()
        if not config_id:
            return None
        
        config = self.env['minio.config'].browse(config_id)
        client = config.get_minio_client()
        bucket = config.get_bucket()

        try:
            # Get object returns a stream (urllib3.response.HTTPResponse)
            response = client.get_object(bucket, self.minio_object_name)
            return response
        except Exception as e:
            _logger.error("Failed to get MinIO stream for %s: %s", self.minio_object_name, e)
            return None

    def action_view_preview(self):
        """Open the preview for the document (via Client Action)"""
        self.ensure_one()
        return {
            'type': 'ir.actions.client',
            'tag': 'documents_minio_sync.preview',
            'params': {
                'resId': self.id,
            }
        }