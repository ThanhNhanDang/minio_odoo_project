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
      final odooSession = data['odoo_session'] ?? '';

      // Open native file dialog via PowerShell (Windows)
      List<String> paths;
      try {
        if (type == 'folder') {
          paths = await _pickFolder();
        } else {
          paths = await _pickFiles();
        }
      } catch (dialogError) {
        appLogger.e('Dialog picker failed', error: dialogError);
        return Response.ok(
          jsonEncode({
            'success': false,
            'error': true,
            'message': 'Dialog failed: $dialogError',
          }),
          headers: {'Content-Type': 'application/json'},
        );
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
        odooSession: odooSession,
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

  // --- PowerShell preambles (matching Go service quality) ---

  static const _utf8Preamble = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
''';

  static const _dpiPreamble = r'''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
public class WinHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
}
'
[WinHelper]::SetProcessDPIAware() | Out-Null
[WinHelper]::AllowSetForegroundWindow(-1) | Out-Null
''';

  /// Opens a multi-select file dialog on Windows via PowerShell.
  /// Uses DPI awareness + visual styles for crisp, modern look.
  Future<List<String>> _pickFiles() async {
    if (!Platform.isWindows) return [];

    const script = '$_utf8Preamble$_dpiPreamble'
        r'''
$form = New-Object System.Windows.Forms.Form
$form.TopMost = $true
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Show()
$form.Hide()

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Select files to upload"
$dialog.Multiselect = $true
$dialog.Filter = "All files (*.*)|*.*"
$result = $dialog.ShowDialog($form)
$form.Dispose()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  $dialog.FileNames | ForEach-Object { Write-Output $_ }
}
''';
    return _runPowerShell(script);
  }

  /// Opens a modern Explorer-style folder picker on Windows via PowerShell.
  /// Uses OpenFileDialog with folder-select trick — same modern UI as file picker.
  Future<List<String>> _pickFolder() async {
    if (!Platform.isWindows) return [];

    const script = '$_utf8Preamble$_dpiPreamble'
        r'''
$form = New-Object System.Windows.Forms.Form
$form.TopMost = $true
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Show()
$form.Hide()

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Select a folder to upload"
$dialog.CheckFileExists = $false
$dialog.CheckPathExists = $true
$dialog.ValidateNames = $false
$dialog.FileName = "Folder Selection"
$dialog.Filter = "Folders|no.files"
$result = $dialog.ShowDialog($form)
$form.Dispose()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output (Split-Path $dialog.FileName)
}
''';
    return _runPowerShell(script);
  }

  Future<List<String>> _runPowerShell(String script) async {
    // Write script to temp file and run with -File flag.
    // This ensures -STA flag works correctly for COM dialogs.
    final tempDir = Directory.systemTemp;
    final scriptFile = File('${tempDir.path}/minio_pick_${DateTime.now().millisecondsSinceEpoch}.ps1');
    await scriptFile.writeAsString(script);

    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', scriptFile.path],
        stdoutEncoding: utf8,
      );

      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        appLogger.e('PowerShell dialog error (exit=${result.exitCode}): $stderr');
        throw Exception('PowerShell failed (exit=${result.exitCode}): $stderr');
      }

      final output = (result.stdout as String).trim();
      if (output.isEmpty) return [];

      return output
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
    } finally {
      try { await scriptFile.delete(); } catch (_) {}
    }
  }
}
