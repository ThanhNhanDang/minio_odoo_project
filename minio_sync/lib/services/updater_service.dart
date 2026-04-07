import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String checksum;
  final bool available;

  const UpdateInfo({
    this.version = '',
    this.downloadUrl = '',
    this.checksum = '',
    this.available = false,
  });

  Map<String, dynamic> toJson() => {
        'update_available': available,
        'latest_version': version,
        'download_url': downloadUrl,
      };
}

class UpdaterService {
  final String currentVersion;
  final String repoSlug; // "owner/repo"
  final String? githubToken;

  Timer? _checkTimer;

  UpdaterService({
    required this.currentVersion,
    required this.repoSlug,
    this.githubToken,
  });

  /// Check GitHub for latest release.
  Future<UpdateInfo> checkForUpdate() async {
    if (repoSlug.isEmpty) {
      return const UpdateInfo();
    }

    final url = 'https://api.github.com/repos/$repoSlug/releases/latest';
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'minio-sync/$currentVersion',
    };
    if (githubToken != null && githubToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $githubToken';
    }

    try {
      final response = await http.get(Uri.parse(url), headers: headers).timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode != 200) {
        appLogger.e('Update check failed: HTTP ${response.statusCode}');
        return const UpdateInfo();
      }

      final release = jsonDecode(response.body);
      final tagName = (release['tag_name'] as String?) ?? '';
      final latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;

      if (latestVersion.isEmpty || latestVersion == currentVersion) {
        return const UpdateInfo();
      }

      // Find matching asset for this platform
      final assets = (release['assets'] as List?) ?? [];
      final binaryName = _platformBinaryName();
      String downloadUrl = '';
      String checksumUrl = '';

      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name == binaryName) {
          downloadUrl = asset['browser_download_url'] as String? ?? '';
        } else if (name == 'checksums.txt') {
          checksumUrl = asset['browser_download_url'] as String? ?? '';
        }
      }

      if (downloadUrl.isEmpty) {
        appLogger.i('No binary for platform: $binaryName');
        return const UpdateInfo();
      }

      // Fetch checksum
      String checksum = '';
      if (checksumUrl.isNotEmpty) {
        checksum = await _fetchChecksum(checksumUrl, binaryName);
      }

      appLogger.i('Update available: $currentVersion -> $latestVersion');
      return UpdateInfo(
        version: latestVersion,
        downloadUrl: downloadUrl,
        checksum: checksum,
        available: true,
      );
    } catch (e) {
      appLogger.e('Update check error', error: e);
      return const UpdateInfo();
    }
  }

  /// Download update and replace current executable.
  Future<void> apply(UpdateInfo info) async {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;

    // Download to temp file in same directory (for atomic rename)
    final tmpFile = File('$exeDir/minio-sync-update-${info.version}.tmp');

    try {
      appLogger.i('Downloading update from ${info.downloadUrl}');

      final response = await http.get(Uri.parse(info.downloadUrl)).timeout(
        const Duration(minutes: 5),
      );

      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      await tmpFile.writeAsBytes(response.bodyBytes);

      // Verify checksum
      if (info.checksum.isNotEmpty) {
        final bytes = await tmpFile.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        if (hash.toLowerCase() != info.checksum.toLowerCase()) {
          await tmpFile.delete();
          throw Exception(
            'Checksum mismatch: expected=${info.checksum}, got=$hash',
          );
        }
        appLogger.i('Checksum verified');
      }

      // Atomic replacement: current -> .old, tmp -> current
      final oldFile = File('$exePath.old');
      if (await oldFile.exists()) {
        await oldFile.delete();
      }
      await File(exePath).rename('$exePath.old');
      await tmpFile.rename(exePath);

      appLogger.i('Update applied: ${info.version}');
    } catch (e) {
      // Restore backup
      final oldFile = File('$exePath.old');
      if (await oldFile.exists() && !await File(exePath).exists()) {
        await oldFile.rename(exePath);
      }
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
      rethrow;
    }
  }

  /// Start background check: 30s initial, then every 6 hours.
  void startBackgroundCheck(void Function(UpdateInfo) onUpdateAvailable) {
    // Initial check after 30 seconds
    Timer(const Duration(seconds: 30), () async {
      final info = await checkForUpdate();
      if (info.available) onUpdateAvailable(info);
    });

    // Recurring every 6 hours
    _checkTimer = Timer.periodic(const Duration(hours: 6), (_) async {
      final info = await checkForUpdate();
      if (info.available) onUpdateAvailable(info);
    });
  }

  void dispose() {
    _checkTimer?.cancel();
  }

  String _platformBinaryName() {
    if (Platform.isWindows) return 'minio-sync-windows-amd64.exe';
    if (Platform.isMacOS) return 'minio-sync-darwin-amd64';
    if (Platform.isLinux) return 'minio-sync-linux-amd64';
    return 'minio-sync-unknown';
  }

  Future<String> _fetchChecksum(String url, String binaryName) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) return '';

      for (final line in response.body.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.contains(binaryName)) {
          // Format: "<hash>  <filename>"
          return trimmed.split(RegExp(r'\s+')).first;
        }
      }
    } catch (_) {}
    return '';
  }
}
