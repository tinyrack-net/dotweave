import 'package:flutter/material.dart';

void main() {
  runApp(const ShipworldFixture());
}

class ShipworldFixture extends StatelessWidget {
  const ShipworldFixture({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('shipworld fixture'))),
    );
  }
}
