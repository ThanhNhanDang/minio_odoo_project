from odoo import models, fields, api
    
class MinIODevice(models.Model):
    _name = 'minio.device'
    _description = 'MinIO Client Device'
    _order = 'last_seen desc'

    name = fields.Char(string="Device Name", required=True)
    client_id = fields.Char(string="Client ID", required=True, index=True, copy=False)
    user_id = fields.Many2one('res.users', string="Linked User")
    status = fields.Selection([
        ('online', 'Online'),
        ('offline', 'Offline')
    ], string="Status", default='offline')
    
    last_seen = fields.Datetime(string="Last Seen")
    version = fields.Char(string="App Version")
    ip_address = fields.Char(string="IP Address")
    
    log_ids = fields.One2many('minio.service.log', 'device_id', string="Logs")
    access_log_ids = fields.One2many('minio.access.log', 'device_id', string="Access Logs")

    _sql_constraints = [
        ('client_id_unique', 'unique(client_id)', 'Client ID must be unique per device!')
    ]

    @api.model
    def update_heartbeat(self, client_id, data):
        """Update device status from client heartbeat"""
        device = self.search([('client_id', '=', client_id)], limit=1)
        
        # If offline and device not found, ignore? No, maybe create it as offline
        if not device:
            device = self.create({
                'client_id': client_id,
                'name': data.get('hostname', 'Unknown Device'),
                'user_id': self.env.uid,
                'status': 'offline' # Default to offline until proven online
            })
        
        raw_status = data.get('status', 'online')
        status = 'online' if raw_status in ('online', 'running') else 'offline'
        
        vals = {
            'status': status,
            'last_seen': fields.Datetime.now()
        }
        
        # Only update info if online
        if data.get('status') == 'online':
             vals.update({
                'version': data.get('version'),
                'ip_address': data.get('ip')
             })

        device.write(vals)
        # Notify Bus for dynamic rendering
        self.env['bus.bus']._sendone('minio.device.updated', 'status_changed', {
            'device_id': device.id,
            'status': status
        })
        return device.id

    def action_check_all(self, *args, **kwargs):
        """Check status for all devices"""
        devices = self.search([])
        for device in devices:
            if device.user_id:
                device.action_check_status()
        
        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'title': 'Status Check Initiated',
                'message': f'Ping sent to {len(devices)} devices. Updates will appear in real-time.',
                'type': 'info',
                'sticky': False,
            }
        }

    def action_check_status(self):
        """Trigger status check for this device via Bus"""
        self.ensure_one()
        if not self.user_id:
            return
            
        payload = {
            'action': 'check_status',
            'client_id': self.client_id
        }
        # Send signal to the user's browser
        self.env['bus.bus']._sendone(self.user_id.partner_id, 'minio.check.status', payload)
        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'title': 'Status Check Initiated',
                'message': f'Ping sent to {self.name}. Updates will appear in real-time.',
                'type': 'info',
                'sticky': False,
            }
        }
