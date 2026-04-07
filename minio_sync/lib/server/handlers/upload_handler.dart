import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../../services/upload_queue.dart';
import '../../models/upload_task.dart';
import 'package:uuid/uuid.dart';

class UploadHandler {
  final UploadQueue uploadQueue;
  final Uuid uuid = const Uuid();

  UploadHandler(this.uploadQueue);

  Future<Response> handleUpload(Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      final String taskId = data['task_id'] ?? uuid.v4();
      final List<String> paths = List<String>.from(data['paths'] ?? [data['path']]);
      final String remotePath = data['path'] ?? '';
      
      final task = UploadTask(
        id: taskId,
        taskName: data['task_name'] ?? 'upload ${paths.length} file(s)',
        localPaths: paths,
        remotePath: remotePath,
        odooFolderId: data['odoo_folder_id'],
        type: data['type'] ?? 'file',
      );

      uploadQueue.addTask(task);

      return Response.ok(
        jsonEncode({'success': true, 'task_id': taskId}),
        headers: {'Content-Type': 'application/json'}
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'}
      );
    }
  }
}
