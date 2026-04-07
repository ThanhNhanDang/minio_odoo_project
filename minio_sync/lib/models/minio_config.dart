class MinioConfig {
  final String endpoint;
  final String accessKey;
  final String secretKey;
  final String bucket;
  final bool secure;

  MinioConfig({
    this.endpoint = '',
    this.accessKey = '',
    this.secretKey = '',
    this.bucket = '',
    this.secure = false,
  });

  factory MinioConfig.fromJson(Map<String, dynamic> json) {
    return MinioConfig(
      endpoint: json['minio_endpoint'] ?? '',
      accessKey: json['minio_access_key'] ?? '',
      secretKey: json['minio_secret_key'] ?? '',
      bucket: json['minio_bucket'] ?? '',
      secure: json['minio_secure'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'minio_endpoint': endpoint,
      'minio_access_key': accessKey,
      'minio_secret_key': secretKey,
      'minio_bucket': bucket,
      'minio_secure': secure,
    };
  }

  MinioConfig copyWith({
    String? endpoint,
    String? accessKey,
    String? secretKey,
    String? bucket,
    bool? secure,
  }) {
    return MinioConfig(
      endpoint: endpoint ?? this.endpoint,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      bucket: bucket ?? this.bucket,
      secure: secure ?? this.secure,
    );
  }
}
