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
  // ============================================================================
  //                        BLUETOOTH CONNECTION VARIABLES
  // ============================================================================
  
  BluetoothConnection? connection;
  BluetoothDevice? connectedDevice;
  bool isConnected = false;
  bool isConnecting = false;
  bool isBluetoothEnabled = false;
  String statusMessage = 'Checking Bluetooth...';
  
  // List of available Bluetooth devices
  List<BluetoothDevice> devices = [];
  
  // ============================================================================
  //                        SENSOR DATA VARIABLES
  // ============================================================================
  
  // Current sensor readings (matches Arduino JSON format)
  int timestamp = 0;          // Milliseconds since Arduino startup
  int distance = 0;           // Distance in centimeters
  int waterQuality = 0;       // Water sensor ADC value (0-1023)
  String status = 'EMPTY';    // EMPTY, HALF_FULL, OVERFLOW, CONTAMINATED
  bool alert = false;         // Alert flag (true/false)
  
  // Data buffer for handling chunked data from HC-05
  String dataBuffer = '';
  
  // Last update time for connection monitoring
  DateTime? lastDataReceived;
  
  // Connection monitoring timer
  Timer? connectionMonitor;

  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
  }

  @override
  void dispose() {
    connectionMonitor?.cancel();
    connection?.dispose();
    super.dispose();
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

      List<BluetoothDevice> bondedDevices = 
          await FlutterBluetoothSerial.instance.getBondedDevices();

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
      connectedDevice = device;
      statusMessage = 'Connecting to ${device.name ?? device.address}...';
    });

    try {
      debugPrint('Attempting to connect to ${device.name ?? device.address}');
      debugPrint('Device address: ${device.address}');

      // Connect to the HC-05 module
      connection = await BluetoothConnection.toAddress(device.address);
      
      debugPrint('Connected successfully!');

      setState(() {
        isConnected = true;
        isConnecting = false;
        statusMessage = 'Connected to ${device.name ?? device.address}';
      });

      _showSnackBar(
        'Connected to ${device.name ?? device.address}', 
        Colors.green,
      );

      // Start listening for incoming data
      _startListeningForData();
      
      // Start connection monitoring
      _startConnectionMonitoring();

    } catch (e) {
      debugPrint('Connection failed: $e');
      
      setState(() {
        isConnecting = false;
        isConnected = false;
        connection = null;
        connectedDevice = null;
        statusMessage = 'Connection failed: $e';
      });

      _showSnackBar('Failed to connect: $e', Colors.red);
    }
  }

  void _disconnect() async {
    try {
      connectionMonitor?.cancel();
      await connection?.close();
      
      setState(() {
        isConnected = false;
        connection = null;
        connectedDevice = null;
        dataBuffer = '';
        lastDataReceived = null;
        statusMessage = 'Disconnected';
        
        // Reset sensor data
        timestamp = 0;
        distance = 0;
        waterQuality = 0;
        status = 'EMPTY';
        alert = false;
      });

      _showSnackBar('Disconnected', Colors.orange);
      debugPrint('Disconnected from device');
    } catch (e) {
      debugPrint('Error disconnecting: $e');
    }
  }

  // ============================================================================
  //                        DATA RECEPTION & PARSING
  // ============================================================================

  void _startListeningForData() {
    if (connection == null) return;

    debugPrint('Starting data listener...');

    connection!.input!.listen(
      (data) {
        _handleIncomingData(data);
      },
      onDone: () {
        debugPrint('Connection closed by remote device');
        _disconnect();
      },
      onError: (error) {
        debugPrint('Data stream error: $error');
      },
    );
  }

  void _handleIncomingData(List<int> data) {
    try {
      // Convert bytes to string
      String chunk = String.fromCharCodes(data);
      debugPrint('Received chunk (${data.length} bytes): $chunk');

      // Add to buffer
      dataBuffer += chunk;

      // Process complete JSON messages (ending with newline)
      while (dataBuffer.contains('\n')) {
        int newlineIndex = dataBuffer.indexOf('\n');
        String jsonString = dataBuffer.substring(0, newlineIndex).trim();
        dataBuffer = dataBuffer.substring(newlineIndex + 1);

        debugPrint('Complete JSON message: $jsonString');

        // Parse JSON if not empty
        if (jsonString.isNotEmpty && jsonString.startsWith('{')) {
          _parseJsonData(jsonString);
        }
      }

      // Prevent buffer overflow (keep last 300 characters)
      if (dataBuffer.length > 300) {
        debugPrint('Buffer overflow protection: truncating buffer');
        dataBuffer = dataBuffer.substring(dataBuffer.length - 100);
      }

    } catch (e) {
      debugPrint('Data handling error: $e');
    }
  }

  void _parseJsonData(String jsonString) {
    try {
      // Parse JSON
      Map<String, dynamic> json = jsonDecode(jsonString);

      debugPrint('Parsed JSON: $json');

      // Update UI with new data
      setState(() {
        // Update timestamp (milliseconds since Arduino startup)
        timestamp = json['timestamp'] ?? 0;

        // Update distance (integer centimeters)
        distance = json['distance'] ?? 0;

        // Update water quality (0-1023 ADC value)
        waterQuality = json['water'] ?? 0;

        // Update status string
        status = json['status'] ?? 'EMPTY';

        // Update alert flag
        var alertValue = json['alert'];
        if (alertValue is int) {
          alert = alertValue == 1;
        } else if (alertValue is bool) {
          alert = alertValue;
        } else {
          alert = false;
        }

        // Update last received time
        lastDataReceived = DateTime.now();
      });

      debugPrint(
        'Updated sensor data: timestamp=$timestamp, distance=$distance cm, '
        'water=$waterQuality, status=$status, alert=$alert',
      );

    } catch (e) {
      debugPrint('JSON parse error: $e');
      debugPrint('Failed JSON string: $jsonString');
    }
  }

  // ============================================================================
  //                        CONNECTION MONITORING
  // ============================================================================

  void _startConnectionMonitoring() {
    connectionMonitor?.cancel();
    
    connectionMonitor = Timer.periodic(
      const Duration(seconds: 3),
      (timer) {
        if (!isConnected) {
          timer.cancel();
          return;
        }

        // Check if we've received data recently (within 5 seconds)
        if (lastDataReceived != null) {
          final timeSinceLastData = 
              DateTime.now().difference(lastDataReceived!).inSeconds;
          
          if (timeSinceLastData > 5) {
            debugPrint('Warning: No data received for $timeSinceLastData seconds');
            
            if (timeSinceLastData > 10) {
              debugPrint('Connection appears dead, disconnecting...');
              _disconnect();
              _showSnackBar('Connection lost - no data received', Colors.red);
            }
          }
        }
      },
    );
  }

  // ============================================================================
  //                        UI HELPER METHODS
  // ============================================================================

  void _showSnackBar(String message, Color backgroundColor) {
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Color _getStatusColor() {
    switch (status) {
      case 'CONTAMINATED':
        return Colors.red;
      case 'OVERFLOW':
        return Colors.orange;
      case 'HALF_FULL':
        return Colors.blue;
      case 'EMPTY':
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon() {
    switch (status) {
      case 'CONTAMINATED':
        return Icons.warning;
      case 'OVERFLOW':
        return Icons.water_drop;
      case 'HALF_FULL':
        return Icons.waves;
      case 'EMPTY':
      default:
        return Icons.water;
    }
  }

  String _getStatusText() {
    switch (status) {
      case 'CONTAMINATED':
        return 'Water Contaminated!';
      case 'OVERFLOW':
        return 'Overflow Warning';
      case 'HALF_FULL':
        return 'Tank Half Full';
      case 'EMPTY':
      default:
        return 'Tank Empty';
    }
  }

  String _getDistanceDescription() {
    if (distance <= 0) return 'No reading';
    if (distance <= 7) return 'Near overflow!';
    if (distance <= 15) return 'Half full';
    return 'Low water level';
  }

  String _getTimestampDisplay() {
    if (timestamp == 0) return 'Waiting for data...';
    
    // Convert milliseconds to readable format
    int seconds = (timestamp ~/ 1000) % 60;
    int minutes = (timestamp ~/ 60000) % 60;
    int hours = timestamp ~/ 3600000;
    
    return 'Uptime: ${hours}h ${minutes}m ${seconds}s';
  }

  // ============================================================================
  //                        UI BUILD METHODS
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('💧 Water Tank Monitor'),
        backgroundColor: isConnected ? _getStatusColor() : Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_connected),
              onPressed: _disconnect,
              tooltip: 'Disconnect',
            )
          else if (isBluetoothEnabled)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _getBondedDevices,
              tooltip: 'Refresh Devices',
            ),
        ],
      ),
      body: !isConnected 
          ? _buildConnectionSection() 
          : _buildMainDisplay(),
    );
  }

  // ============================================================================
  //                        CONNECTION SECTION UI
  // ============================================================================

  Widget _buildConnectionSection() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isBluetoothEnabled 
                  ? Icons.bluetooth_searching 
                  : Icons.bluetooth_disabled,
              size: 100,
              color: isBluetoothEnabled ? Colors.blue : Colors.grey,
            ),
            const SizedBox(height: 20),
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
            Text(
              statusMessage,
              style: const TextStyle(
                fontSize: 14, 
                color: Colors.grey,
              ),
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
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
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
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
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
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      final deviceName = device.name ?? 'Unnamed Device';
                      final isHC05 = deviceName.toUpperCase().contains('HC') || 
                                     deviceName.toUpperCase().contains('BLUETOOTH');

                      return ListTile(
                        leading: Icon(
                          Icons.bluetooth,
                          color: isHC05 ? Colors.blue : Colors.grey,
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
                                : Colors.blue,
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
                    'Connecting to ${connectedDevice?.name ?? "device"}...',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ============================================================================
  //                        MAIN DISPLAY UI (SENSOR DATA)
  // ============================================================================

  Widget _buildMainDisplay() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Connection Status Card
          Card(
            color: Colors.blue.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.bluetooth_connected, 
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected to ${connectedDevice?.name ?? connectedDevice?.address ?? "Device"}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _getTimestampDisplay(),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Status Card
          Card(
            color: _getStatusColor().withOpacity(0.2),
            elevation: 4,
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
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _getStatusColor(),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (alert)
                    Container(
                      margin: const EdgeInsets.only(top: 15),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.notification_important,
                            color: Colors.white,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'ALERT ACTIVE!',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Distance Card
          Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Icon(
                    Icons.height, 
                    size: 50, 
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Distance to Water Surface',
                    style: TextStyle(
                      fontSize: 20, 
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    distance > 0 ? '$distance cm' : 'No Reading',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: distance > 0 ? Colors.blue : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _getDistanceDescription(),
                    style: const TextStyle(
                      fontSize: 14, 
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Water Quality Card
          Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    waterQuality > 100 
                        ? Icons.warning_amber 
                        : Icons.check_circle,
                    size: 50,
                    color: waterQuality > 100 ? Colors.red : Colors.green,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Water Quality Sensor',
                    style: TextStyle(
                      fontSize: 20, 
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$waterQuality / 1023',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: waterQuality > 100 ? Colors.red : Colors.green,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    waterQuality > 100 ? 'Contaminated' : 'Clean',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: waterQuality > 100 ? Colors.red : Colors.green,
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