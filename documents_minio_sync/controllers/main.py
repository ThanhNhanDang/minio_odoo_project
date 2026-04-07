from odoo import http
from odoo.http import request
from odoo import fields
from odoo.addons.documents.controllers.documents import ShareRoute
import json
import logging
import mimetypes
import re
import unicodedata
from urllib.parse import unquote, quote

_logger = logging.getLogger(__name__)

def sanitize_header(value):
    """Remove non-Latin-1 characters from HTTP header values.
    Werkzeug encodes headers as latin-1; Unicode chars like \\u200b crash it."""
    if not value:
        return value
    # Remove zero-width and other invisible Unicode characters
    value = re.sub(r'[\u200b\u200c\u200d\u200e\u200f\ufeff\u00ad]', '', value)
    # Encode to latin-1, replacing anything that doesn't fit
    return value.encode('latin-1', 'replace').decode('latin-1')


def sanitize_filename(name):
    """Clean a filename for use in Content-Disposition headers."""
    if not name:
        return 'download'
    # Remove zero-width and invisible chars
    name = re.sub(r'[\u200b\u200c\u200d\u200e\u200f\ufeff\u00ad]', '', name)
    # Strip leading/trailing whitespace
    name = name.strip()
    return name or 'download'


def parse_minio_timestamp(ts):
    """Parse ISO timestamp from MinIO Tray App to Odoo format"""
    if not ts:
        return fields.Datetime.now()
    if isinstance(ts, str):
        try:
            from dateutil.parser import parse
            # Parse and convert to naive datetime (Odoo standard)
            return parse(ts).replace(tzinfo=None)
        except Exception:
            try:
                # Fallback for simple Odoo format
                return fields.Datetime.to_datetime(ts)
            except Exception:
                return fields.Datetime.now()
    return ts

class MinioDocumentsOverride(ShareRoute):
    """Override documents download to stream MinIO files directly,
    avoiding mixed-content redirects when behind an HTTPS reverse proxy."""

    def _get_file_response(self, res_id, share_id=None, share_token=None, field='raw', as_attachment=None):
        record = request.env['documents.document'].browse(int(res_id))
        if share_id:
            share = request.env['documents.share'].sudo().browse(int(share_id))
            record = share._get_documents_and_check_access(share_token, [int(res_id)], operation='read')
        if not record or not record.exists():
            raise request.not_found()

        # MinIO documents: stream content directly instead of redirecting
        if record.type == 'url' and record.minio_object_name:
            try:
                stream = record.get_minio_stream()
                if stream:
                    data = stream.read()
                    stream.close()
                    stream.release_conn()

                    mimetype_guess = mimetypes.guess_type(record.minio_object_name)[0] or 'application/octet-stream'
                    filename = sanitize_filename(record.minio_object_name.split('/')[-1])
                    disposition = 'attachment' if as_attachment else 'inline'
                    headers = [
                        ('Content-Type', mimetype_guess),
                        ('Content-Disposition', f'{disposition}; filename="{filename}"'),
                        ('Content-Length', str(len(data))),
                    ]
                    return request.make_response(data, headers=headers)
            except Exception as e:
                _logger.error('MinIO stream failed for doc %s: %s', res_id, e)
                # Fall through to default behavior

        return super()._get_file_response(res_id, share_id=share_id, share_token=share_token, field=field, as_attachment=as_attachment)


class MinioConfigController(http.Controller):
    @http.route('/minio/get_config', type='json', auth='user')
    def get_minio_config(self, **kwargs):
        """
        Return the active MinIO configuration.
        Requires authentication (auth='user').
        """
        try:
            MinioConfig = request.env['minio.config']
            config_id = MinioConfig.get_default_config()
            
            if not config_id:
                return {
                    'status': 'error',
                    'message': 'No active MinIO configuration found in Odoo.'
                }
            
            config = MinioConfig.browse(config_id)
            
            # --- Auto-Register Device ---
            client_id = kwargs.get('client_id')
            if client_id:
                hostname = kwargs.get('hostname', 'Unknown Device')
                ip_address = request.httprequest.remote_addr
                
                device = request.env['minio.device'].sudo().search([('client_id', '=', client_id)], limit=1)
                if not device:
                    device = request.env['minio.device'].sudo().create({
                        'client_id': client_id,
                        'name': hostname,
                        'user_id': request.env.uid,
                        'status': 'online',
                        'last_seen': fields.Datetime.now(),
                        'ip_address': ip_address,
                        'version': 'Tray App' # Placeholder
                    })
                else:
                    device.sudo().write({
                        'name': hostname, # Update hostname if changed
                        'user_id': request.env.uid, # Update user if changed
                        'status': 'online',
                        'last_seen': fields.Datetime.now(),
                        'ip_address': ip_address,
                    })
            # ---------------------------

            bucket = config.get_bucket()
            return {
                'status': 'success',
                'data': {
                    'endpoint': (config.endpoint or "").strip(),
                    'access_key': (config.access_key or "").strip(),
                    'secret_key': (config.secret_key or "").strip(),
                    'bucket_name': bucket,
                    'alias': config.name  # Use config name as alias
                }
            }
        except Exception as e:
            _logger.error(f"Error fetching MinIO config: {str(e)}")
            return {
                'status': 'error',
                'message': f"Internal Server Error: {str(e)}"
            }

    @http.route('/minio/log_access', type='json', auth='user')
    def log_access(self, **kwargs):
        """
        Receive access logs from Tray App.
        Params: name, status, details, ip_address, user_agent, timestamp
        """
        try:
            client_id = kwargs.get('client_id')
            device = request.env['minio.device'].sudo().search([('client_id', '=', client_id)], limit=1)
            
            vals = {
                'name': kwargs.get('name', 'Unknown Operation'),
                'status': kwargs.get('status', 'success'),
                'details': kwargs.get('details', ''),
                'ip_address': kwargs.get('ip_address', request.httprequest.remote_addr),
                'user_agent': kwargs.get('user_agent', request.httprequest.user_agent.string),
                'timestamp': parse_minio_timestamp(kwargs.get('timestamp')),
            }
            if device:
                vals['device_id'] = device.id

            request.env['minio.access.log'].sudo().create(vals)
            return {'status': 'success'}
        except Exception as e:
            _logger.error(f"Error creating access log: {str(e)}")
            return {'status': 'error', 'message': str(e)}

    @http.route('/minio/log_service', type='json', auth='user')
    def log_service(self, **kwargs):
        """
        Receive service error logs from Tray App.
        Params: client_id, level, message, details, timestamp
        """
        try:
            client_id = kwargs.get('client_id')
            device = request.env['minio.device'].search([('client_id', '=', client_id)], limit=1)
            
            # Auto-create device if missing (optional, but good for tracking)
            if not device and client_id:
                device = request.env['minio.device'].create({
                    'client_id': client_id,
                    'name': 'Unknown Device (Log)',
                    'user_id': request.env.uid
                })

            if device:
                request.env['minio.service.log'].sudo().create({
                    'device_id': device.id,
                    'level': kwargs.get('level', 'error'),
                    'message': kwargs.get('message', ''),
                    'details': kwargs.get('details', ''),
                    'timestamp': parse_minio_timestamp(kwargs.get('timestamp')),
                })
            return {'status': 'success'}
        except Exception as e:
            _logger.error(f"Error creating service log: {str(e)}")
            return {'status': 'error', 'message': str(e)}

    @http.route('/minio/sync_metadata', type='json', auth='user')
    def sync_metadata(self, **kwargs):
        """
        Sync document metadata after MinIO upload.
        If document exists: update metadata.
        If document does NOT exist: create new document + folder structure.

        Params: minio_path (required), size, checksum, mimetype, filename, odoo_folder_id
        """
        try:
            _logger.info('=== sync_metadata called === kwargs: %s', kwargs)
            _logger.info('=== sync_metadata user: %s (uid=%s) ===', request.env.user.name, request.env.uid)

            minio_path = kwargs.get('minio_path')
            if not minio_path:
                _logger.warning('sync_metadata: missing minio_path')
                return {'status': 'error', 'message': 'Missing minio_path'}

            # Find existing document by minio_object_name or attachment url
            domain = ['|', ('minio_object_name', '=', minio_path), ('url', 'ilike', minio_path)]
            doc = request.env['documents.document'].search(domain, limit=1)
            _logger.info('sync_metadata: search for existing doc with path=%s → found=%s', minio_path, doc.id if doc else 'NONE')

            if doc:
                # --- UPDATE existing document ---
                vals = {
                    'minio_synced': True,
                    'minio_last_sync': fields.Datetime.now(),
                }
                if doc.attachment_id:
                    att_vals = {}
                    if kwargs.get('checksum'):
                        att_vals['checksum'] = kwargs.get('checksum')
                    if kwargs.get('size'):
                        att_vals['file_size'] = kwargs.get('size')
                    if att_vals:
                        doc.attachment_id.write(att_vals)

                doc.write(vals)
                _logger.info('sync_metadata: UPDATED doc id=%s', doc.id)
                return {'status': 'success', 'document_id': doc.id, 'action': 'updated'}

            # --- CREATE new document ---
            filename = kwargs.get('filename') or minio_path.split('/')[-1]
            mimetype = kwargs.get('mimetype') or 'application/octet-stream'
            size = kwargs.get('size', 0)

            # Determine target folder: explicit odoo_folder_id or auto-create from path
            folder_id = kwargs.get('odoo_folder_id')
            rel_path = kwargs.get('rel_path', '')
            _logger.info('sync_metadata: CREATE mode — filename=%s, mimetype=%s, size=%s, folder_id=%s, rel_path=%s',
                         filename, mimetype, size, folder_id, rel_path)

            if folder_id and rel_path:
                # rel_path e.g. "Screenshots/file1.png" — create subfolders under odoo_folder_id
                folder_id = self._get_or_create_subfolders(folder_id, rel_path)
                _logger.info('sync_metadata: created subfolders from rel_path, final folder_id=%s', folder_id)
            elif not folder_id:
                folder_id = self._get_or_create_folders_from_path(minio_path)
                _logger.info('sync_metadata: auto-created folder_id=%s from path', folder_id)

            # Build internal download URL using correct protocol
            proto = request.httprequest.headers.get('X-Forwarded-Proto', '').strip() or request.httprequest.scheme
            host = request.httprequest.host
            download_url = f'{proto}://{host}/minio/api/download?path={quote(minio_path)}'

            doc_vals = {
                'name': filename,
                'type': 'url',
                'url': download_url,
                'minio_object_name': minio_path,
                'minio_synced': True,
                'minio_last_sync': fields.Datetime.now(),
            }
            if folder_id:
                doc_vals['folder_id'] = folder_id

            _logger.info('sync_metadata: creating document with vals=%s', doc_vals)
            new_doc = request.env['documents.document'].create(doc_vals)

            # Update attachment mimetype and size if attachment was auto-created
            if new_doc.attachment_id:
                att_vals = {'mimetype': mimetype}
                if size:
                    att_vals['file_size'] = size
                new_doc.attachment_id.write(att_vals)

            _logger.info('sync_metadata: CREATED doc id=%s for path=%s in folder=%s', new_doc.id, minio_path, folder_id)
            return {'status': 'success', 'document_id': new_doc.id, 'action': 'created'}
        except Exception as e:
            _logger.error('sync_metadata: EXCEPTION: %s', str(e), exc_info=True)
            return {'status': 'error', 'message': str(e)}

    def _get_or_create_subfolders(self, parent_folder_id, rel_path):
        """
        Create subfolder hierarchy under an existing Odoo folder from a relative path.
        e.g. parent_folder_id=Internal, rel_path="Screenshots/file1.png"
        → creates "Screenshots" folder under Internal, returns its ID.
        Only processes folder parts (excludes the filename at the end).
        """
        parts = rel_path.replace('\\', '/').split('/')
        if len(parts) <= 1:
            # No subfolder in rel_path (just a filename), use parent directly
            return parent_folder_id

        folder_parts = parts[:-1]  # Exclude the filename
        current_parent = parent_folder_id
        Folder = request.env['documents.folder']

        for folder_name in folder_parts:
            if not folder_name:
                continue
            domain = [
                ('name', '=', folder_name),
                ('parent_folder_id', '=', current_parent),
            ]
            folder = Folder.search(domain, limit=1)
            if not folder:
                folder = Folder.create({
                    'name': folder_name,
                    'parent_folder_id': current_parent,
                })
                _logger.info('Created subfolder: %s (parent=%s)', folder_name, current_parent)
            current_parent = folder.id

        return current_parent

    def _get_or_create_folders_from_path(self, minio_path):
        """
        Auto-create Odoo documents.folder hierarchy from a MinIO object path.
        e.g. "project/docs/Q1/report.pdf" → creates folders: project > docs > Q1
        Returns the leaf folder ID, or False if path has no folder components.
        """
        parts = minio_path.split('/')
        if len(parts) <= 1:
            # No folder structure (just a filename at root)
            return False

        folder_parts = parts[:-1]  # Exclude the filename
        parent_id = False
        Folder = request.env['documents.folder']

        for folder_name in folder_parts:
            if not folder_name:
                continue
            domain = [('name', '=', folder_name)]
            if parent_id:
                domain.append(('parent_folder_id', '=', parent_id))
            else:
                domain.append(('parent_folder_id', '=', False))

            folder = Folder.search(domain, limit=1)
            if not folder:
                vals = {'name': folder_name}
                if parent_id:
                    vals['parent_folder_id'] = parent_id
                folder = Folder.create(vals)
                _logger.info('Created folder: %s (parent=%s)', folder_name, parent_id)
            parent_id = folder.id

        return parent_id

    @http.route('/minio/api/bucket', type='http', auth='user')
    def api_bucket(self):
        """Simulate MinIO service /api/bucket"""
        try:
            config_id = request.env['minio.config'].get_default_config()
            if not config_id:
                return request.make_response(json.dumps({"error": "No configuration found"}), [('Content-Type', 'application/json')])
            config = request.env['minio.config'].browse(config_id)
            data = {
                "bucket": config.get_bucket(),
                "alias": config.name
            }
            return request.make_response(json.dumps(data), [('Content-Type', 'application/json')])
        except Exception as e:
            return request.make_response(json.dumps({"error": str(e)}), [('Content-Type', 'application/json')])

    @http.route('/minio/api/list', type='http', auth='user')
    def api_list(self, path="", **kwargs):
        """Simulate MinIO service /api/list"""
        try:
            path = (path or "").strip().lstrip("/")
            prefix = (path + "/") if path else ""
            
            config_id = request.env['minio.config'].get_default_config()
            if not config_id:
                return request.make_response(json.dumps({"error": "No configuration found"}), [('Content-Type', 'application/json')])
            
            config = request.env['minio.config'].browse(config_id)
            client = config.get_minio_client()
            
            # List objects
            bucket = config.get_bucket()
            objects = client.list_objects(bucket, prefix=prefix, recursive=False)
            items = []
            for obj in objects:
                # obj.object_name is the full path
                full_path = obj.object_name.rstrip("/")
                name = obj.object_name[len(prefix):].rstrip("/")
                
                if not name: continue
                
                items.append({
                    "name": name,
                    "type": "folder" if obj.is_dir else "file",
                    "size": obj.size,
                    "lastModified": obj.last_modified.isoformat() if obj.last_modified else "",
                    "path": full_path
                })
            return request.make_response(json.dumps(items), [('Content-Type', 'application/json')])
        except Exception as e:
            _logger.error(f"MinIO API List Error: {str(e)}")
            return request.make_response(json.dumps({"error": str(e)}), [('Content-Type', 'application/json')])


    @http.route('/minio/api/download', type='http', auth='user', methods=['GET'])
    def api_download(self, path=None, **kwargs):
        """Stream file from MinIO with Range support. Never loads entire file into RAM."""
        from werkzeug.wrappers import Response as WerkzeugResponse

        if not path:
            return request.make_response(
                json.dumps({'error': 'No path provided'}),
                headers=[('Content-Type', 'application/json')],
                status=400
            )

        path = unquote(path).strip().lstrip('/')
        CHUNK_SIZE = 1024 * 1024  # 1 MB chunks for streaming

        try:
            config_id = request.env['minio.config'].get_default_config()
            if not config_id:
                return request.make_response(
                    json.dumps({'error': 'MinIO not configured'}),
                    headers=[('Content-Type', 'application/json')],
                    status=500
                )

            config = request.env['minio.config'].browse(config_id)
            client = config.get_minio_client()
            bucket_name = config.get_bucket()

            _logger.info('Download: bucket=%s, path=%s, endpoint=%s',
                         bucket_name, path, config.backend_endpoint or config.endpoint)

            # stat_object to get total size (needed for Range + Content-Length)
            try:
                stat = client.stat_object(bucket_name, path)
                total_size = stat.size
            except Exception as stat_err:
                _logger.error('stat_object failed for bucket=%s path=%s: %s', bucket_name, path, stat_err)
                return request.make_response(
                    json.dumps({'error': f'File not found: {path}'}),
                    headers=[('Content-Type', 'application/json')],
                    status=404
                )

            mimetype = mimetypes.guess_type(path)[0] or 'application/octet-stream'
            filename = sanitize_filename(path.split('/')[-1])

            def stream_minio(offset, length):
                """Generator that streams chunks from MinIO without loading all into RAM."""
                resp = client.get_object(bucket_name, path, offset=offset, length=length)
                try:
                    remaining = length
                    while remaining > 0:
                        chunk_size = min(CHUNK_SIZE, remaining)
                        chunk = resp.read(chunk_size)
                        if not chunk:
                            break
                        remaining -= len(chunk)
                        yield chunk
                finally:
                    resp.close()
                    resp.release_conn()

            # Parse Range header
            range_header = request.httprequest.headers.get('Range')
            if range_header and range_header.startswith('bytes='):
                parts = range_header[6:].split('-')
                start = int(parts[0]) if parts[0] else 0
                end = int(parts[1]) if len(parts) > 1 and parts[1] else total_size - 1
                end = min(end, total_size - 1)
                length = end - start + 1

                headers = {
                    'Content-Type': sanitize_header(mimetype),
                    'Content-Disposition': f'inline; filename="{filename}"',
                    'Content-Range': f'bytes {start}-{end}/{total_size}',
                    'Content-Length': str(length),
                    'Accept-Ranges': 'bytes',
                    'Cache-Control': 'public, max-age=3600',
                }
                return WerkzeugResponse(
                    stream_minio(start, length),
                    status=206,
                    headers=headers,
                    direct_passthrough=True,
                )

            # Full download — still streamed, never loaded entirely into RAM
            headers = {
                'Content-Type': sanitize_header(mimetype),
                'Content-Disposition': f'inline; filename="{filename}"',
                'Content-Length': str(total_size),
                'Accept-Ranges': 'bytes',
                'Cache-Control': 'public, max-age=3600',
            }
            return WerkzeugResponse(
                stream_minio(0, total_size),
                status=200,
                headers=headers,
                direct_passthrough=True,
            )

        except Exception as e:
            _logger.error('MinIO Download Error: %s', e, exc_info=True)
            return request.make_response(
                json.dumps({'error': str(e)}),
                headers=[('Content-Type', 'application/json')],
                status=500
            )

    @http.route('/minio/api/thumbnail', type='http', auth='user', methods=['GET'])
    def api_thumbnail(self, path=None, **kwargs):
        """Generate video thumbnail using ffmpeg. Returns JPEG image."""
        import subprocess
        import tempfile

        if not path:
            return request.make_response(b'', status=400)

        path = unquote(path).strip().lstrip('/')
        mimetype = mimetypes.guess_type(path)[0] or ''

        # Only generate thumbnails for video files
        if not mimetype.startswith('video/'):
            return request.make_response(b'', status=404)

        try:
            config_id = request.env['minio.config'].get_default_config()
            if not config_id:
                return request.make_response(b'', status=500)

            config = request.env['minio.config'].browse(config_id)
            client = config.get_minio_client()
            bucket_name = config.get_bucket()

            # Download first 5MB of video (enough for ffmpeg to extract a frame)
            resp = client.get_object(bucket_name, path, offset=0, length=5 * 1024 * 1024)
            video_head = resp.read()
            resp.close()
            resp.release_conn()

            with tempfile.NamedTemporaryFile(suffix='.mp4', delete=False) as tmp_in:
                tmp_in.write(video_head)
                tmp_in_path = tmp_in.name

            tmp_out_path = tmp_in_path + '.jpg'

            try:
                # Extract frame at 1 second, resize to 320px width
                result = subprocess.run([
                    'ffmpeg', '-i', tmp_in_path,
                    '-ss', '00:00:01', '-vframes', '1',
                    '-vf', 'scale=320:-1',
                    '-f', 'image2', '-y', tmp_out_path
                ], capture_output=True, timeout=10)

                if result.returncode == 0:
                    import os
                    with open(tmp_out_path, 'rb') as f:
                        thumb_data = f.read()
                    os.unlink(tmp_in_path)
                    os.unlink(tmp_out_path)

                    return request.make_response(thumb_data, headers=[
                        ('Content-Type', 'image/jpeg'),
                        ('Cache-Control', 'public, max-age=86400'),
                    ])
                else:
                    _logger.debug('ffmpeg thumbnail failed: %s', result.stderr[:200])
            except FileNotFoundError:
                _logger.debug('ffmpeg not installed — no video thumbnails')
            except Exception as e:
                _logger.debug('thumbnail generation error: %s', e)
            finally:
                import os
                for p in [tmp_in_path, tmp_out_path]:
                    try:
                        os.unlink(p)
                    except Exception:
                        pass

            return request.make_response(b'', status=404)

        except Exception as e:
            _logger.error('Thumbnail error: %s', e)
            return request.make_response(b'', status=500)

    @http.route('/minio/api/delete', type='http', auth='user', methods=['POST'], csrf=False)
    def api_delete(self):
        """Simulate MinIO service /api/delete"""
        try:
            data = request.get_json_data() if request.httprequest.is_json else json.loads(request.httprequest.data)
            path = data.get("path")
            is_folder = data.get("is_folder", False)
            
            if not path:
                return request.make_response(json.dumps({"success": False, "error": "Missing path"}), [('Content-Type', 'application/json')])

            config_id = request.env['minio.config'].get_default_config()
            config = request.env['minio.config'].browse(config_id)
            client = config.get_minio_client()
            bucket = config.get_bucket()

            if is_folder:
                # MinIO Python client doesn't have recursive delete like 'mc rm'.
                # We must list and delete each object.
                objects_to_delete = client.list_objects(bucket, prefix=path.strip("/") + "/", recursive=True)
                for obj in objects_to_delete:
                    client.remove_object(bucket, obj.object_name)
            else:
                client.remove_object(bucket, path)
            
            return request.make_response(json.dumps({"success": True}), [('Content-Type', 'application/json')])
        except Exception as e:
            _logger.error(f"MinIO API Delete Error: {str(e)}")
            return request.make_response(json.dumps({"success": False, "error": str(e)}), [('Content-Type', 'application/json')])

    @http.route('/minio/api/download_zip', type='http', auth='user', methods=['POST'], csrf=False)
    def api_download_zip(self):
        """Simulate MinIO service /api/download_zip"""
        import io
        import zipfile
        import werkzeug.wrappers
        
        try:
            data = request.get_json_data() if request.httprequest.is_json else json.loads(request.httprequest.data)
            paths = data.get("paths", [])
            if not paths:
                return werkzeug.wrappers.Response(json.dumps({"error": "No paths provided"}), status=400, content_type='application/json')

            config_id = request.env['minio.config'].get_default_config()
            config = request.env['minio.config'].browse(config_id)
            client = config.get_minio_client()
            bucket = config.get_bucket()

            in_memory_zip = io.BytesIO()
            with zipfile.ZipFile(in_memory_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
                for path in paths:
                    path = path.strip("/")
                    # Check if it's a folder (ends with / in names or we list it)
                    # For simplicity, we list with prefix
                    objects = client.list_objects(bucket, prefix=path, recursive=True)
                    for obj in objects:
                        if obj.is_dir: continue
                        # Get object
                        res = client.get_object(bucket, obj.object_name)
                        try:
                            # Reconstruct relative path for zip
                            # If path was a folder, we want to keep structure from that folder
                            # If path was a file, we want it at root of zip? 
                            # Let's match Tray App logic: 
                            # If multiple items, use timestamp for zip name.
                            # If single folder, name zip after folder.
                            rel_path = obj.object_name
                            if len(paths) == 1 and paths[0] in obj.object_name:
                                # Strip the parent part if it's a single folder download
                                parent = "/".join(paths[0].split("/")[:-1])
                                if parent: rel_path = obj.object_name[len(parent):].lstrip("/")
                            
                            zf.writestr(rel_path, res.read())
                        finally:
                            res.close()
                            res.release_conn()

            in_memory_zip.seek(0)
            
            # Determine zip filename
            filename = "minio_download.zip"
            if len(paths) == 1:
                filename = sanitize_filename(f"{paths[0].split('/')[-1]}.zip")
            
            headers = [
                ('Content-Type', 'application/zip'),
                ('Content-Disposition', f'attachment; filename="{filename}"'),
            ]
            
            return werkzeug.wrappers.Response(in_memory_zip, headers=headers)
            
        except Exception as e:
            _logger.error(f"MinIO API Zip Error: {str(e)}")
            return werkzeug.wrappers.Response(json.dumps({"error": str(e)}), status=500, content_type='application/json')
