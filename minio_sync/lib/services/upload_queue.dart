import 'dart:collection';
import 'dart:io';
import '../models/upload_task.dart';
import 'minio_service.dart';
import '../utils/logger.dart';

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
      if (task.status == UploadStatus.canceled) {
        continue;
      }
      
      task.updateProgress(0, UploadStatus.uploading, info: 'Starting...');
      
      try {
        if (task.localPaths.length == 1) {
          final localPath = task.localPaths.first;
          // Simple local remote generation map
          final remotePath = task.remotePath.endsWith('/') 
            ? '${task.remotePath}${localPath.split(Platform.pathSeparator).last}'
            : task.remotePath;
            
          await minioService.uploadFile(localPath, remotePath, task);
        } else {
          // Multiple files
          for (int i = 0; i < task.localPaths.length; i++) {
             if (task.status == UploadStatus.canceled) break;
             final localPath = task.localPaths[i];
             final remotePath = '${task.remotePath}/${localPath.split(Platform.pathSeparator).last}';
             await minioService.uploadFile(localPath, remotePath, task);
          }
        }
      } catch (e) {
        appLogger.e('Task ${task.id} failed', error: e);
      }
    }

    _isProcessing = false;
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
