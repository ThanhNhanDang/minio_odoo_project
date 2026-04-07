import 'package:flutter/material.dart';

class PopupWindow extends StatelessWidget {
  const PopupWindow({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // Requires window_manager styling to support transparency
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E).withOpacity(0.95), // Dark mode glassmorphism
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 15,
              offset: const Offset(0, 5),
            )
          ],
          border: Border.all(
            color: Colors.white.withOpacity(0.1),
            width: 1,
          )
        ),
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'WARP SYNC', // Sample Title
            style: const TextStyle(
              color: Colors.deepOrangeAccent,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 2.0
            ),
          )
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Huge Toggle Button
        Container(
          width: 200,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.deepOrangeAccent,
            borderRadius: BorderRadius.circular(50),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Container(
            width: 80,
            height: 80,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(height: 30),
        const Text(
          'Connected',
          style: TextStyle(color: Colors.white, fontSize: 24),
        ),
        const SizedBox(height: 10),
        RichText(
          text: const TextSpan(
            style: TextStyle(color: Colors.white70, fontSize: 16),
            children: [
              TextSpan(text: 'Your connection is '),
              TextSpan(
                text: 'private.',
                style: TextStyle(color: Colors.deepOrangeAccent, fontWeight: FontWeight.bold),
              )
            ]
          ),
        )
      ],
    );
  }
}
