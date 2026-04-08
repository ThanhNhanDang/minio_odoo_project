import 'dart:async';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../../services/updater_service.dart';
import '../../utils/logger.dart';

class UpdateHandler {
  final UpdaterService? updater;
  final String currentVersion;

  UpdateHandler(this.updater, this.currentVersion);

  /// GET /api/system/update_check
  Future<Response> handleUpdateCheck(Request request) async {
    if (updater == null) {
      return Response.ok(
        jsonEncode({
          'update_available': false,
          'current_version': currentVersion,
          'message': 'Updater not configured',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final info = await updater!.checkForUpdate();
      return Response.ok(
        jsonEncode({
          ...info.toJson(),
          'current_version': currentVersion,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('Update check failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// POST /api/system/update
  Future<Response> handleUpdate(Request request) async {
    if (updater == null) {
      return Response(400,
        body: jsonEncode({'error': 'Updater not configured'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    try {
      final info = await updater!.checkForUpdate();
      if (!info.available) {
        return Response.ok(
          jsonEncode({
            'success': false,
            'message': 'Already up to date',
            'version': currentVersion,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Return success FIRST, then apply in background.
      // apply() downloads installer, runs it silently, and exits.
      // Installer handles kill + restart — we don't need to do it here.
      Future.microtask(() async {
        try {
          await updater!.apply(info);
        } catch (e) {
          appLogger.e('Background update apply failed: $e');
        }
      });

      return Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Downloading update ${info.version}...',
          'version': info.version,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('Update failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// GET /api/system/update/progress
  Future<Response> handleUpdateProgress(Request request) async {
    if (updater == null) {
      return Response(400,
        body: jsonEncode({'error': 'Updater not configured'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    return Response.ok(
      jsonEncode({
        'status': updater!.updateStatus,
        'progress': updater!.downloadProgress,
        'error': updater!.updateError,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
