import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../../services/upload_queue.dart';

class TaskHandler {
  final UploadQueue uploadQueue;

  TaskHandler(this.uploadQueue);

  Future<Response> handleListTasks(Request request) async {
    final tasks = uploadQueue.getAllTasks();
    final jsonTasks = tasks.map((t) => t.toJson()).toList();
    return Response.ok(
      jsonEncode(jsonTasks),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> handleGetTask(Request request, String id) async {
    final task = uploadQueue.getTask(id);
    if (task == null) {
      return Response.notFound(
        jsonEncode({'error': 'Task not found'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    return Response.ok(
      jsonEncode(task.toJson()),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> handleDeleteTask(Request request, String id) async {
    final removed = uploadQueue.removeTask(id);
    if (!removed) {
      return Response.notFound(
        jsonEncode({'error': 'Task not found'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    return Response.ok(
      jsonEncode({'success': true}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> handleCancelTask(Request request, String id) async {
    uploadQueue.cancelTask(id);
    return Response.ok(
      jsonEncode({'success': true}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
