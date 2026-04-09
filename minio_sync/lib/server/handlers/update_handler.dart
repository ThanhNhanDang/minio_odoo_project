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
      // Cache the result so handleUpdate() doesn't need to re-fetch
      if (info.available) {
        updater!.latestUpdate = info;
      }
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
      // Use cached update info from prior check to avoid redundant GitHub API
      // call (which can fail due to rate limiting on unauthenticated requests).
      final info = updater!.latestUpdate;
      if (info == null || !info.available) {
        return Response.ok(
          jsonEncode({
            'success': false,
            'message': 'No cached update info. Please check for updates first.',
            'version': currentVersion,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Download and apply synchronously so the caller knows the real result.
      // apply() downloads the installer, verifies checksum, launches it, then
      // calls exit(0).  If anything fails before the installer launches, we
      // report the error back to the UI.
      await updater!.apply(info);

      // If apply() returned without calling exit(0) (e.g. Android stores APK
      // for user to install manually), report success.
      return Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Update ${info.version} applied.',
          'version': info.version,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('Update failed', error: e);
      return Response.ok(
        jsonEncode({
          'success': false,
          'message': 'Update failed: $e',
          'version': currentVersion,
        }),
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
