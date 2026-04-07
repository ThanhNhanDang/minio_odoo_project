import 'dart:io';
import 'dart:typed_data';
import 'package:minio_new/minio.dart';
import '../models/minio_config.dart';
import '../models/upload_task.dart';
import '../utils/logger.dart';

class MinioService {
  Minio? _minio;
  String? _bucket;
  bool isConnected = false;

  void connect(MinioConfig config) {
    try {
      final hostPort = config.endpoint.replaceFirst('https://', '').replaceFirst('http://', '');
      var host = hostPort;
      int? port;

      if (hostPort.contains(':')) {
        final parts = hostPort.split(':');
        host = parts[0];
        port = int.tryParse(parts[1]);
      }

      _minio = Minio(
        endPoint: host,
        port: port,
        accessKey: config.accessKey,
        secretKey: config.secretKey,
        useSSL: config.secure || config.endpoint.startsWith('https'),
      );
      _bucket = config.bucket;
      isConnected = true;
      appLogger.i('MinIO initialized at ${config.endpoint}');
    } catch (e) {
      isConnected = false;
      appLogger.e('Failed to initialize MinIO client', error: e);
    }
  }

  /// Upload a single file to MinIO with per-byte progress callback.
  /// [onBytesUploaded] is called with number of bytes read on each chunk.
  /// Returns the actual object name used in MinIO.
  Future<String> uploadFileWithProgress(
    String localPath,
    String objectName, {
    void Function(int bytesRead)? onBytesUploaded,
  }) async {
    if (_minio == null || _bucket == null) {
      throw Exception('MinIO not connected');
    }

    final file = File(localPath);
    if (!await file.exists()) {
      throw Exception('File not found: $localPath');
    }

    final size = await file.length();
    appLogger.i('Uploading $localPath to $objectName ($size bytes)');

    final stream = file.openRead();
    final progressStream = stream.map((chunk) {
      if (onBytesUploaded != null) {
        onBytesUploaded(chunk.length);
      }
      return Uint8List.fromList(chunk);
    });

    await _minio!.putObject(
      _bucket!,
      objectName,
      progressStream,
      size: size,
    );

    appLogger.i('Upload complete: $objectName');
    return objectName;
  }

  /// Legacy upload method for backward compatibility.
  Future<void> uploadFile(String localPath, String remotePath, UploadTask task) async {
    if (_minio == null || _bucket == null) {
      throw Exception('MinIO not connected');
    }

    final file = File(localPath);
    if (!await file.exists()) {
      throw Exception('File not found: $localPath');
    }

    final size = await file.length();
    appLogger.i('Uploading $localPath to $remotePath ($size bytes)');

    final stream = file.openRead();
    int uploaded = 0;
    final progressStream = stream.map((chunk) {
      uploaded += chunk.length;
      final percent = size > 0 ? (uploaded / size * 100) : 100.0;
      task.updateProgress(percent, UploadStatus.uploading, info: 'Uploading $localPath');
      return Uint8List.fromList(chunk);
    });

    try {
      await _minio!.putObject(
        _bucket!,
        remotePath,
        progressStream,
        size: size,
      );
      task.updateProgress(100, UploadStatus.done, info: 'Success');
      appLogger.i('Upload complete: $remotePath');
    } catch (e) {
      task.updateProgress(task.percentCompleted, UploadStatus.error, info: e.toString());
      appLogger.e('Upload error', error: e);
      rethrow;
    }
  }

  Future<void> deleteObject(String path, {bool recursive = false}) async {
    if (_minio == null || _bucket == null) {
      throw Exception('MinIO not connected');
    }

    if (recursive) {
      final prefix = path.endsWith('/') ? path : '$path/';
      final objects = await _minio!.listObjectsV2(_bucket!, prefix: prefix, recursive: true).toList();
      for (var page in objects) {
        for (var obj in page.objects) {
          if (obj.key != null) {
            await _minio!.removeObject(_bucket!, obj.key!);
          }
        }
      }
      appLogger.i('Deleted folder: $prefix');
    } else {
      await _minio!.removeObject(_bucket!, path);
      appLogger.i('Deleted object: $path');
    }
  }

  Future<List<Map<String, dynamic>>> listObjects(String prefix) async {
    if (_minio == null || _bucket == null) return [];

    List<Map<String, dynamic>> items = [];
    try {
      final objects = await _minio!.listObjectsV2(_bucket!, prefix: prefix).toList();
      for (var page in objects) {
        for (var obj in page.objects) {
          items.add({
            'key': obj.key,
            'size': obj.size,
            'lastModified': obj.lastModified?.toIso8601String(),
          });
        }
      }
    } catch (e) {
      appLogger.e('List error', error: e);
    }
    return items;
  }
}
