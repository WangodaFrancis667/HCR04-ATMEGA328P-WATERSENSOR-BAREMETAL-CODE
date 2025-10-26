import 'package:flutter/material.dart';
import 'screens/bluetooth_connection_screen.dart';

void main() {
  runApp(const WaterTankMonitorApp());
}

class WaterTankMonitorApp extends StatelessWidget {
  const WaterTankMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Water Tank Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const BluetoothConnectionScreen(),
    );
  }
}