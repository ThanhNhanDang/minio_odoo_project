import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:http/http.dart' as http;
import '../../models/app_config.dart';
import '../../utils/logger.dart';

class AuthHandler {
  String? _sessionId;
  String? _authenticatedUser;
  final AppConfig Function() getAppConfig;

  AuthHandler(this.getAppConfig);

  bool get isAuthenticated => _sessionId != null;
  String? get sessionId => _sessionId;

  Future<Response> handleStatus(Request request) async {
    final config = getAppConfig();
    return Response.ok(
      jsonEncode({
        'authenticated': isAuthenticated,
        'url': config.odooUrl,
        'db': config.odooDb,
        'client_id': config.clientId,
        if (_authenticatedUser != null) 'user': _authenticatedUser,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> handleLogin(Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      final url = data['url'] ?? getAppConfig().odooUrl;
      final db = data['db'] ?? getAppConfig().odooDb;
      final username = data['username'] ?? '';
      final password = data['password'] ?? '';

      if (url.isEmpty || db.isEmpty) {
        return Response(401,
          body: jsonEncode({'success': false, 'error': 'Odoo URL and DB not configured'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Call Odoo JSON-RPC to authenticate
      final rpcUrl = '$url/web/session/authenticate';
      final rpcBody = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'call',
        'params': {
          'db': db,
          'login': username,
          'password': password,
        },
      });

      final response = await http.post(
        Uri.parse(rpcUrl),
        headers: {'Content-Type': 'application/json'},
        body: rpcBody,
      );

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        final uid = result['result']?['uid'];

        if (uid != null && uid is int && uid > 0) {
          // Extract session_id from cookies
          final cookies = response.headers['set-cookie'] ?? '';
          final sessionMatch = RegExp(r'session_id=([^;]+)').firstMatch(cookies);
          _sessionId = sessionMatch?.group(1);
          _authenticatedUser = username;

          appLogger.i('Authenticated as $username (uid=$uid)');

          return Response.ok(
            jsonEncode({'success': true, 'uid': uid}),
            headers: {'Content-Type': 'application/json'},
          );
        } else {
          final errorMsg = result['result']?['message'] ?? result['error']?['message'] ?? 'Invalid credentials';
          return Response(401,
            body: jsonEncode({'success': false, 'error': errorMsg}),
            headers: {'Content-Type': 'application/json'},
          );
        }
      } else {
        return Response(401,
          body: jsonEncode({'success': false, 'error': 'Odoo server returned ${response.statusCode}'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    } catch (e) {
      appLogger.e('Login failed', error: e);
      return Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Future<Response> handleLogout(Request request) async {
    _sessionId = null;
    _authenticatedUser = null;
    appLogger.i('Logged out');
    return Response.ok(
      jsonEncode({'success': true}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
