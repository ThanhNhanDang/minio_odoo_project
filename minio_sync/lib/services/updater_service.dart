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

  /// Latest update found by background check. UI polls this.
  UpdateInfo? latestUpdate;

  /// Current update tracking state
  String updateStatus = 'idle'; // idle, downloading, installing, error
  double downloadProgress = 0.0;
  String updateError = '';

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
      // Tag format: "minio-sync-v1.0.2" → extract "1.0.2"
      final vIndex = tagName.lastIndexOf('v');
      final latestVersion = vIndex >= 0 ? tagName.substring(vIndex + 1) : tagName;

      if (latestVersion.isEmpty || latestVersion == currentVersion) {
        return const UpdateInfo();
      }

      // Find matching asset for this platform (e.g. MinIOSync-1.0.1-Setup.exe)
      final assets = (release['assets'] as List?) ?? [];
      final suffix = _platformAssetSuffix();
      String downloadUrl = '';
      String checksumUrl = '';
      String assetName = '';

      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.startsWith('MinIOSync-') && name.endsWith(suffix)) {
          downloadUrl = asset['browser_download_url'] as String? ?? '';
          assetName = name;
        } else if (name == 'checksums.txt') {
          checksumUrl = asset['browser_download_url'] as String? ?? '';
        }
      }

      if (downloadUrl.isEmpty) {
        appLogger.i('No installer asset matching *$suffix');
        return const UpdateInfo();
      }

      // Fetch checksum
      String checksum = '';
      if (checksumUrl.isNotEmpty) {
        checksum = await _fetchChecksum(checksumUrl, assetName);
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

  /// Download update and apply per platform.
  Future<void> apply(UpdateInfo info) async {
    final tmpDir = Directory.systemTemp.path;
    final downloadPath = '$tmpDir/minio-sync-update-${info.version}${_platformAssetSuffix()}';
    final tmpFile = File(downloadPath);

    updateStatus = 'downloading';
    downloadProgress = 0.0;
    updateError = '';

    try {
      appLogger.i('Downloading update from ${info.downloadUrl}');

      final request = http.Request('GET', Uri.parse(info.downloadUrl));
      final response = await http.Client().send(request).timeout(
        const Duration(minutes: 10),
      );

      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      int downloadedBytes = 0;
      final sink = tmpFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloadedBytes += chunk.length;
        if (contentLength > 0) {
          downloadProgress = downloadedBytes / contentLength;
        }
      }
      await sink.close();

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

      updateStatus = 'installing';

      if (Platform.isWindows) {
        await _applyWindows(downloadPath, info);
      } else if (Platform.isLinux) {
        await _applyLinux(downloadPath, info);
      } else if (Platform.isAndroid) {
        await _applyAndroid(downloadPath, info);
      }
    } catch (e) {
      updateStatus = 'error';
      updateError = e.toString();
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
      rethrow;
    }
  }

  /// Windows: run Inno Setup installer silently
  Future<void> _applyWindows(String installerPath, UpdateInfo info) async {
    appLogger.i('Launching Windows installer: $installerPath');
    await Process.start(
      installerPath,
      ['/SILENT', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
    appLogger.i('Installer launched, exiting current instance');
    exit(0);
  }

  /// Linux: extract tar.gz over current installation, then restart
  Future<void> _applyLinux(String tarPath, UpdateInfo info) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    appLogger.i('Extracting Linux update to $exeDir');

    final result = await Process.run(
      'tar', ['-xzf', tarPath, '-C', exeDir, '--strip-components=1'],
    );
    if (result.exitCode != 0) {
      throw Exception('tar extract failed: ${result.stderr}');
    }

    // Restart: launch new version and exit current
    await Process.start(
      Platform.resolvedExecutable, [],
      mode: ProcessStartMode.detached,
    );
    appLogger.i('Linux update applied, restarting');
    exit(0);
  }

  /// Android: save APK and open it for user to install
  Future<void> _applyAndroid(String apkPath, UpdateInfo info) async {
    // On Android, we can't silently install. Open the APK with the system installer.
    // The app needs REQUEST_INSTALL_PACKAGES permission in AndroidManifest.xml.
    appLogger.i('Android APK downloaded: $apkPath');
    // Trigger install via intent — requires platform channel or url_launcher
    // For now, store the path so the UI can prompt the user.
    _pendingApkPath = apkPath;
  }

  /// Path to downloaded APK waiting for user to install (Android only).
  String? _pendingApkPath;
  String? get pendingApkPath => _pendingApkPath;

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

  /// Platform-specific suffix to identify the correct asset in a GitHub release.
  /// Windows: MinIOSync-1.0.1-Setup.exe
  /// Linux:   MinIOSync-1.0.1-linux.tar.gz
  /// Android: MinIOSync-1.0.1.apk
  String _platformAssetSuffix() {
    if (Platform.isWindows) return '-Setup.exe';
    if (Platform.isLinux) return '-linux.tar.gz';
    if (Platform.isAndroid) return '.apk';
    if (Platform.isMacOS) return '-macOS.dmg';
    return '';
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
