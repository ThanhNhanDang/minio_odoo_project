import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import '../../services/minio_service.dart';
import '../../models/minio_config.dart';
import '../../models/app_config.dart';
import '../../utils/logger.dart';

class ConfigHandler {
  final MinioService minioService;
  AppConfig appConfig;
  MinioConfig minioConfig;

  ConfigHandler(this.minioService, this.appConfig, this.minioConfig);

  Future<Response> handleAutoSet(Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      appConfig = appConfig.copyWith(
        odooUrl: data['url'] ?? appConfig.odooUrl,
        odooDb: data['db'] ?? appConfig.odooDb,
      );

      minioConfig = MinioConfig(
        endpoint: data['minio_endpoint'] ?? minioConfig.endpoint,
        accessKey: data['minio_access_key'] ?? minioConfig.accessKey,
        secretKey: data['minio_secret_key'] ?? minioConfig.secretKey,
        bucket: data['minio_bucket'] ?? minioConfig.bucket,
        secure: data['minio_secure'] ?? minioConfig.secure,
      );

      appLogger.i('Config auto_set: endpoint=${minioConfig.endpoint}, bucket=${minioConfig.bucket}');

      // Persist config to disk so UI and restarts pick it up
      await persistConfig();

      // Connect to MinIO with new config
      minioService.connect(minioConfig);

      return Response.ok(
        jsonEncode({'provisioned': minioService.isConnected}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('Config auto_set failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// GET /api/config — return current config (for UI polling)
  Future<Response> handleGetConfig(Request request) async {
    return Response.ok(
      jsonEncode({
        'odoo_url': appConfig.odooUrl,
        'odoo_db': appConfig.odooDb,
        'minio_endpoint': minioConfig.endpoint,
        'minio_bucket': minioConfig.bucket,
        'minio_secure': minioConfig.secure,
        'minio_connected': minioService.isConnected,
        'version': appConfig.version,
        'hostname': appConfig.hostname,
        'listen_addr': appConfig.listenAddr,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// GET /api/bucket — return current bucket info (used by Odoo test connection)
  Future<Response> handleGetBucket(Request request) async {
    return Response.ok(
      jsonEncode({
        'bucket': minioConfig.bucket.isNotEmpty ? minioConfig.bucket : 'odoo-documents',
        'alias': 'minio',
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<void> persistConfig() async {
    try {
      final exePath = Platform.resolvedExecutable;
      final configPath = '${File(exePath).parent.path}/config.json';
      final file = File(configPath);

      // Merge with existing file content
      Map<String, dynamic> existing = {};
      if (await file.exists()) {
        try {
          existing = jsonDecode(await file.readAsString());
        } catch (_) {}
      }

      existing.addAll(appConfig.toJson());
      existing.addAll(minioConfig.toJson());

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(existing),
      );
      appLogger.i('Config persisted to $configPath');
    } catch (e) {
      appLogger.e('Failed to persist config', error: e);
    }
  }
}
