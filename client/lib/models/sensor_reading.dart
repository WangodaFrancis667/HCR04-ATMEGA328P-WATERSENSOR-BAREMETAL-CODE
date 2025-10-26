/// Model class representing a sensor reading stored in the database
class SensorReading {
  final int? id; // Auto-increment primary key
  final DateTime timestamp; // When the reading was received
  final int distance; // Distance in centimeters
  final int waterQuality; // Water sensor ADC value (0-1023)
  final String status; // EMPTY, HALF_FULL, OVERFLOW, CONTAMINATED
  final bool alert; // Alert flag
  final int arduinoUptime; // Arduino uptime in milliseconds
  final String deviceName; // Name of connected Bluetooth device
  final String deviceAddress; // MAC address of Bluetooth device

  SensorReading({
    this.id,
    required this.timestamp,
    required this.distance,
    required this.waterQuality,
    required this.status,
    required this.alert,
    required this.arduinoUptime,
    required this.deviceName,
    required this.deviceAddress,
  });

  /// Create SensorReading from database map
  factory SensorReading.fromMap(Map<String, dynamic> map) {
    return SensorReading(
      id: map['id'] as int?,
      timestamp: DateTime.parse(map['timestamp'] as String),
      distance: map['distance'] as int,
      waterQuality: map['waterQuality'] as int,
      status: map['status'] as String,
      alert: (map['alert'] as int) == 1,
      arduinoUptime: map['arduinoUptime'] as int,
      deviceName: map['deviceName'] as String,
      deviceAddress: map['deviceAddress'] as String,
    );
  }

  /// Convert SensorReading to database map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'distance': distance,
      'waterQuality': waterQuality,
      'status': status,
      'alert': alert ? 1 : 0,
      'arduinoUptime': arduinoUptime,
      'deviceName': deviceName,
      'deviceAddress': deviceAddress,
    };
  }

  /// Convert to JSON for display
  Map<String, dynamic> toJson() {
    return {
      'ID': id,
      'Timestamp': timestamp.toLocal().toString(),
      'Distance (cm)': distance,
      'Water Quality': waterQuality,
      'Status': status,
      'Alert': alert ? 'Yes' : 'No',
      'Arduino Uptime': _formatUptime(arduinoUptime),
      'Device Name': deviceName,
      'Device Address': deviceAddress,
    };
  }

  /// Format uptime from milliseconds to readable format
  String _formatUptime(int milliseconds) {
    int seconds = (milliseconds ~/ 1000) % 60;
    int minutes = (milliseconds ~/ 60000) % 60;
    int hours = milliseconds ~/ 3600000;
    return '${hours}h ${minutes}m ${seconds}s';
  }

  /// Get a summary string of this reading
  String getSummary() {
    return 'Distance: ${distance}cm, Water: $waterQuality, Status: $status';
  }

  @override
  String toString() {
    return 'SensorReading{id: $id, timestamp: $timestamp, distance: ${distance}cm, '
        'waterQuality: $waterQuality, status: $status, alert: $alert}';
  }
}