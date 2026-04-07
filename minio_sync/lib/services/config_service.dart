import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_config.dart';
import '../models/minio_config.dart';
import '../utils/logger.dart';
import '../utils/platform_utils.dart';

abstract class ConfigRepository {
  Future<AppConfig> loadAppConfig();
  Future<void> saveAppConfig(AppConfig config);
  
  Future<MinioConfig> loadMinioConfig();
  Future<void> saveMinioConfig(MinioConfig config);
}

class JsonConfigRepository implements ConfigRepository {
  late final File _configFile;
  
  Future<void> init() async {
    final execDir = Platform.resolvedExecutable;
    final String configPath = '${File(execDir).parent.path}/config.json';
    _configFile = File(configPath);
    if (!await _configFile.exists()) {
      await _configFile.writeAsString(jsonEncode({}));
    }
  }

  @override
  Future<AppConfig> loadAppConfig() async {
    try {
      final text = await _configFile.readAsString();
      return AppConfig.fromJson(jsonDecode(text));
    } catch (e) {
      appLogger.e('Failed to load AppConfig from JSON', error: e);
      return AppConfig();
    }
  }

  @override
  Future<void> saveAppConfig(AppConfig config) async {
    try {
      final json = jsonDecode(await _configFile.readAsString());
      json.addAll(config.toJson());
      await _configFile.writeAsString(jsonEncode(json));
    } catch (e) {
      appLogger.e('Failed to save AppConfig to JSON', error: e);
    }
  }

  @override
  Future<MinioConfig> loadMinioConfig() async {
    try {
      final text = await _configFile.readAsString();
      return MinioConfig.fromJson(jsonDecode(text));
    } catch (e) {
      appLogger.e('Failed to load MinioConfig from JSON', error: e);
      return MinioConfig();
    }
  }

  @override
  Future<void> saveMinioConfig(MinioConfig config) async {
     try {
      final json = jsonDecode(await _configFile.readAsString());
      json.addAll(config.toJson());
      await _configFile.writeAsString(jsonEncode(json));
    } catch (e) {
      appLogger.e('Failed to save MinioConfig to JSON', error: e);
    }
  }
}

class PrefsConfigRepository implements ConfigRepository {
  static const String _appKey = 'app_config';
  static const String _minioKey = 'minio_config';

  @override
  Future<AppConfig> loadAppConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_appKey);
    if (data != null) return AppConfig.fromJson(jsonDecode(data));
    return AppConfig();
  }

  @override
  Future<void> saveAppConfig(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appKey, jsonEncode(config.toJson()));
  }

  @override
  Future<MinioConfig> loadMinioConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_minioKey);
    if (data != null) return MinioConfig.fromJson(jsonDecode(data));
    return MinioConfig();
  }

  @override
  Future<void> saveMinioConfig(MinioConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_minioKey, jsonEncode(config.toJson()));
  }
}

class ConfigService {
  static late final ConfigRepository repository;

  static Future<void> initialize() async {
    if (PlatformUtils.isDesktop) {
      final repo = JsonConfigRepository();
      await repo.init();
      repository = repo;
    } else {
      repository = PrefsConfigRepository();
    }
  }
}
