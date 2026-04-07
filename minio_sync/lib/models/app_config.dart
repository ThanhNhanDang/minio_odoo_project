class AppConfig {
  final String odooUrl;
  final String odooDb;
  final String clientId;
  final String listenAddr;
  final String hostname;
  final String version;
  final String updateUrl;
  final String githubToken;

  AppConfig({
    this.odooUrl = '',
    this.odooDb = '',
    this.clientId = '',
    this.listenAddr = ':9999',
    this.hostname = 'MobileClient',
    this.version = '1.0.0',
    this.updateUrl = 'ThanhNhanDang/minio_odoo_project',
    this.githubToken = '',
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      odooUrl: json['odoo_url'] ?? '',
      odooDb: json['odoo_db'] ?? '',
      clientId: json['client_id'] ?? '',
      listenAddr: json['listen_addr'] ?? ':9999',
      hostname: json['hostname'] ?? 'MobileClient',
      version: json['version'] ?? '1.0.0',
      updateUrl: json['update_url'] ?? 'ThanhNhanDang/minio_odoo_project',
      githubToken: json['github_token'] ?? '',
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
      'update_url': updateUrl,
      'github_token': githubToken,
    };
  }

  AppConfig copyWith({
    String? odooUrl,
    String? odooDb,
    String? clientId,
    String? listenAddr,
    String? hostname,
    String? version,
    String? updateUrl,
    String? githubToken,
  }) {
    return AppConfig(
      odooUrl: odooUrl ?? this.odooUrl,
      odooDb: odooDb ?? this.odooDb,
      clientId: clientId ?? this.clientId,
      listenAddr: listenAddr ?? this.listenAddr,
      hostname: hostname ?? this.hostname,
      version: version ?? this.version,
      updateUrl: updateUrl ?? this.updateUrl,
      githubToken: githubToken ?? this.githubToken,
    );
  }
}
