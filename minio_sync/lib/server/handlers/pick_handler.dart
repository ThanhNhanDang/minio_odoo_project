import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';
import '../../services/upload_queue.dart';
import '../../models/upload_task.dart';
import '../../utils/logger.dart';

class PickHandler {
  final UploadQueue uploadQueue;
  final Uuid _uuid = const Uuid();

  PickHandler(this.uploadQueue);

  /// POST /api/pick_sync — opens native file/folder dialog on desktop
  Future<Response> handlePickSync(Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      final type = data['type'] ?? 'file';
      final currentPath = data['current_path'] ?? '';
      final odooFolderId = data['odoo_folder_id'];
      final taskName = data['task_name'] ?? 'Upload from dialog';
      // odoo_session available for future Odoo callback
      // final odooSession = data['odoo_session'];

      // Open native file dialog via PowerShell (Windows)
      List<String> paths;
      if (type == 'folder') {
        paths = await _pickFolder();
      } else {
        paths = await _pickFiles();
      }

      if (paths.isEmpty) {
        return Response.ok(
          jsonEncode({'success': false, 'canceled': true}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final taskId = _uuid.v4();
      final task = UploadTask(
        id: taskId,
        taskName: taskName,
        localPaths: paths,
        remotePath: currentPath,
        odooFolderId: odooFolderId is int ? odooFolderId : int.tryParse('$odooFolderId'),
        type: type,
      );
      uploadQueue.addTask(task);

      return Response.ok(
        jsonEncode({
          'success': true,
          'task_id': taskId,
          'paths': paths,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      appLogger.e('pick_sync failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// Opens a multi-select file dialog on Windows via PowerShell.
  Future<List<String>> _pickFiles() async {
    if (!Platform.isWindows) return [];

    const script = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Multiselect = $true
$f.Title = "Select files to upload"
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.StartPosition = 'CenterScreen'
$owner.Width = 0; $owner.Height = 0; $owner.FormBorderStyle = 'None'
$owner.Show(); $owner.Hide()
$result = $f.ShowDialog($owner)
$owner.Close()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  $f.FileNames | ForEach-Object { Write-Output $_ }
}
''';
    return _runPowerShell(script);
  }

  /// Opens a folder dialog on Windows via PowerShell.
  Future<List<String>> _pickFolder() async {
    if (!Platform.isWindows) return [];

    const script = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.FolderBrowserDialog
$f.Description = "Select folder to upload"
$f.ShowNewFolderButton = $true
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.StartPosition = 'CenterScreen'
$owner.Width = 0; $owner.Height = 0; $owner.FormBorderStyle = 'None'
$owner.Show(); $owner.Hide()
$result = $f.ShowDialog($owner)
$owner.Close()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output $f.SelectedPath
}
''';
    return _runPowerShell(script);
  }

  Future<List<String>> _runPowerShell(String script) async {
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      stdoutEncoding: const SystemEncoding(),
    );

    if (result.exitCode != 0) {
      appLogger.e('PowerShell dialog error: ${result.stderr}');
      return [];
    }

    final output = (result.stdout as String).trim();
    if (output.isEmpty) return [];

    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }
}
