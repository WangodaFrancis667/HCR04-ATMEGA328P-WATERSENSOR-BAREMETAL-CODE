/// Model class representing a sensor reading with tank configuration
class SensorReading {
  final int? id;
  final DateTime timestamp;
  final int distance;
  final int waterQuality;
  final String status;
  final bool alert;
  final int arduinoUptime;
  final String deviceName;
  final String deviceAddress;
  
  // New fields for dynamic tank configuration
  final double? tankHeight;      // Tank height in cm
  final double? waterLevel;      // Actual water level in cm
  final double? percentage;      // Water level as percentage (0-100%)

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
    this.tankHeight,
    this.waterLevel,
    this.percentage,
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
      tankHeight: map['tankHeight'] as double?,
      waterLevel: map['waterLevel'] as double?,
      percentage: map['percentage'] as double?,
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
      'tankHeight': tankHeight,
      'waterLevel': waterLevel,
      'percentage': percentage,
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
      if (tankHeight != null) 'Tank Height (cm)': tankHeight!.toStringAsFixed(1),
      if (waterLevel != null) 'Water Level (cm)': waterLevel!.toStringAsFixed(1),
      if (percentage != null) 'Fill Percentage': '${percentage!.toStringAsFixed(1)}%',
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
    String base = 'Distance: ${distance}cm, Water: $waterQuality, Status: $status';
    if (percentage != null) {
      base += ', Fill: ${percentage!.toStringAsFixed(1)}%';
    }
    return base;
  }

  @override
  String toString() {
    return 'SensorReading{id: $id, timestamp: $timestamp, distance: ${distance}cm, '
        'waterQuality: $waterQuality, status: $status, alert: $alert, '
        'tankHeight: $tankHeight, waterLevel: $waterLevel, percentage: $percentage}';
  }
}