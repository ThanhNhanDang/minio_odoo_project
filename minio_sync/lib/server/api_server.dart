import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'handlers/upload_handler.dart';
import 'handlers/task_handler.dart';
import 'handlers/auth_handler.dart';
import 'handlers/config_handler.dart';
import 'handlers/system_handler.dart';
import 'handlers/progress_handler.dart';
import 'handlers/pick_handler.dart';
import 'handlers/file_handler.dart';
import 'handlers/update_handler.dart';
import '../services/upload_queue.dart';
import '../services/minio_service.dart';
import '../services/updater_service.dart';
import '../models/app_config.dart';
import '../models/minio_config.dart';
import '../utils/logger.dart';

class ServerConfig {
  final int port;
  final SendPort sendPort;

  ServerConfig(this.port, this.sendPort);
}

Future<Map<String, dynamic>> _loadConfigFromDisk() async {
  try {
    final exePath = Platform.resolvedExecutable;
    final configPath = '${File(exePath).parent.path}/config.json';
    final file = File(configPath);
    if (await file.exists()) {
      return jsonDecode(await file.readAsString());
    }
  } catch (e) {
    appLogger.e('Failed to load config.json in isolate', error: e);
  }
  return {};
}

void startApiServer(ServerConfig config) async {
  final minioService = MinioService();
  final uploadQueue = UploadQueue(minioService);

  // Load persisted config from disk
  final diskConfig = await _loadConfigFromDisk();
  final initialAppConfig = AppConfig.fromJson(diskConfig);
  final initialMinioConfig = MinioConfig.fromJson(diskConfig);

  appLogger.i('Server config loaded: endpoint=${initialMinioConfig.endpoint}, updateUrl=${initialAppConfig.updateUrl}');

  // Auto-connect MinIO if config was persisted from a previous session
  if (initialMinioConfig.endpoint.isNotEmpty) {
    minioService.connect(initialMinioConfig);
    appLogger.i('Auto-connected MinIO from persisted config');
  }

  final configHandler = ConfigHandler(minioService, initialAppConfig, initialMinioConfig);

  // Initialize updater from config
  final appConfig = configHandler.appConfig;
  UpdaterService? updater;
  if (appConfig.updateUrl.isNotEmpty) {
    updater = UpdaterService(
      currentVersion: appConfig.version,
      repoSlug: appConfig.updateUrl,
      githubToken: appConfig.githubToken.isNotEmpty ? appConfig.githubToken : null,
    );
    appLogger.i('Updater initialized: repo=${appConfig.updateUrl}');

    // Start background update check (30s initial, 6h recurring)
    updater.startBackgroundCheck((info) {
      appLogger.i('Update available: ${appConfig.version} -> ${info.version}');
    });
  }

  final authHandler = AuthHandler(() => configHandler.appConfig);
  final systemHandler = SystemHandler(minioService, () => configHandler.appConfig);
  final uploadHandler = UploadHandler(uploadQueue);
  final taskHandler = TaskHandler(uploadQueue);
  final progressHandler = ProgressHandler(uploadQueue);
  final pickHandler = PickHandler(uploadQueue);
  final fileHandler = FileHandler(minioService);
  final updateHandler = UpdateHandler(updater, appConfig.version);

  final router = Router();

  // Upload & progress
  router.post('/api/upload', uploadHandler.handleUpload);
  router.get('/api/upload/progress/<id>', progressHandler.handleProgress);

  // Tasks
  router.get('/api/tasks', taskHandler.handleListTasks);
  router.get('/api/task/<id>', taskHandler.handleGetTask);
  router.delete('/api/task/<id>', taskHandler.handleDeleteTask);
  router.post('/api/task/<id>/cancel', taskHandler.handleCancelTask);

  // Auth
  router.post('/api/auth/login', authHandler.handleLogin);
  router.post('/api/auth/logout', authHandler.handleLogout);
  router.get('/api/auth/status', authHandler.handleStatus);

  // Config & System
  router.post('/api/config/auto_set', configHandler.handleAutoSet);
  router.get('/api/config', configHandler.handleGetConfig);
  router.get('/api/system/status', systemHandler.handleStatus);
  router.get('/api/system/update_check', updateHandler.handleUpdateCheck);
  router.post('/api/system/update', updateHandler.handleUpdate);

  // File operations
  router.get('/api/list', fileHandler.handleList);
  router.post('/api/delete', fileHandler.handleDelete);
  router.post('/api/download_async', fileHandler.handleDownloadAsync);

  // Pick sync (native file dialog)
  router.post('/api/pick_sync', pickHandler.handlePickSync);

  final handler = const Pipeline()
      .addMiddleware(corsHeaders(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization, X-Requested-With',
      }))
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final server = await io.serve(handler, '127.0.0.1', config.port);
  print('Server listening on port ${server.port} in separate Isolate');
}
