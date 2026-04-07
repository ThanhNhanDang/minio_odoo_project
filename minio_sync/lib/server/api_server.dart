import 'dart:isolate';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'handlers/upload_handler.dart';
import 'handlers/task_handler.dart';
import 'handlers/auth_handler.dart';
import '../../services/upload_queue.dart';
import '../../services/minio_service.dart';

class ServerConfig {
  final int port;
  final SendPort sendPort;

  ServerConfig(this.port, this.sendPort);
}

void startApiServer(ServerConfig config) async {
  final uploadQueue = UploadQueue(MinioService());
  
  final router = Router();
  
  final uploadHandler = UploadHandler(uploadQueue);
  final taskHandler = TaskHandler(uploadQueue);
  final authHandler = AuthHandler();

  router.post('/api/upload', uploadHandler.handleUpload);
  router.get('/api/tasks', taskHandler.handleListTasks);
  router.get('/api/task/<id>', taskHandler.handleGetTask);
  router.post('/api/auth/login', authHandler.handleLogin);

  final handler = const Pipeline()
      .addMiddleware(corsHeaders(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
      }))
      .addMiddleware(logRequests())
      .addHandler(router.call);

  var server = await io.serve(handler, '127.0.0.1', config.port);
  print('Server listening on port ${server.port} in separate Isolate');
}
