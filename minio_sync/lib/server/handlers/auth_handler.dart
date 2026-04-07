import 'dart:convert';
import 'package:shelf/shelf.dart';

class AuthHandler {
  Future<Response> handleLogin(Request request) async {
    // Stub implementation mirroring Go behavior
    // Real logic would make HTTP call to Odoo RPC 
    return Response.ok(
      jsonEncode({'success': true, 'provisioned': false}),
      headers: {'Content-Type': 'application/json'}
    );
  }
}
