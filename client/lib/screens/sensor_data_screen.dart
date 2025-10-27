import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'bluetooth_connection_screen.dart'; // Make sure this import is correct
import '../database/database_helper.dart';
import '../models/sensor_reading.dart';

class SensorDataScreen extends StatefulWidget {
  final BluetoothConnection connection;
  final BluetoothDevice device;
  // Optional callback to notify parent when the user disconnects.
  final VoidCallback? onDisconnect;

  const SensorDataScreen({
    super.key,
    required this.connection,
    required this.device,
    this.onDisconnect,
  });

  @override
  State<SensorDataScreen> createState() => _SensorDataScreenState();
}

class _SensorDataScreenState extends State<SensorDataScreen> {
  // ============================================================================
  //                        THEME COLORS
  // ============================================================================
  static const Color _primaryBlue = Color(0xFF0D47A1); // A deep, classic blue
  static const Color _lightBlueBackground = Color(
    0xFFE3F2FD,
  ); // Very light blue
  static const Color _cardBackground = Colors.white;
  static const Color _primaryText = Color(0xFF212121);
  static const Color _secondaryText = Color(0xFF757575);

  // ============================================================================
  //                        SENSOR DATA VARIABLES
  // ============================================================================

  // Current sensor readings (matches Arduino JSON format)
  int timestamp = 0; // Milliseconds since Arduino startup
  int distance = 0; // Distance in centimeters
  int waterQuality = 0; // Water sensor ADC value (0-1023)
  String status = 'EMPTY'; // EMPTY, HALF_FULL, OVERFLOW, CONTAMINATED
  bool alert = false; // Alert flag (true/false)

  // Data buffer for handling chunked data from HC-05
  String dataBuffer = '';

  // Last update time for connection monitoring
  DateTime? lastDataReceived;

  // Connection monitoring timer
  Timer? connectionMonitor;

  // Connection status
  bool isConnected = true;

  @override
  void initState() {
    super.initState();
    _startListeningForData();
    _startConnectionMonitoring();
  }

  @override
  void dispose() {
    connectionMonitor?.cancel();
    widget.connection.dispose();
    super.dispose();
  }

  // ============================================================================
  //                        DATA RECEPTION & PARSING
  // ============================================================================

  void _startListeningForData() {
    debugPrint('Starting data listener...');

    widget.connection.input!.listen(
      (data) {
        _handleIncomingData(data);
      },
      onDone: () {
        debugPrint('Connection closed by remote device');
        _handleDisconnection();
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

  Future<void> _parseJsonData(String jsonString) async {
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

      // Persist the reading to the local SQLite database.
      try {
        final reading = SensorReading(
          timestamp: DateTime.now(),
          distance: distance,
          waterQuality: waterQuality,
          status: status,
          alert: alert,
          arduinoUptime: timestamp,
          deviceName: widget.device.name ?? '',
          deviceAddress: widget.device.address,
        );

        // Insert and log the assigned id (DatabaseHelper also prints on insert)
        final id = await DatabaseHelper.instance.insertReading(reading);
        debugPrint('Sensor reading persisted with id: $id');
      } catch (dbError) {
        debugPrint('Error inserting reading into DB: $dbError');
      }
    } catch (e) {
      debugPrint('JSON parse error: $e');
      debugPrint('Failed JSON string: $jsonString');
    }
  }

  // ============================================================================
  //                        CONNECTION MONITORING
  // ============================================================================

  void _startConnectionMonitoring() {
    connectionMonitor = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!isConnected) {
        timer.cancel();
        return;
      }

      // Check if we've received data recently (within 5 seconds)
      if (lastDataReceived != null) {
        final timeSinceLastData = DateTime.now()
            .difference(lastDataReceived!)
            .inSeconds;

        if (timeSinceLastData > 5) {
          debugPrint(
            'Warning: No data received for $timeSinceLastData seconds',
          );

          if (timeSinceLastData > 10) {
            debugPrint('Connection appears dead, disconnecting...');
            _handleDisconnection();
            _showSnackBar('Connection lost - no data received', Colors.red);
          }
        }
      }
    });
  }

  void _handleDisconnection() {
    setState(() {
      isConnected = false;
    });

    connectionMonitor?.cancel();
    // Notify parent if it provided a disconnect handler (preferred). The
    // parent (e.g. MainNavigationScreen) can update its state and show the
    // connection screen. If no handler is provided, fall back to navigating
    // back to the connection screen directly.
    if (widget.onDisconnect != null) {
      widget.onDisconnect!();
    } else {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => BluetoothConnectionScreen(
              onConnectionEstablished:
                  (BluetoothConnection connection, BluetoothDevice device) {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SensorDataScreen(
                          connection: connection,
                          device: device,
                        ),
                      ),
                    );
                  },
            ),
          ),
        );
      }
    }
  }

  void _manualDisconnect() async {
    try {
      connectionMonitor?.cancel();
      await widget.connection.close();

      _showSnackBar('Disconnected', Colors.orange);
      debugPrint('Manually disconnected from device');

      // Navigate back to connection screen
      if (widget.onDisconnect != null) {
        widget.onDisconnect!();
      } else if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => BluetoothConnectionScreen(
              onConnectionEstablished:
                  (BluetoothConnection connection, BluetoothDevice device) {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SensorDataScreen(
                          connection: connection,
                          device: device,
                        ),
                      ),
                    );
                  },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error disconnecting: $e');
    }
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
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10.0),
        ),
      ),
    );
  }

  // Updated to use the blue theme for default states
  Color _getStatusColor() {
    switch (status) {
      case 'CONTAMINATED':
        return Colors.red[700]!;
      case 'OVERFLOW':
        return Colors.orange[700]!;
      case 'HALF_FULL':
        return Colors.blue[600]!; // A slightly lighter blue for "half"
      case 'EMPTY':
      default:
        return _primaryBlue; // Default "all clear" state is blue
    }
  }

  IconData _getStatusIcon() {
    switch (status) {
      case 'CONTAMINATED':
        return Icons.warning_amber_rounded;
      case 'OVERFLOW':
        return Icons.water_drop_rounded;
      case 'HALF_FULL':
        return Icons.waves_rounded;
      case 'EMPTY':
      default:
        return Icons.check_circle_outline_rounded; // "Empty" is an OK state
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
  //                        UI BUILD METHOD
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _lightBlueBackground,
      appBar: AppBar(
        title: const Text('💧 Water Tank Monitor'),
        backgroundColor: _getStatusColor(), // AppBar color reflects status
        foregroundColor: Colors.white,
        elevation: 4.0,
        automaticallyImplyLeading: false, // Remove back button
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_connected),
            onPressed: _manualDisconnect,
            tooltip: 'Disconnect',
          ),
        ],
      ),
      body: SingleChildScrollView(
        // Use a more standard padding
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Connection Status Card
            _buildConnectionCard(),

            const SizedBox(height: 16),

            // Main Status Card
            _buildMainStatusCard(),

            const SizedBox(height: 16),

            // Sensor data tiles in a Grid
            _buildSensorGrid(),

            const SizedBox(height: 24),

            // Disconnect Button
            _buildDisconnectButton(),
          ],
        ),
      ),
    );
  }

  // ============================================================================
  //                        REFACTORED UI WIDGETS
  // ============================================================================

  /// A card showing the currently connected device and uptime.
  Widget _buildConnectionCard() {
    return Card(
      elevation: 2.0,
      color: _cardBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Row(
          children: [
            const Icon(
              Icons.bluetooth_connected,
              color: _primaryBlue,
              size: 28.0,
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected to ${widget.device.name ?? widget.device.address}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _primaryText,
                      fontSize: 16.0,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _getTimestampDisplay(),
                    style: const TextStyle(fontSize: 12, color: _secondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The main card showing the most important system status.
  Widget _buildMainStatusCard() {
    final Color statusColor = _getStatusColor();

    return Card(
      // Use a light tint of the status color for the background
      color: statusColor.withValues(alpha: 0.15),
      elevation: 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22.0)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
        child: Column(
          children: [
            Icon(_getStatusIcon(), size: 72, color: statusColor),
            const SizedBox(height: 12),
            Text(
              _getStatusText(),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
              textAlign: TextAlign.center,
            ),

            // Show the "ALERT!" banner only if alert is true
            if (alert)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.red[700],
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.notification_important,
                      color: Colors.white,
                      size: 20,
                    ),
                    SizedBox(width: 8),
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
    );
  }

  /// A GridView for displaying the secondary sensor readings.
  Widget _buildSensorGrid() {
    // Determine colors for the water quality tile
    final bool isContaminated = waterQuality > 100;
    final Color qualityColor = isContaminated
        ? Colors.red[700]!
        : Colors.green[700]!;
    final IconData qualityIcon = isContaminated
        ? Icons.warning_amber_rounded
        : Icons.check_circle_rounded;

    // Determine colors for the distance tile
    final bool isDistanceValid = distance > 0;
    final Color distanceColor = isDistanceValid ? _primaryBlue : _secondaryText;

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 16.0,
      mainAxisSpacing: 16.0,
      shrinkWrap: true, // Important inside a SingleChildScrollView
      physics: const NeverScrollableScrollPhysics(), // Disables grid scrolling
      // *** FIX 1: Added childAspectRatio to prevent overflow ***
      // This makes the tiles taller than they are wide.
      // Adjust 0.85 up or down if needed (e.g., 0.8, 0.9).
      childAspectRatio: 0.85,

      children: [
        // Distance Tile
        _buildSensorTile(
          icon: Icons.height_rounded,
          iconColor: distanceColor,
          title: 'Water Level',
          value: isDistanceValid ? '$distance cm' : 'N/A',
          valueColor: distanceColor,
          description: _getDistanceDescription(),
        ),

        // Water Quality Tile
        _buildSensorTile(
          icon: qualityIcon,
          iconColor: qualityColor,
          title: 'Water Quality',
          value: '$waterQuality / 1023',
          valueColor: qualityColor,
          description: isContaminated ? 'Contaminated' : 'Clean',
        ),
      ],
    );
  }

  /// A reusable template for the sensor data tiles.
  /// *** FIX 2: Restructured Column for better layout ***
  Widget _buildSensorTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required Color valueColor,
    required String description,
  }) {
    return Card(
      elevation: 2.0,
      color: _cardBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          // This MainAxisAlignment now works on just two children
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // --- CHILD 1: The Header Row ---
            Row(
              children: [
                Icon(icon, color: iconColor, size: 24),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: _primaryText,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            // --- CHILD 2: The Data Column ---
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  ),
                  // Add this to prevent the value itself from overflowing
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(fontSize: 14, color: _secondaryText),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The final disconnect button.
  Widget _buildDisconnectButton() {
    return ElevatedButton.icon(
      onPressed: _manualDisconnect,
      icon: const Icon(Icons.bluetooth_disabled_rounded),
      label: const Text('Disconnect'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.red[700],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }
}
