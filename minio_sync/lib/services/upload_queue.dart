import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import '../models/upload_task.dart';
import 'minio_service.dart';
import '../utils/logger.dart';

/// Represents a file entry to upload with its local and relative paths.
class _FileEntry {
  final String localPath;
  final String relPath; // relative path preserving folder structure

  _FileEntry(this.localPath, this.relPath);
}

class UploadQueue {
  final MinioService minioService;
  final Queue<UploadTask> _queue = Queue();
  final Map<String, UploadTask> _activeTasks = {};
  bool _isProcessing = false;

  UploadQueue(this.minioService);

  UploadTask addTask(UploadTask task) {
    _activeTasks[task.id] = task;
    _queue.add(task);
    _processQueue();
    return task;
  }

  UploadTask? getTask(String id) => _activeTasks[id];

  List<UploadTask> getAllTasks() => _activeTasks.values.toList();

  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;
    _isProcessing = true;

    while (_queue.isNotEmpty) {
      final task = _queue.removeFirst();
      if (task.status == UploadStatus.canceled) continue;

      task.updateProgress(0, UploadStatus.uploading, info: 'Collecting files...');

      try {
        await _runUpload(task);
      } catch (e) {
        appLogger.e('Task ${task.id} failed', error: e);
        if (task.status != UploadStatus.error && task.status != UploadStatus.canceled) {
          task.updateProgress(task.percentCompleted, UploadStatus.error, info: e.toString());
        }
      }
    }

    _isProcessing = false;
  }

  /// Main upload engine — mirrors Go service's upload.Engine.Run()
  Future<void> _runUpload(UploadTask task) async {
    // --- Phase 1: Collect all files with relative paths ---
    final files = <_FileEntry>[];
    for (final path in task.localPaths) {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.directory) {
        // Walk directory recursively (like Go's filepath.Walk)
        final dir = Directory(path);
        final dirName = p.basename(path);
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            // Compute relative path from parent of uploaded dir
            // e.g. uploaded dir = C:\Docs\Reports => rel = Reports/Q1/sales.pdf
            final rel = p.relative(entity.path, from: p.dirname(path));
            final relForward = rel.replaceAll('\\', '/');
            files.add(_FileEntry(entity.path, relForward.isNotEmpty ? relForward : '$dirName/${p.basename(entity.path)}'));
          }
        }
      } else if (stat.type == FileSystemEntityType.file) {
        files.add(_FileEntry(path, p.basename(path)));
      } else {
        appLogger.w('Skipping non-file/dir: $path');
      }
    }

    final total = files.length;
    if (total == 0) {
      appLogger.i('Task ${task.id}: no files to upload');
      task.updateProgress(100, UploadStatus.done, info: 'No files found');
      return;
    }

    // --- Phase 2: Calculate total bytes for cumulative progress ---
    int totalBytes = 0;
    for (final fe in files) {
      try {
        totalBytes += await File(fe.localPath).length();
      } catch (_) {}
    }

    appLogger.i('Task ${task.id}: uploading $total files ($totalBytes bytes) to ${task.remotePath}');

    // --- Phase 3: Upload each file with per-byte progress ---
    final prefix = task.remotePath.endsWith('/') ? task.remotePath.substring(0, task.remotePath.length - 1) : task.remotePath;
    int bytesUploaded = 0;
    int uploadedCount = 0;

    for (int i = 0; i < files.length; i++) {
      if (task.status == UploadStatus.canceled) {
        appLogger.i('Task ${task.id}: canceled');
        return;
      }

      final fe = files[i];
      final objectName = _buildObjectName(prefix, fe.relPath);

      try {
        await minioService.uploadFileWithProgress(
          fe.localPath,
          objectName,
          onBytesUploaded: (int n) {
            bytesUploaded += n;
            double pct = 0;
            if (totalBytes > 0) {
              pct = (bytesUploaded / totalBytes * 100).floorToDouble();
              pct = min(pct, 100);
            }
            task.updateProgress(pct, UploadStatus.uploading,
                info: '${_formatBytes(bytesUploaded)} / ${_formatBytes(totalBytes)}');
          },
        );

        task.uploadedPaths.add(objectName);
        uploadedCount++;

        double pct = totalBytes > 0 ? (bytesUploaded / totalBytes * 100).floorToDouble() : 100;
        pct = min(pct, 100);
        task.updateProgress(pct, UploadStatus.uploading,
            info: 'uploaded ${i + 1}/$total: ${p.basename(fe.localPath)}');
      } catch (e) {
        appLogger.e('Task ${task.id}: failed to upload ${fe.localPath}', error: e);
        // Account for skipped file size so progress doesn't jump backwards
        try {
          bytesUploaded += await File(fe.localPath).length();
        } catch (_) {}

        double pct = totalBytes > 0 ? (bytesUploaded / totalBytes * 100).floorToDouble() : 0;
        task.updateProgress(min(pct, 100), UploadStatus.uploading,
            info: 'error on ${p.basename(fe.localPath)}');
      }
    }

    // --- Phase 4: Best-effort sync metadata to Odoo ---
    await _syncMetadataToOdoo(task);

    // --- Phase 5: Final status ---
    if (uploadedCount == 0 && total > 0) {
      task.updateProgress(100, UploadStatus.error, info: 'All $total file(s) failed to upload');
    } else if (uploadedCount < total) {
      final failed = total - uploadedCount;
      task.updateProgress(100, UploadStatus.done, info: '$failed of $total file(s) failed');
    } else {
      task.updateProgress(100, UploadStatus.done, info: 'Success');
    }

    appLogger.i('Task ${task.id}: upload complete ($uploadedCount/$total files)');
  }

  /// Build MinIO object key from prefix and relative path.
  String _buildObjectName(String prefix, String relPath) {
    final rel = relPath.replaceAll('\\', '/');
    if (prefix.isEmpty) return rel;
    return '$prefix/$rel';
  }

  /// Sync uploaded file metadata to Odoo via /minio/sync_metadata.
  Future<void> _syncMetadataToOdoo(UploadTask task) async {
    if (task.odooSession.isEmpty) {
      appLogger.i('Task ${task.id}: no Odoo session — skipping metadata sync');
      return;
    }

    // We need the Odoo URL from somewhere — read from config on disk
    String odooUrl = '';
    try {
      final exePath = Platform.resolvedExecutable;
      final configPath = '${File(exePath).parent.path}/config.json';
      final file = File(configPath);
      if (await file.exists()) {
        final config = jsonDecode(await file.readAsString());
        odooUrl = config['odoo_url'] ?? '';
      }
    } catch (_) {}

    if (odooUrl.isEmpty) {
      appLogger.w('Task ${task.id}: odoo_url not configured, skipping metadata sync');
      return;
    }

    final client = HttpClient();
    try {
      for (final objectName in task.uploadedPaths) {
        if (task.status == UploadStatus.canceled) return;

        final parts = objectName.split('/');
        final filename = parts.last;

        final params = <String, dynamic>{
          'minio_path': objectName,
          'filename': filename,
          'mimetype': _detectContentType(filename),
        };
        if (task.odooFolderId != null && task.odooFolderId! > 0) {
          params['odoo_folder_id'] = task.odooFolderId;
        }

        final body = jsonEncode({
          'jsonrpc': '2.0',
          'method': 'call',
          'params': params,
        });

        try {
          final endpoint = '${odooUrl.replaceAll(RegExp(r'/+$'), '')}/minio/sync_metadata';
          final request = await client.postUrl(Uri.parse(endpoint));
          request.headers.set('Content-Type', 'application/json');
          request.headers.set('Cookie', 'session_id=${task.odooSession}');
          request.write(body);
          final response = await request.close();
          final responseBody = await response.transform(utf8.decoder).join();

          appLogger.i('syncMetadata: $objectName -> HTTP ${response.statusCode}');
          if (response.statusCode >= 400) {
            appLogger.e('syncMetadata error: $responseBody');
          }
        } catch (e) {
          appLogger.e('syncMetadata failed for $objectName', error: e);
        }
      }
    } finally {
      client.close();
    }
  }

  /// Human-readable byte count (e.g. "1.5 GB").
  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    if (bytes < 1024) return '$bytes B';
    int exp = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && exp < units.length - 1) {
      size /= 1024;
      exp++;
    }
    return '${size.toStringAsFixed(1)} ${units[exp]}';
  }

  /// Detect MIME type from file extension.
  String _detectContentType(String filename) {
    final ext = p.extension(filename).toLowerCase();
    const mimeMap = {
      '.pdf': 'application/pdf',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.svg': 'image/svg+xml',
      '.mp4': 'video/mp4',
      '.mp3': 'audio/mpeg',
      '.json': 'application/json',
      '.xml': 'application/xml',
      '.txt': 'text/plain',
      '.html': 'text/html',
      '.htm': 'text/html',
      '.csv': 'text/csv',
      '.zip': 'application/zip',
      '.doc': 'application/msword',
      '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.xls': 'application/vnd.ms-excel',
      '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.ppt': 'application/vnd.ms-powerpoint',
      '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    };
    return mimeMap[ext] ?? 'application/octet-stream';
  }

  bool removeTask(String id) {
    return _activeTasks.remove(id) != null;
  }

  void cancelTask(String id) {
    final task = _activeTasks[id];
    if (task != null && task.status != UploadStatus.done && task.status != UploadStatus.error) {
      task.updateProgress(task.percentCompleted, UploadStatus.canceled, info: 'Canceled by user');
    }
  }
}
