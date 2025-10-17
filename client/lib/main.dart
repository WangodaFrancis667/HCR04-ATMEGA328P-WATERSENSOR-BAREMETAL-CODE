import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

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
      home: const MonitorScreen(),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  // Bluetooth connection
  BluetoothConnection? connection;
  bool isConnected = false;
  bool isConnecting = false;
  
  // Sensor data
  double distance = 0.0;
  int waterQuality = 0;
  String status = 'EMPTY';
  bool alert = false;
  
  // Available Bluetooth devices
  List<BluetoothDevice> devices = [];

  @override
  void initState() {
    super.initState();
    _getBondedDevices();
  }

  @override
  void dispose() {
    connection?.dispose();
    super.dispose();
  }

  // Get list of paired Bluetooth devices
  Future<void> _getBondedDevices() async {
    try {
      List<BluetoothDevice> bondedDevices = 
          await FlutterBluetoothSerial.instance.getBondedDevices();
      setState(() {
        devices = bondedDevices;
      });
    } catch (e) {
      debugPrint('Error getting devices: $e');
    }
  }

  // Connect to HC-05 Bluetooth module
  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      isConnecting = true;
    });

    try {
      BluetoothConnection newConnection = 
          await BluetoothConnection.toAddress(device.address);
      
      setState(() {
        connection = newConnection;
        isConnected = true;
        isConnecting = false;
      });

      // Listen for incoming data
      connection!.input!.listen((data) {
        _handleData(data);
      }).onDone(() {
        setState(() {
          isConnected = false;
        });
      });

    } catch (e) {
      debugPrint('Connection error: $e');
      setState(() {
        isConnecting = false;
      });
    }
  }

  // Disconnect from Bluetooth
  void _disconnect() {
    connection?.dispose();
    setState(() {
      isConnected = false;
      connection = null;
    });
  }

  // Parse incoming JSON data
  void _handleData(List<int> data) {
    String jsonString = utf8.decode(data).trim();
    
    try {
      Map<String, dynamic> json = jsonDecode(jsonString);
      
      setState(() {
        distance = (json['distance'] ?? 0).toDouble();
        waterQuality = json['water'] ?? 0;
        status = json['status'] ?? 'EMPTY';
        alert = json['alert'] == 1;
      });
    } catch (e) {
      debugPrint('JSON parse error: $e');
    }
  }

  // Get status color based on current state
  Color _getStatusColor() {
    switch (status) {
      case 'CONTAMINATED':
        return Colors.red;
      case 'OVERFLOW':
        return Colors.green;
      case 'HALF_FULL':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  // Get status icon
  IconData _getStatusIcon() {
    switch (status) {
      case 'CONTAMINATED':
        return Icons.warning;
      case 'OVERFLOW':
        return Icons.water_drop;
      case 'HALF_FULL':
        return Icons.waves;
      default:
        return Icons.water;
    }
  }

  // Get readable status text
  String _getStatusText() {
    switch (status) {
      case 'CONTAMINATED':
        return 'Water Contaminated!';
      case 'OVERFLOW':
        return 'Overflow Warning';
      case 'HALF_FULL':
        return 'Tank Half Full';
      default:
        return 'Tank Empty';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Tank Monitor'),
        backgroundColor: _getStatusColor(),
        actions: [
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_connected),
              onPressed: _disconnect,
              tooltip: 'Disconnect',
            ),
        ],
      ),
      body: Column(
        children: [
          // Connection Section
          if (!isConnected) _buildConnectionSection(),
          
          // Main Display Section
          if (isConnected) Expanded(child: _buildMainDisplay()),
        ],
      ),
    );
  }

  // Build connection selection UI
  Widget _buildConnectionSection() {
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.bluetooth_searching,
                size: 100,
                color: Colors.blue,
              ),
              const SizedBox(height: 20),
              const Text(
                'Select HC-05 Device',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),
              if (isConnecting)
                const CircularProgressIndicator()
              else
                ...devices.map((device) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  child: ListTile(
                    leading: const Icon(Icons.bluetooth),
                    title: Text(device.name ?? 'Unknown'),
                    subtitle: Text(device.address),
                    onTap: () => _connectToDevice(device),
                  ),
                )),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _getBondedDevices,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Devices'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Build main sensor display UI
  Widget _buildMainDisplay() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Status Card
          Card(
            color: _getStatusColor().withValues(alpha: 0.2),
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                children: [
                  Icon(
                    _getStatusIcon(),
                    size: 80,
                    color: _getStatusColor(),
                  ),
                  const SizedBox(height: 15),
                  Text(
                    _getStatusText(),
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: _getStatusColor(),
                    ),
                  ),
                  if (alert)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                        '⚠️ ALERT ACTIVE',
                        style: TextStyle(
                          fontSize: 18,
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Distance Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Icon(Icons.height, size: 50, color: Colors.blue),
                  const SizedBox(height: 10),
                  const Text(
                    'Water Level',
                    style: TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    distance > 0 ? '${distance.toStringAsFixed(1)} cm' : 'No Reading',
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Water Quality Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Icon(Icons.opacity, size: 50, color: Colors.teal),
                  const SizedBox(height: 10),
                  const Text(
                    'Water Quality',
                    style: TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$waterQuality / 1023',
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    waterQuality < 100 ? 'Clean' : 'Contaminated',
                    style: TextStyle(
                      fontSize: 16,
                      color: waterQuality < 100 ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}