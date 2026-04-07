import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import '../../services/upload_queue.dart';

class TaskHandler {
  final UploadQueue uploadQueue;

  TaskHandler(this.uploadQueue);

  Future<Response> handleListTasks(Request request) async {
    final tasks = uploadQueue.getAllTasks();
    final jsonTasks = tasks.map((t) => t.toJson()).toList();
    return Response.ok(
      jsonEncode(jsonTasks),
      headers: {'Content-Type': 'application/json'}
    );
  }

  Future<Response> handleGetTask(Request request, String id) async {
    final task = uploadQueue.getTask(id);
    if (task == null) {
      return Response.notFound(jsonEncode({'error': 'Task not found'}));
    }
    return Response.ok(
      jsonEncode(task.toJson()),
      headers: {'Content-Type': 'application/json'}
    );
  }
}
