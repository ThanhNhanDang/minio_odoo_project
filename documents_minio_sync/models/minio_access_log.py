from odoo import models, fields, api

class MinioAccessLog(models.Model):
    _name = 'minio.access.log'
    _description = 'MinIO Access Log'
    _order = 'create_date desc'

    name = fields.Char(string='Operation', required=True)
    user_id = fields.Many2one('res.users', string='User', default=lambda self: self.env.user)
    device_id = fields.Many2one('minio.device', string='Device')
    ip_address = fields.Char(string='IP Address')
    user_agent = fields.Char(string='User Agent')
    status = fields.Selection([
        ('success', 'Success'),
        ('failed', 'Failed'),
        ('warning', 'Warning')
    ], string='Status', required=True, default='success')
    details = fields.Text(string='Details')
    timestamp = fields.Datetime(string='Timestamp', default=fields.Datetime.now)
