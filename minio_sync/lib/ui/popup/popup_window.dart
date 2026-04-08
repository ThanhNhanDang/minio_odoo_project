import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:launch_at_startup/launch_at_startup.dart';
import '../../main.dart' show spawnServer, killServer, serverIsolate;

class PopupWindow extends StatefulWidget {
  const PopupWindow({super.key});

  @override
  State<PopupWindow> createState() => _PopupWindowState();
}

class _PopupWindowState extends State<PopupWindow> with SingleTickerProviderStateMixin {
  // Server & MinIO status
  bool _serverRunning = true;
  bool _isConnected = false;
  bool _isLoading = true;
  String _endpoint = '';
  String _bucket = '';
  String _odooUrl = '';
  String _version = '1.0.0';
  String _hostname = '';
  String _listenAddr = ':9999';
  bool _secure = false;

  // Auto startup
  bool _autoStartup = false;

  // Update
  bool _checkingUpdate = false;
  String _updateVersion = '';
  bool _updateAvailable = false;

  late AnimationController _pulseController;
  Timer? _pollTimer;

  static const _apiBase = 'http://127.0.0.1:9999';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _serverRunning = serverIsolate != null;
    _loadAutoStartup();
    _fetchStatus();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchStatus());
    // Auto-check for updates 5s after startup
    Future.delayed(const Duration(seconds: 5), _silentUpdateCheck);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAutoStartup() async {
    final enabled = await launchAtStartup.isEnabled();
    if (mounted) setState(() => _autoStartup = enabled);
  }

  Future<void> _toggleAutoStartup(bool value) async {
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
    if (mounted) setState(() => _autoStartup = value);
  }

  Future<void> _toggleServer() async {
    if (_serverRunning) {
      killServer();
      setState(() {
        _serverRunning = false;
        _isConnected = false;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = true);
      await spawnServer();
      setState(() => _serverRunning = true);
      // Give server time to bind
      await Future.delayed(const Duration(seconds: 2));
      await _fetchStatus();
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final response = await http.get(Uri.parse('$_apiBase/api/system/update_check')).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        setState(() {
          _updateAvailable = data['update_available'] ?? false;
          _updateVersion = data['latest_version'] ?? '';
          _checkingUpdate = false;
        });
        if (_updateAvailable) {
          _showSnack('Update v$_updateVersion available!', isError: false);
        } else {
          _showSnack('Already up to date (v$_version)', isError: false);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _checkingUpdate = false);
        _showSnack('Server not reachable');
      }
    }
  }

  /// Silent background check — if update found, show confirmation dialog.
  Future<void> _silentUpdateCheck() async {
    if (!_serverRunning) return;
    try {
      final response = await http.get(Uri.parse('$_apiBase/api/system/update_check')).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        final available = data['update_available'] ?? false;
        final version = data['latest_version'] ?? '';
        if (available && version.isNotEmpty) {
          setState(() {
            _updateAvailable = true;
            _updateVersion = version;
          });
          _showUpdateDialog(version);
        }
      }
    } catch (_) {}
  }

  /// Show dialog asking user to update.
  void _showUpdateDialog(String newVersion) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF3B82F6), size: 24),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Update Available',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version v$newVersion is available.',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text('Current: v$_version',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text('The app will download and install the update, then restart automatically.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              _applyUpdate();
            },
            icon: const Icon(Icons.download_rounded, size: 16),
            label: const Text('Update & Restart'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B82F6),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyUpdate() async {
    _showSnack('Downloading update v$_updateVersion...', isError: false);
    try {
      final response = await http.post(Uri.parse('$_apiBase/api/system/update')).timeout(
        const Duration(minutes: 5),
      );
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          _showSnack('Updated to v${data['version']}! Restarting...', isError: false);
        } else {
          _showSnack(data['message'] ?? 'Update failed');
        }
      }
    } catch (e) {
      if (mounted) _showSnack('Update failed: $e');
    }
  }

  Future<void> _fetchStatus() async {
    if (!_serverRunning) return;
    try {
      final response = await http.get(Uri.parse('$_apiBase/api/config')).timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        setState(() {
          _isConnected = data['minio_connected'] ?? false;
          _endpoint = data['minio_endpoint'] ?? '';
          _bucket = data['minio_bucket'] ?? '';
          _odooUrl = data['odoo_url'] ?? '';
          _version = data['version'] ?? '1.0.0';
          _hostname = data['hostname'] ?? '';
          _listenAddr = data['listen_addr'] ?? ':9999';
          _secure = data['minio_secure'] ?? false;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnack(String msg, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12, color: Colors.white)),
        backgroundColor: isError ? const Color(0xFFDC2626) : const Color(0xFF059669),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.06))),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF00D2FF), Color(0xFF3A7BD5)]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.cloud_sync, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          const Text('MinIO Sync',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('v$_version',
              style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          // Server toggle
          _buildServerToggle(),
          const SizedBox(height: 16),

          // Status indicator
          _buildStatusIndicator(),
          const SizedBox(height: 16),

          // Info cards
          _buildInfoCard(Icons.storage_rounded, 'Endpoint',
            _endpoint.isEmpty ? 'Waiting for Odoo...' : _endpoint,
            _endpoint.isEmpty ? Colors.amber.withOpacity(0.7) : Colors.white70),
          const SizedBox(height: 6),
          _buildInfoCard(Icons.folder_rounded, 'Bucket',
            _bucket.isEmpty ? 'Not set' : _bucket,
            _bucket.isEmpty ? Colors.white38 : Colors.white70),
          const SizedBox(height: 6),
          _buildInfoCard(Icons.language_rounded, 'Odoo',
            _odooUrl.isEmpty ? 'Waiting for Odoo...' : _odooUrl,
            _odooUrl.isEmpty ? Colors.amber.withOpacity(0.7) : Colors.white70),
          const SizedBox(height: 6),
          _buildInfoCard(Icons.lock_rounded, 'SSL',
            _secure ? 'Enabled' : 'Disabled',
            _secure ? const Color(0xFF4ADE80) : Colors.white38),

          const SizedBox(height: 16),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 12),

          // Settings
          _buildSettingRow(
            icon: Icons.power_settings_new_rounded,
            label: 'Launch at startup',
            trailing: SizedBox(
              height: 28,
              child: Switch(
                value: _autoStartup,
                onChanged: _toggleAutoStartup,
                activeColor: const Color(0xFF4ADE80),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          const SizedBox(height: 4),
          _buildSettingRow(
            icon: Icons.system_update_rounded,
            label: _updateAvailable ? 'Update to v$_updateVersion' : 'Check for updates',
            trailing: _checkingUpdate
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                  )
                : _updateAvailable
                    ? _buildSmallButton('Install', const Color(0xFF3B82F6), _applyUpdate)
                    : _buildSmallButton('Check', Colors.white10, _serverRunning ? _checkUpdate : null),
          ),
        ],
      ),
    );
  }

  Widget _buildServerToggle() {
    final bool on = _serverRunning;
    return GestureDetector(
      onTap: _toggleServer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF4ADE80).withOpacity(0.08) : Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on ? const Color(0xFF4ADE80).withOpacity(0.3) : Colors.white.withOpacity(0.06),
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 36,
              height: 20,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: on ? const Color(0xFF4ADE80) : const Color(0xFF374151),
              ),
              padding: const EdgeInsets.all(2),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 16, height: 16,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              on ? 'Sync Server Running' : 'Sync Server Stopped',
              style: TextStyle(
                color: on ? const Color(0xFF4ADE80) : Colors.white38,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              on ? 'Port ${_listenAddr.replaceFirst(':', '')}' : 'OFF',
              style: TextStyle(
                color: on ? Colors.white24 : Colors.white12,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    const Color activeColor = Color(0xFF4ADE80);
    const Color waitingColor = Color(0xFFF59E0B);
    const Color inactiveColor = Color(0xFF374151);
    const Color offColor = Color(0xFF6B7280);

    Color currentColor;
    String statusText;
    String subtitle;
    IconData icon;

    if (!_serverRunning) {
      currentColor = offColor;
      statusText = 'Server Off';
      subtitle = 'Tap toggle above to start';
      icon = Icons.power_off_rounded;
    } else if (_isLoading) {
      currentColor = waitingColor;
      statusText = 'Starting...';
      subtitle = 'Initializing service...';
      icon = Icons.hourglass_top_rounded;
    } else if (_isConnected) {
      currentColor = activeColor;
      statusText = 'Connected';
      subtitle = 'Sync service is active';
      icon = Icons.cloud_done_rounded;
    } else if (_endpoint.isEmpty) {
      currentColor = waitingColor;
      statusText = 'Waiting for config';
      subtitle = 'Open Odoo to auto-configure';
      icon = Icons.hourglass_top_rounded;
    } else {
      currentColor = inactiveColor;
      statusText = 'Disconnected';
      subtitle = 'MinIO connection failed';
      icon = Icons.cloud_off_rounded;
    }

    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 72, height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: currentColor.withOpacity(0.1),
            border: Border.all(color: currentColor.withOpacity(0.4), width: 2.5),
            boxShadow: _isConnected && _serverRunning
                ? [BoxShadow(color: activeColor.withOpacity(0.2), blurRadius: 20, spreadRadius: 2)]
                : [],
          ),
          child: _isLoading && _serverRunning
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white54),
                )
              : Icon(icon, color: currentColor, size: 30),
        ),
        const SizedBox(height: 10),
        Text(statusText, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: currentColor)),
        const SizedBox(height: 2),
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final bool shouldPulse = _serverRunning && !_isConnected && _endpoint.isEmpty && !_isLoading;
            return Text(subtitle,
              style: TextStyle(
                color: Colors.white.withOpacity(shouldPulse ? 0.25 + _pulseController.value * 0.25 : 0.35),
                fontSize: 12,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildInfoCard(IconData icon, String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white24, size: 16),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          const Spacer(),
          Flexible(
            child: Text(value,
              style: TextStyle(color: valueColor, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingRow({required IconData icon, required String label, required Widget trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: Colors.white24, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _buildSmallButton(String text, Color bg, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
          style: TextStyle(
            color: onTap != null ? Colors.white70 : Colors.white24,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 7, height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !_serverRunning
                  ? const Color(0xFF6B7280)
                  : _isConnected
                      ? const Color(0xFF4ADE80)
                      : _endpoint.isEmpty
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF6B7280),
              boxShadow: _isConnected && _serverRunning
                  ? [BoxShadow(color: const Color(0xFF4ADE80).withOpacity(0.5), blurRadius: 5)]
                  : [],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _hostname.isNotEmpty ? _hostname : 'MinIO Sync',
            style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 11),
          ),
          const Spacer(),
          Text(
            _serverRunning ? 'Port ${_listenAddr.replaceFirst(':', '')}' : 'Stopped',
            style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 11),
          ),
        ],
      ),
    );
  }
}
