import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class PopupWindow extends StatefulWidget {
  const PopupWindow({super.key});

  @override
  State<PopupWindow> createState() => _PopupWindowState();
}

class _PopupWindowState extends State<PopupWindow> with SingleTickerProviderStateMixin {
  bool _isConnected = false;
  bool _isLoading = true;
  String _endpoint = '';
  String _bucket = '';
  String _odooUrl = '';
  String _version = '1.0.0';
  String _hostname = '';
  String _listenAddr = ':9999';
  bool _secure = false;

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
    _fetchStatus();
    // Poll server status every 3 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchStatus());
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchStatus() async {
    try {
      final response = await http.get(Uri.parse('$_apiBase/api/config')).timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (!mounted) return;
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
      // Server not ready yet
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withOpacity(0.08),
            width: 1,
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF00D2FF), Color(0xFF3A7BD5)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.cloud_sync, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          const Text(
            'MinIO Sync',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'v$_version',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          _buildStatusIndicator(),
          const SizedBox(height: 24),
          _buildInfoCard(
            icon: Icons.storage_rounded,
            label: 'Endpoint',
            value: _endpoint.isEmpty ? 'Waiting for Odoo...' : _endpoint,
            valueColor: _endpoint.isEmpty ? Colors.amber.withOpacity(0.7) : Colors.white70,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            icon: Icons.folder_rounded,
            label: 'Bucket',
            value: _bucket.isEmpty ? 'Not set' : _bucket,
            valueColor: _bucket.isEmpty ? Colors.white38 : Colors.white70,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            icon: Icons.language_rounded,
            label: 'Odoo Server',
            value: _odooUrl.isEmpty ? 'Waiting for Odoo...' : _odooUrl,
            valueColor: _odooUrl.isEmpty ? Colors.amber.withOpacity(0.7) : Colors.white70,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            icon: Icons.dns_rounded,
            label: 'API Server',
            value: 'localhost$_listenAddr',
            valueColor: Colors.white70,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            icon: Icons.lock_rounded,
            label: 'SSL',
            value: _secure ? 'Enabled' : 'Disabled',
            valueColor: _secure ? const Color(0xFF4ADE80) : Colors.white38,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator() {
    const Color activeColor = Color(0xFF4ADE80);
    const Color waitingColor = Color(0xFFF59E0B);
    const Color inactiveColor = Color(0xFF374151);

    final bool isWaiting = !_isConnected && _endpoint.isEmpty && !_isLoading;
    final Color currentColor = _isConnected
        ? activeColor
        : isWaiting
            ? waitingColor
            : inactiveColor;

    final String statusText = _isLoading
        ? 'Starting...'
        : _isConnected
            ? 'Connected'
            : isWaiting
                ? 'Waiting for config'
                : 'Disconnected';

    final String subtitle = _isLoading
        ? 'Initializing service...'
        : _isConnected
            ? 'Sync service is active'
            : isWaiting
                ? 'Open Odoo to auto-configure'
                : 'MinIO connection failed';

    return Column(
      children: [
        // Status circle
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: currentColor.withOpacity(0.12),
            border: Border.all(
              color: currentColor.withOpacity(0.5),
              width: 3,
            ),
            boxShadow: _isConnected
                ? [
                    BoxShadow(
                      color: activeColor.withOpacity(0.25),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ]
                : [],
          ),
          child: _isLoading
              ? const Padding(
                  padding: EdgeInsets.all(28),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white54,
                  ),
                )
              : Icon(
                  _isConnected
                      ? Icons.cloud_done_rounded
                      : isWaiting
                          ? Icons.hourglass_top_rounded
                          : Icons.cloud_off_rounded,
                  color: currentColor,
                  size: 40,
                ),
        ),
        const SizedBox(height: 16),

        // Status text
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 300),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: currentColor,
          ),
          child: Text(statusText),
        ),
        const SizedBox(height: 4),

        // Subtitle with pulse when waiting
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withOpacity(
                  isWaiting ? 0.3 + _pulseController.value * 0.3 : 0.4,
                ),
                fontSize: 13,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String label,
    required String value,
    Color valueColor = Colors.white70,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white24, size: 18),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontSize: 13),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isConnected
                  ? const Color(0xFF4ADE80)
                  : _endpoint.isEmpty
                      ? const Color(0xFFF59E0B)
                      : const Color(0xFF6B7280),
              boxShadow: _isConnected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF4ADE80).withOpacity(0.5),
                        blurRadius: 6,
                      ),
                    ]
                  : [],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _hostname.isNotEmpty ? _hostname : 'MinIO Sync',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 12,
            ),
          ),
          const Spacer(),
          Text(
            'Port ${_listenAddr.replaceFirst(':', '')}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
