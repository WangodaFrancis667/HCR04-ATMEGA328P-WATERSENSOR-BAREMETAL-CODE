import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/sensor_reading.dart';

/// Database helper class for managing SQLite operations
class DatabaseHelper {
  // Singleton pattern
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  /// Get the database instance
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('water_tank_logs.db');
    return _database!;
  }

  /// Initialize the database
  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  /// Create database tables
  Future<void> _createDB(Database db, int version) async {
    const idType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const textType = 'TEXT NOT NULL';
    const intType = 'INTEGER NOT NULL';

    await db.execute('''
      CREATE TABLE sensor_readings (
        id $idType,
        timestamp $textType,
        distance $intType,
        waterQuality $intType,
        status $textType,
        alert $intType,
        arduinoUptime $intType,
        deviceName $textType,
        deviceAddress $textType
      )
    ''');

    // Create index on timestamp for faster queries
    await db.execute('''
      CREATE INDEX idx_timestamp ON sensor_readings(timestamp DESC)
    ''');

    print('Database created successfully with sensor_readings table');
  }

  /// Insert a sensor reading into the database
  Future<int> insertReading(SensorReading reading) async {
    final db = await instance.database;
    final id = await db.insert('sensor_readings', reading.toMap());
    print('Inserted reading with ID: $id');
    return id;
  }

  /// Get all sensor readings (newest first)
  Future<List<SensorReading>> getAllReadings() async {
    final db = await instance.database;
    const orderBy = 'timestamp DESC';
    final result = await db.query('sensor_readings', orderBy: orderBy);
    
    return result.map((map) => SensorReading.fromMap(map)).toList();
  }

  /// Get readings with pagination
  Future<List<SensorReading>> getReadingsPaginated({
    required int limit,
    required int offset,
  }) async {
    final db = await instance.database;
    final result = await db.query(
      'sensor_readings',
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    
    return result.map((map) => SensorReading.fromMap(map)).toList();
  }

  /// Get readings within a date range
  Future<List<SensorReading>> getReadingsByDateRange({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final db = await instance.database;
    final result = await db.query(
      'sensor_readings',
      where: 'timestamp BETWEEN ? AND ?',
      whereArgs: [
        startDate.toIso8601String(),
        endDate.toIso8601String(),
      ],
      orderBy: 'timestamp DESC',
    );
    
    return result.map((map) => SensorReading.fromMap(map)).toList();
  }

  /// Get readings by status
  Future<List<SensorReading>> getReadingsByStatus(String status) async {
    final db = await instance.database;
    final result = await db.query(
      'sensor_readings',
      where: 'status = ?',
      whereArgs: [status],
      orderBy: 'timestamp DESC',
    );
    
    return result.map((map) => SensorReading.fromMap(map)).toList();
  }

  /// Get readings with alerts only
  Future<List<SensorReading>> getAlertReadings() async {
    final db = await instance.database;
    final result = await db.query(
      'sensor_readings',
      where: 'alert = ?',
      whereArgs: [1],
      orderBy: 'timestamp DESC',
    );
    
    return result.map((map) => SensorReading.fromMap(map)).toList();
  }

  /// Get total count of readings
  Future<int> getTotalCount() async {
    final db = await instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM sensor_readings');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get count by status
  Future<Map<String, int>> getCountByStatus() async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT status, COUNT(*) as count 
      FROM sensor_readings 
      GROUP BY status
    ''');
    
    Map<String, int> counts = {};
    for (var row in result) {
      counts[row['status'] as String] = row['count'] as int;
    }
    return counts;
  }

  /// Get latest reading
  Future<SensorReading?> getLatestReading() async {
    final db = await instance.database;
    final result = await db.query(
      'sensor_readings',
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    
    if (result.isNotEmpty) {
      return SensorReading.fromMap(result.first);
    }
    return null;
  }

  /// Delete a reading by ID
  Future<int> deleteReading(int id) async {
    final db = await instance.database;
    return await db.delete(
      'sensor_readings',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete all readings
  Future<int> deleteAllReadings() async {
    final db = await instance.database;
    return await db.delete('sensor_readings');
  }

  /// Delete readings older than specified days
  Future<int> deleteOldReadings(int days) async {
    final db = await instance.database;
    final cutoffDate = DateTime.now().subtract(Duration(days: days));
    
    return await db.delete(
      'sensor_readings',
      where: 'timestamp < ?',
      whereArgs: [cutoffDate.toIso8601String()],
    );
  }

  /// Get database statistics
  Future<Map<String, dynamic>> getStatistics() async {
    final db = await instance.database;
    
    // Total count
    final totalResult = await db.rawQuery(
      'SELECT COUNT(*) as total FROM sensor_readings'
    );
    final total = Sqflite.firstIntValue(totalResult) ?? 0;
    
    // Average distance
    final avgDistanceResult = await db.rawQuery(
      'SELECT AVG(distance) as avg FROM sensor_readings'
    );
    final avgDistanceValue = avgDistanceResult.first['avg'] as num?;
    final avgDistance = avgDistanceValue?.toDouble();
    
    // Average water quality
    final avgWaterResult = await db.rawQuery(
      'SELECT AVG(waterQuality) as avg FROM sensor_readings'
    );
    final avgWaterValue = avgWaterResult.first['avg'] as num?;
    final avgWater = avgWaterValue?.toDouble();
    
    // Alert count
    final alertResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM sensor_readings WHERE alert = 1'
    );
    final alertCount = Sqflite.firstIntValue(alertResult) ?? 0;
    
    // Status breakdown
    final statusResult = await db.rawQuery('''
      SELECT status, COUNT(*) as count 
      FROM sensor_readings 
      GROUP BY status
    ''');
    
    Map<String, int> statusBreakdown = {};
    for (var row in statusResult) {
      statusBreakdown[row['status'] as String] = row['count'] as int;
    }
    
    return {
      'total': total,
      'averageDistance': avgDistance ?? 0.0,
      'averageWaterQuality': avgWater ?? 0.0,
      'alertCount': alertCount,
      'statusBreakdown': statusBreakdown,
    };
  }

  /// Export all data as JSON
  Future<List<Map<String, dynamic>>> exportToJson() async {
    final readings = await getAllReadings();
    return readings.map((r) => r.toMap()).toList();
  }

  /// Close the database
  Future<void> close() async {
    final db = await instance.database;
    await db.close();
  }
}