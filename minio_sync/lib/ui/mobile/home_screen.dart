import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MinIO Sync Mobile'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
             Icon(Icons.cloud_sync, size: 80, color: Theme.of(context).primaryColor),
             const SizedBox(height: 20),
             const Text('Mobile direct API sync is ready', style: TextStyle(fontSize: 18)),
          ],
        ),
      ),
    );
  }
}
