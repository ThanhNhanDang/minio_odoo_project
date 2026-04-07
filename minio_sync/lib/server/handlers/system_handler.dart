import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import '../../services/minio_service.dart';
import '../../models/app_config.dart';

class SystemHandler {
  final MinioService minioService;
  final AppConfig Function() getAppConfig;

  SystemHandler(this.minioService, this.getAppConfig);

  Future<Response> handleStatus(Request request) async {
    final config = getAppConfig();
    return Response.ok(
      jsonEncode({
        'client_id': config.clientId,
        'minio_connected': minioService.isConnected,
        'hostname': config.hostname.isNotEmpty ? config.hostname : Platform.localHostname,
        'ip': _getLocalIp(),
        'version': config.version,
        'listen_addr': config.listenAddr,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  String _getLocalIp() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '127.0.0.1';
    }
  }
}
