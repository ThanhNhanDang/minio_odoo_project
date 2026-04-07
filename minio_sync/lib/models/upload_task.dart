import 'dart:async';

enum UploadStatus { pending, uploading, done, error, canceled }

class UploadProgress {
  final double percent;
  final UploadStatus status;
  final String info;

  UploadProgress({
    required this.percent,
    required this.status,
    required this.info,
  });
}

class UploadTask {
  final String id;
  final String taskName;
  final List<String> localPaths;
  final String remotePath;
  final int? odooFolderId;
  final String type; // 'file' or 'folder'
  final String odooSession; // Odoo session cookie for metadata sync

  UploadStatus status;
  String errorText;
  double percentCompleted;
  List<String> uploadedPaths; // MinIO object keys of uploaded files

  final StreamController<UploadProgress> progressController;

  UploadTask({
    required this.id,
    required this.taskName,
    required this.localPaths,
    required this.remotePath,
    this.odooFolderId,
    this.type = 'file',
    this.odooSession = '',
    this.status = UploadStatus.pending,
    this.errorText = '',
    this.percentCompleted = 0.0,
  }) : progressController = StreamController<UploadProgress>.broadcast(),
       uploadedPaths = [];

  void updateProgress(double percent, UploadStatus state, {String info = ''}) {
    percentCompleted = percent;
    status = state;
    if (state == UploadStatus.error) {
      errorText = info;
    }
    progressController.add(UploadProgress(percent: percent, status: state, info: info));
  }

  void close() {
    progressController.close();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': taskName,
      'remote_path': remotePath,
      'odoo_folder_id': odooFolderId,
      'type': type,
      'status': status.name,
      'error': errorText,
      'percent': percentCompleted,
      'uploaded_paths': uploadedPaths,
    };
  }
}
