import 'dart:async';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../../services/upload_queue.dart';
import '../../models/upload_task.dart';

class ProgressHandler {
  final UploadQueue uploadQueue;

  ProgressHandler(this.uploadQueue);

  /// SSE endpoint: GET /api/upload/progress/<id>
  /// Streams real-time upload progress as Server-Sent Events.
  Future<Response> handleProgress(Request request, String id) async {
    final task = uploadQueue.getTask(id);

    // If task not found yet, still open the SSE stream — it may be created shortly.
    final controller = StreamController<List<int>>();

    // Send initial event
    if (task != null) {
      _sendEvent(controller, task.percentCompleted, task.status);
    } else {
      _sendEvent(controller, 0, UploadStatus.pending);
    }

    StreamSubscription<UploadProgress>? subscription;

    void listen(UploadTask t) {
      subscription = t.progressController.stream.listen(
        (progress) {
          _sendEvent(controller, progress.percent, progress.status);
          if (progress.status == UploadStatus.done ||
              progress.status == UploadStatus.error ||
              progress.status == UploadStatus.canceled) {
            subscription?.cancel();
            controller.close();
          }
        },
        onDone: () => controller.close(),
        onError: (_) => controller.close(),
      );
    }

    if (task != null) {
      // If already done, send final event and close
      if (task.status == UploadStatus.done ||
          task.status == UploadStatus.error ||
          task.status == UploadStatus.canceled) {
        _sendEvent(controller, task.percentCompleted, task.status);
        controller.close();
      } else {
        listen(task);
      }
    } else {
      // Poll for task creation (it may be added shortly after SSE connects)
      Timer.periodic(const Duration(milliseconds: 200), (timer) {
        final t = uploadQueue.getTask(id);
        if (t != null) {
          timer.cancel();
          listen(t);
        }
        // Give up after 30 seconds
        if (timer.tick > 150) {
          timer.cancel();
          _sendEvent(controller, 0, UploadStatus.error);
          controller.close();
        }
      });
    }

    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'Access-Control-Allow-Origin': '*',
      },
    );
  }

  void _sendEvent(StreamController<List<int>> controller, double percent, UploadStatus status) {
    if (controller.isClosed) return;
    final statusStr = (status == UploadStatus.done || status == UploadStatus.error || status == UploadStatus.canceled)
        ? 'complete'
        : 'running';
    final data = jsonEncode({
      'status': statusStr,
      'percent': percent.round(),
    });
    controller.add('data: $data\n\n'.codeUnits);
  }
}
