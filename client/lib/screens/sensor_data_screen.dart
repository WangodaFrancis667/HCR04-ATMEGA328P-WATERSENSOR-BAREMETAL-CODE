import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  double percentage = 0.0; // Fill percentage (0.0 - 100.0)
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

  // User-configurable tank height (cm) - optional
  double? tankHeight;

  // Controller for height input
  final TextEditingController _heightController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _startListeningForData();
    _startConnectionMonitoring();
    _loadSavedTankHeight();
  }

  @override
  void dispose() {
    connectionMonitor?.cancel();
    _heightController.dispose();
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

      // Process complete messages (ending with newline)
      while (dataBuffer.contains('\n')) {
        int newlineIndex = dataBuffer.indexOf('\n');
        String msg = dataBuffer.substring(0, newlineIndex).trim();
        dataBuffer = dataBuffer.substring(newlineIndex + 1);

        debugPrint('Complete message: $msg');

        if (msg.isEmpty) continue;

        // If it's JSON (legacy or some confirmations), parse as JSON
        if (msg.startsWith('{')) {
          _parseJsonData(msg);
        } else {
          // Otherwise it's the MCU's ASCII protocol: T:...,P:...,W:...,S:...,A:... or H:<value>
          _parsePlainPacket(msg);
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

      // If MCU returns a dedicated 'height' key, treat it as confirmation
      if (json.containsKey('height')) {
        var h = json['height'];
        if (h is num) {
          final double confirmed = h.toDouble();
          // Update UI and persist locally
          setState(() {
            tankHeight = confirmed;
            _heightController.text = confirmed.toStringAsFixed(1);
          });
          await _saveTankHeightLocally(confirmed);
          if (mounted) {
            _showSnackBar(
              'Tank height confirmed: ${confirmed.toStringAsFixed(1)} cm',
              Colors.green,
            );
          }
          // Continue to parse telemetry in the same message if present
        }
      }

      // Distinguish telemetry messages from simple confirmations
      // Telemetry messages include keys like 'percentage', 'water' or 'timestamp'.
      // Simple confirmations from MCU (e.g. {"status":"..."}) may only include a 'status' field.
      final bool looksLikeTelemetry =
          json.containsKey('percentage') ||
          json.containsKey('water') ||
          json.containsKey('timestamp');

      if (!looksLikeTelemetry && json.containsKey('status')) {
        // This is likely a confirmation/notice from MCU. Show it to the user.
        final String msg = json['status'].toString();
        if (mounted) _showSnackBar(msg, Colors.green);
        return;
      }

      // Update UI with telemetry data
      setState(() {
        // Update timestamp (milliseconds since Arduino startup)
        timestamp = json['timestamp'] ?? 0;

        // Update percentage (newer firmware sends percentage)
        if (json.containsKey('percentage')) {
          var p = json['percentage'];
          if (p is num) {
            percentage = p.toDouble();
          } else if (p is String) {
            percentage = double.tryParse(p) ?? percentage;
          }
        }

        // Update distance: prefer explicit 'distance' field from MCU if present,
        // otherwise compute from percentage and known tank height (if set).
        if (json['distance'] != null) {
          distance = (json['distance'] as num).toInt();
        } else if (percentage > 0.0 && tankHeight != null) {
          // Compute distance from top sensor to water surface in cm.
          // If percentage is fill percent (0 = empty, 100 = full), then
          // distance = tankHeight * (1 - percentage/100).
          final double computed = tankHeight! * (1.0 - (percentage / 100.0));
          distance = computed.round();
        }

        // Update water quality (0-1023 ADC value)
        waterQuality = (json['water'] is num)
            ? (json['water'] as num).toInt()
            : (json['water'] ?? waterQuality);

        // Update status string
        status = json['status'] ?? status;

        // Update alert flag
        var alertValue = json['alert'];
        if (alertValue is int) {
          alert = alertValue == 1;
        } else if (alertValue is bool) {
          alert = alertValue;
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
          percentage: percentage,
          tankHeight: tankHeight,
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

  /// Parse the MCU ASCII status packets and confirmations.
  /// Expected formats:
  /// - Telemetry: "T:12345,P:50,W:123,S:2,A:1" (keys separated by commas)
  /// - Height confirmation: "H:100" (integer cm)
  Future<void> _parsePlainPacket(String packet) async {
    try {
      final s = packet.trim();
      if (s.isEmpty) return;

      // Handle simple height confirmation: "H:100" or "H:100\r"
      if (s.startsWith('H:')) {
        final rest = s.substring(2).trim();
        final int? h = int.tryParse(rest);
        if (h != null) {
          setState(() {
            tankHeight = h.toDouble();
            _heightController.text = tankHeight!.toStringAsFixed(1);
          });
          await _saveTankHeightLocally(tankHeight!);
          if (mounted) {
            _showSnackBar(
              'Tank height confirmed: ${tankHeight!.toStringAsFixed(1)} cm',
              Colors.green,
            );
          }
        }
        return;
      }

      // Otherwise parse key:value pairs separated by commas
      final parts = s.split(',');
      int? parsedTimestamp;
      int? parsedP;
      int? parsedW;
      int? parsedS;
      int? parsedA;

      for (var part in parts) {
        final token = part.trim();
        if (!token.contains(':')) continue;
        final kv = token.split(':');
        if (kv.length < 2) continue;
        final key = kv[0].trim();
        final value = kv.sublist(1).join(':').trim();

        switch (key) {
          case 'T':
            parsedTimestamp = int.tryParse(value);
            break;
          case 'P':
            parsedP = int.tryParse(value);
            break;
          case 'W':
            parsedW = int.tryParse(value);
            break;
          case 'S':
            parsedS = int.tryParse(value);
            break;
          case 'A':
            parsedA = int.tryParse(value);
            break;
          default:
            break;
        }
      }

      // If this looks like telemetry, update UI and persist
      final bool hasTelemetry =
          parsedTimestamp != null ||
          parsedP != null ||
          parsedW != null ||
          parsedS != null ||
          parsedA != null;
      if (!hasTelemetry) return;

      // Map status code to string (matches MCU enum)
      String mapStatus(int code) {
        switch (code) {
          case 3:
            return 'CONTAMINATED';
          case 2:
            return 'OVERFLOW';
          case 1:
            return 'HALF_FULL';
          case 0:
          default:
            return 'EMPTY';
        }
      }

      setState(() {
        if (parsedTimestamp != null) timestamp = parsedTimestamp;
        if (parsedP != null) percentage = parsedP.toDouble();

        // Compute distance from percentage when tankHeight is known. If the MCU
        // provided an explicit distance field in other packets use that (not
        // available in the compact ASCII format), so here we compute.
        if (parsedP != null && tankHeight != null) {
          final double computed = tankHeight! * (1.0 - (percentage / 100.0));
          distance = computed.round();
        }

        if (parsedW != null) waterQuality = parsedW;
        if (parsedS != null) status = mapStatus(parsedS);
        if (parsedA != null) alert = parsedA == 1;
        lastDataReceived = DateTime.now();
      });

      // Persist reading to DB (distance unknown in this packet, keep previous)
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
          percentage: percentage,
          tankHeight: tankHeight,
        );

        final id = await DatabaseHelper.instance.insertReading(reading);
        debugPrint('Persisted reading from plain packet with id: $id');
      } catch (dbError) {
        debugPrint('DB insert error for plain packet: $dbError');
      }
    } catch (e) {
      debugPrint('Plain packet parse error: $e');
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

  /// Load saved tank height from SharedPreferences (if present)
  Future<void> _loadSavedTankHeight() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('tankHeight')) {
        final double? saved = prefs.getDouble('tankHeight');
        if (saved != null) {
          setState(() {
            tankHeight = saved;
            _heightController.text = saved.toStringAsFixed(1);
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to load saved tank height: $e');
    }
  }

  /// Save tank height locally (used when MCU confirms)
  Future<void> _saveTankHeightLocally(double h) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('tankHeight', h);
      debugPrint('Saved tankHeight=$h to preferences');
    } catch (e) {
      debugPrint('Failed to save tank height: $e');
    }
  }

  /// Show dialog to enter tank height (cm) and send it over Bluetooth
  void _showSetHeightDialog() {
    // Pre-fill with current value if available
    _heightController.text = tankHeight != null
        ? tankHeight!.toStringAsFixed(1)
        : '';

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Set Tank Height (cm)'),
          content: TextField(
            controller: _heightController,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: false,
            ),
            decoration: const InputDecoration(
              hintText: 'Enter height in cm (e.g. 10.0)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              // --- FIX 1: Make onPressed async ---
              onPressed: () async {
                final raw = _heightController.text.trim();
                final parsed = double.tryParse(raw);
                if (parsed == null || parsed <= 0 || parsed >= 500) {
                  _showSnackBar(
                    'Please enter a valid height (0 < cm < 500)',
                    Colors.red,
                  );
                  return;
                }

                // --- FIX 2: Update UI and Save Locally Immediately ---
                // This provides instant feedback to the user.
                setState(() {
                  tankHeight = parsed;
                  // Keep the controller in sync
                  _heightController.text = parsed.toStringAsFixed(1);
                });
                await _saveTankHeightLocally(parsed); // Save it
                // --- END OF FIX 2 ---

                // Send integer centimeters as ASCII digits terminated with newline to MCU.
                // MCU RX ISR accepts digits only (no decimal point), so send an integer
                // to avoid accidental scaling (e.g., "10.0" -> "100" on the MCU).
                try {
                  final String payload = '${parsed.round().toString()}\n';
                  widget.connection.output.add(
                    Uint8List.fromList(utf8.encode(payload)),
                  );
                  _showSnackBar(
                    'Sent & set tank height: ${parsed.toStringAsFixed(1)} cm',
                    Colors.green,
                  );
                } catch (e) {
                  debugPrint('Failed to send tank height: $e');
                  _showSnackBar('Failed to send height: $e', Colors.red);
                }

                // --- FIX 4: Add 'if (mounted)' check for safety ---
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Send'),
            ),
          ],
        );
      },
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
    // Prefer percentage-driven descriptions when available
    if (percentage <= 0.0) return 'No reading';
    if (percentage >= 50.0) return 'Near overflow!';
    if (percentage > 5.0) return 'Half full';
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
                  const SizedBox(height: 8),
                  // Button to set tank height via Bluetooth
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => _showSetHeightDialog(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Set Tank Height'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Always show current tank height (or a 'Not set' placeholder)
                      Text(
                        tankHeight != null
                            ? 'Current: ${tankHeight!.toStringAsFixed(1)} cm'
                            : 'Current: Not set',
                        style: const TextStyle(
                          fontSize: 12,
                          color: _secondaryText,
                        ),
                      ),
                    ],
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

    // Determine colors for the level tile (use percentage when available)
    final bool isLevelValid = percentage > 0.0;
    final Color distanceColor = isLevelValid ? _primaryBlue : _secondaryText;

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
        // Water Level Tile (shows percentage)
        _buildSensorTile(
          icon: Icons.height_rounded,
          iconColor: distanceColor,
          title: 'Water Level',
          value: isLevelValid ? '${percentage.toStringAsFixed(1)} %' : 'N/A',
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

