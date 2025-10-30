import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
// We don't need to import SensorDataScreen here anymore
// import 'sensor_data_screen.dart';

class BluetoothConnectionScreen extends StatefulWidget {
  // 1. Accept the callback
  final Function(BluetoothConnection, BluetoothDevice) onConnectionEstablished;

  // 2. Update the constructor
  const BluetoothConnectionScreen({
    super.key,
    required this.onConnectionEstablished,
  });

  @override
  State<BluetoothConnectionScreen> createState() =>
      _BluetoothConnectionScreenState();
}

class _BluetoothConnectionScreenState extends State<BluetoothConnectionScreen> {
  // ============================================================================
  //                        BLUETOOTH VARIABLES
  // ============================================================================

  bool isBluetoothEnabled = false;
  bool isConnecting = false;
  String statusMessage = 'Checking Bluetooth...';

  // List of available Bluetooth devices
  List<BluetoothDevice> devices = [];
  BluetoothDevice? selectedDevice;

  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
  }

  // ============================================================================
  //                        BLUETOOTH INITIALIZATION
  // ============================================================================

  void _initializeBluetooth() async {
    try {
      // Check if Bluetooth is enabled
      bool? isEnabled = await FlutterBluetoothSerial.instance.isEnabled;

      setState(() {
        isBluetoothEnabled = isEnabled ?? false;
        statusMessage = isBluetoothEnabled
            ? 'Bluetooth enabled. Tap "Load Paired Devices"'
            : 'Bluetooth is disabled';
      });

      if (isBluetoothEnabled) {
        _getBondedDevices();
      }
    } catch (e) {
      setState(() {
        statusMessage = 'Error checking Bluetooth: $e';
      });
      debugPrint('Bluetooth initialization error: $e');
    }
  }

  // ============================================================================
  //                        BLUETOOTH DEVICE DISCOVERY
  // ============================================================================

  void _enableBluetooth() async {
    try {
      await FlutterBluetoothSerial.instance.requestEnable();
      _initializeBluetooth();
    } catch (e) {
      setState(() {
        statusMessage = 'Failed to enable Bluetooth: $e';
      });
    }
  }

  void _getBondedDevices() async {
    try {
      setState(() {
        statusMessage = 'Loading paired devices...';
      });

      // Bluetooth runtime permissions are requested in the Android native side
      // (MainActivity) for Android 12+ to avoid needing the permission_handler plugin.

      List<BluetoothDevice> bondedDevices = await FlutterBluetoothSerial
          .instance
          .getBondedDevices();

      setState(() {
        devices = bondedDevices;
        statusMessage = devices.isEmpty
            ? 'No paired devices found. Please pair your HC-05 module first.'
            : 'Found ${devices.length} paired device(s)';
      });

      debugPrint('Found ${devices.length} bonded devices');
      for (var device in devices) {
        debugPrint('  - ${device.name ?? "Unnamed"} (${device.address})');
      }
    } catch (e) {
      setState(() {
        statusMessage = 'Error loading devices: $e';
      });
      debugPrint('Error getting bonded devices: $e');
    }
  }

  // ============================================================================
  //                        BLUETOOTH CONNECTION
  // ============================================================================

  void _connectToDevice(BluetoothDevice device) async {
    setState(() {
      isConnecting = true;
      selectedDevice = device;
      statusMessage = 'Connecting to ${device.name ?? device.address}...';
    });

    try {
      debugPrint('Attempting to connect to ${device.name ?? device.address}');
      debugPrint('Device address: ${device.address}');

      // Connect to the HC-05 module
      BluetoothConnection connection = await BluetoothConnection.toAddress(
        device.address,
      );

      debugPrint('Connected successfully!');

      setState(() {
        isConnecting = false;
      });

      // Show success message
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connected to ${device.name ?? device.address}'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );

      // 3. FIX: Call the callback instead of navigating
      widget.onConnectionEstablished(connection, device);

      // REMOVED:
      // Navigator.pushReplacement(
      //   context,
      //   MaterialPageRoute(
      //     builder: (context) => SensorDataScreen(
      //       connection: connection,
      //       device: device,
      //     ),
      //   ),
      // );
    } catch (e) {
      debugPrint('Connection failed: $e');

      setState(() {
        isConnecting = false;
        selectedDevice = null;
        statusMessage = 'Connection failed: $e';
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to connect: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ============================================================================
  //                        UI BUILD METHOD
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to Petrol Tank System'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        actions: [
          if (isBluetoothEnabled)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _getBondedDevices,
              tooltip: 'Refresh Devices',
            ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Bluetooth Icon
              Icon(
                isBluetoothEnabled
                    ? Icons.bluetooth_searching
                    : Icons.bluetooth_disabled,
                size: 100,
                color: isBluetoothEnabled
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),

              const SizedBox(height: 20),

              // Title
              Text(
                isBluetoothEnabled
                    ? 'Select HC-05 Device'
                    : 'Bluetooth Disabled',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 10),

              // Status Message
              Text(
                statusMessage,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 30),

              // Enable Bluetooth Button
              if (!isBluetoothEnabled)
                ElevatedButton.icon(
                  onPressed: _enableBluetooth,
                  icon: const Icon(Icons.bluetooth),
                  label: const Text('Enable Bluetooth'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 30,
                      vertical: 15,
                    ),
                  ),
                ),

              // Load Paired Devices Button
              if (isBluetoothEnabled && !isConnecting)
                ElevatedButton.icon(
                  onPressed: _getBondedDevices,
                  icon: const Icon(Icons.devices),
                  label: const Text('Load Paired Devices'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 30,
                      vertical: 15,
                    ),
                  ),
                ),

              const SizedBox(height: 20),

              // Device List
              if (devices.isNotEmpty && !isConnecting)
                Container(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: Card(
                    elevation: 4,
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: devices.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final deviceName = device.name ?? 'Unnamed Device';
                        final isHC05 =
                            deviceName.toUpperCase().contains('HC') ||
                            deviceName.toUpperCase().contains('BLUETOOTH');

                        return ListTile(
                          leading: Icon(
                            Icons.bluetooth,
                            color: isHC05
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey,
                          ),
                          title: Text(
                            deviceName,
                            style: TextStyle(
                              fontWeight: isHC05
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            device.address,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: ElevatedButton(
                            onPressed: () => _connectToDevice(device),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isHC05
                                  ? Colors.green
                                  : Theme.of(context).colorScheme.primary,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Connect'),
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // Connecting Indicator
              if (isConnecting)
                Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 15),
                    Text(
                      'Connecting to ${selectedDevice?.name ?? "device"}...',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
