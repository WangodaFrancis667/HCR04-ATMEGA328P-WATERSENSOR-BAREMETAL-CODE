import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'screens/bluetooth_connection_screen.dart';
import 'screens/sensor_data_screen.dart';
import 'screens/logs_screen.dart';

void main() {
  runApp(const WaterTankMonitorApp());
}

class WaterTankMonitorApp extends StatelessWidget {
  const WaterTankMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Water Tank Monitor with Logging',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        // Using the blue theme from your Sensor screen
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D47A1)),
        useMaterial3: true,
      ),
      home: const MainNavigationScreen(),
    );
  }
}

/// Main navigation screen with bottom navigation bar
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  // Connection state shared across screens
  BluetoothConnection? _connection;
  BluetoothDevice? _connectedDevice;
  bool _isConnected = false;

  /// Handle connection from Screen 1
  void _onConnectionEstablished(
    BluetoothConnection connection,
    BluetoothDevice device,
  ) {
    setState(() {
      _connection = connection;
      _connectedDevice = device;
      _isConnected = true;
      _currentIndex = 1; // Navigate to sensor data screen
    });
  }

  /// Handle disconnection
  void _onDisconnection() {
    setState(() {
      _connection?.dispose(); // Ensure connection is closed
      _connection = null;
      _connectedDevice = null;
      _isConnected = false;
      _currentIndex = 0; // Navigate back to connection screen
    });
  }

  /// Get the current screen based on index
  Widget _getCurrentScreen() {
    switch (_currentIndex) {
      case 0:
        return BluetoothConnectionScreen(
          // Pass the callback to the child
          onConnectionEstablished: _onConnectionEstablished,
        );
      case 1:
        if (_isConnected && _connection != null && _connectedDevice != null) {
          return SensorDataScreen(
            connection: _connection!,
            device: _connectedDevice!,
            // Pass the callback to the child
            onDisconnect: _onDisconnection,
          );
        } else {
          // Show placeholder if not connected
          return _buildNotConnectedScreen();
        }
      case 2:
        return const LogsScreen(); // Assumes LogsScreen exists
      default:
        return BluetoothConnectionScreen(
          onConnectionEstablished: _onConnectionEstablished,
        );
    }
  }

  /// Build a placeholder screen for sensor data when not connected
  Widget _buildNotConnectedScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('💧 Sensor Data'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bluetooth_disabled, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 20),
            Text(
              'Not Connected',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Connect to a device to view sensor data',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _currentIndex = 0; // Navigate to connection screen
                });
              },
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Go to Connection'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _connection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          // We render all screens to preserve their state
          BluetoothConnectionScreen(
            onConnectionEstablished: _onConnectionEstablished,
          ),
          _isConnected && _connection != null && _connectedDevice != null
              ? SensorDataScreen(
                  connection: _connection!,
                  device: _connectedDevice!,
                  onDisconnect: _onDisconnection,
                )
              : _buildNotConnectedScreen(),
          const LogsScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          // Prevent navigation to sensor data if not connected
          if (index == 1 && !_isConnected) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please connect to a device first'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
            return;
          }

          setState(() {
            _currentIndex = index;
          });
        },
        items: [
          BottomNavigationBarItem(
            icon: Icon(
              _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
            ),
            label: 'Connection',
            tooltip: 'Bluetooth Connection',
          ),
          BottomNavigationBarItem(
            icon: Badge(
              // Use isConnected to control the badge
              isLabelVisible: _isConnected,
              label: const Text('Live'),
              backgroundColor: Colors.green,
              child: const Icon(Icons.water_drop),
            ),
            label: 'Sensor Data',
            tooltip: 'Real-time Sensor Data',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Logs',
            tooltip: 'View Logged Data',
          ),
        ],
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }
}
