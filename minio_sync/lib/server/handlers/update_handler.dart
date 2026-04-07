import 'dart:convert';
import 'dart:io';
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

      await updater!.apply(info);

      // Launch new exe and exit
      final exePath = Platform.resolvedExecutable;
      appLogger.i('Restarting with new version ${info.version}');

      Process.start(exePath, [], mode: ProcessStartMode.detached);

      // Return success then exit after short delay
      Future.delayed(const Duration(milliseconds: 500), () => exit(0));

      return Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Updated to ${info.version} — restarting',
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
}
