import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../../services/minio_service.dart';
import '../../utils/logger.dart';

class FileHandler {
  final MinioService minioService;

  FileHandler(this.minioService);

  /// GET /api/list?path=prefix
  Future<Response> handleList(Request request) async {
    final path = request.url.queryParameters['path'] ?? '';

    if (!minioService.isConnected) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'MinIO not connected'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final items = await minioService.listObjects(path);
      return Response.ok(
        jsonEncode(items),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('List objects failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// POST /api/delete { path, is_folder }
  Future<Response> handleDelete(Request request) async {
    if (!minioService.isConnected) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'MinIO not connected'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);
      final path = data['path'] ?? '';
      final isFolder = data['is_folder'] ?? false;

      if (path.isEmpty) {
        return Response(400,
          body: jsonEncode({'error': 'path is required'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      await minioService.deleteObject(path, recursive: isFolder);

      return Response.ok(
        jsonEncode({'success': true}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('Delete failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// POST /api/download_async { paths }
  Future<Response> handleDownloadAsync(Request request) async {
    // Stub — marks task as complete immediately (same as Go service)
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);
      final paths = List<String>.from(data['paths'] ?? []);

      appLogger.i('download_async requested for ${paths.length} path(s)');

      return Response.ok(
        jsonEncode({
          'success': true,
          'task_id': 'download_stub',
          'message': 'Download async not yet implemented',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }
}
