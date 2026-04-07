class AppConfig {
  final String odooUrl;
  final String odooDb;
  final String clientId;
  final String listenAddr;
  final String hostname;
  final String version;

  AppConfig({
    this.odooUrl = '',
    this.odooDb = '',
    this.clientId = '',
    this.listenAddr = ':9999',
    this.hostname = 'MobileClient',
    this.version = '1.0.0',
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      odooUrl: json['odoo_url'] ?? '',
      odooDb: json['odoo_db'] ?? '',
      clientId: json['client_id'] ?? '',
      listenAddr: json['listen_addr'] ?? ':9999',
      hostname: json['hostname'] ?? 'MobileClient',
      version: json['version'] ?? '1.0.0',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'odoo_url': odooUrl,
      'odoo_db': odooDb,
      'client_id': clientId,
      'listen_addr': listenAddr,
      'hostname': hostname,
      'version': version,
    };
  }

  AppConfig copyWith({
    String? odooUrl,
    String? odooDb,
    String? clientId,
    String? listenAddr,
    String? hostname,
    String? version,
  }) {
    return AppConfig(
      odooUrl: odooUrl ?? this.odooUrl,
      odooDb: odooDb ?? this.odooDb,
      clientId: clientId ?? this.clientId,
      listenAddr: listenAddr ?? this.listenAddr,
      hostname: hostname ?? this.hostname,
      version: version ?? this.version,
    );
  }
}
