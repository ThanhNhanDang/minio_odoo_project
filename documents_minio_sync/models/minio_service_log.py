from odoo import models, fields, api

class MinIOServiceLog(models.Model):
    _name = 'minio.service.log'
    _description = 'MinIO Service Log'
    _order = 'create_date desc'

    device_id = fields.Many2one('minio.device', string="Device", required=True, ondelete='cascade')
    level = fields.Selection([
        ('info', 'Info'),
        ('warning', 'Warning'),
        ('error', 'Error')
    ], string="Level", default='error')
    message = fields.Text(string="Message")
    details = fields.Text(string="Details/Stack Trace")
    timestamp = fields.Datetime(string="Client Timestamp")
