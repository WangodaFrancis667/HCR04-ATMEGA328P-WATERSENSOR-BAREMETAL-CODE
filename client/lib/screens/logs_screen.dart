import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/database_helper.dart';
import '../models/sensor_reading.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  // ============================================================================
  //                        THEME COLORS (Classic Water Blue)
  // ============================================================================
  static const Color _primaryBlue = Color(0xFF0D47A1); // Used for Filling
  static const Color _primaryGreen = Color(0xFF388E3C); // Used for Past Halfway
  static const Color _primaryColor = Color(0xFF3D52A0);
  static const Color _accentColor = Color(0xFF7091E6);
  static const Color _secondaryColor = Color(0xFF8697C4);
  static const Color _lightGrayBlue = Color(0xFFADBBDA);
  static const Color _backgroundColor = Color(0xFFEDE8F5);

  // Semantic Colors
  static final Color _dangerColor = Colors.red[700]!;
  static final Color _warningColor = Colors.orange[700]!;
  static final Color _successColor = Colors.green[700]!;
  static final Color _neutralColor = Colors.grey[700]!;

  // Text Colors
  static const Color _primaryText = Color(0xFF212121);
  static const Color _secondaryText = Color(0xFF757575);

  // ============================================================================
  //                        STATE VARIABLES
  // ============================================================================
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  List<SensorReading> _readings = [];
  bool _isLoading = true;
  String _filterStatus = 'ALL';
  bool _showAlertsOnly = false;

  // Statistics
  Map<String, dynamic> _statistics = {};

  // Pagination
  static const int _itemsPerPage = 50;
  int _currentPage = 0;
  bool _hasMoreData = true;

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadStatistics();
  }

  // ============================================================================
  //                        DATA LOADING
  // ============================================================================

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      List<SensorReading> readings;

      if (_showAlertsOnly) {
        // Load only alert readings
        readings = await _dbHelper.getAlertReadings();
      } else if (_filterStatus != 'ALL') {
        // Load filtered by status
        readings = await _dbHelper.getReadingsByStatus(_filterStatus);
      } else {
        // Load all readings with pagination
        readings = await _dbHelper.getReadingsPaginated(
          limit: _itemsPerPage,
          offset: _currentPage * _itemsPerPage,
        );
      }

      setState(() {
        _readings = readings;
        _hasMoreData = readings.length == _itemsPerPage;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading data: $e');
      setState(() {
        _isLoading = false;
      });
      _showSnackBar('Error loading data: $e', Colors.red);
    }
  }

  Future<void> _loadStatistics() async {
    try {
      final stats = await _dbHelper.getStatistics();
      setState(() {
        _statistics = stats;
      });
    } catch (e) {
      debugPrint('Error loading statistics: $e');
    }
  }

  Future<void> _refreshData() async {
    _currentPage = 0;
    await _loadData();
    await _loadStatistics();
  }

  // ============================================================================
  //                        FILTER & ACTIONS
  // ============================================================================

  void _applyFilter(String status) {
    setState(() {
      _filterStatus = status;
      _currentPage = 0;
    });
    _loadData();
  }

  void _toggleAlertsFilter() {
    setState(() {
      _showAlertsOnly = !_showAlertsOnly;
      _currentPage = 0;
    });
    _loadData();
  }

  void _nextPage() {
    if (_hasMoreData && !_showAlertsOnly && _filterStatus == 'ALL') {
      setState(() {
        _currentPage++;
      });
      _loadData();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      setState(() {
        _currentPage--;
      });
      _loadData();
    }
  }

  Future<void> _deleteAllReadings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.0),
        ),
        title: const Text('Delete All Logs'),
        content: const Text(
          'Are you sure you want to delete ALL logged readings? '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: _secondaryText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete All', style: TextStyle(color: _dangerColor)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _dbHelper.deleteAllReadings();
        _showSnackBar('All logs deleted', Colors.orange);
        _refreshData();
      } catch (e) {
        _showSnackBar('Error deleting logs: $e', _dangerColor);
      }
    }
  }

  Future<void> _deleteOldReadings() async {
    final days = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.0),
        ),
        title: const Text('Delete Old Logs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Delete logs older than:'),
            const SizedBox(height: 10),
            ListTile(
              title: const Text('7 days'),
              onTap: () => Navigator.pop(context, 7),
            ),
            ListTile(
              title: const Text('30 days'),
              onTap: () => Navigator.pop(context, 30),
            ),
            ListTile(
              title: const Text('90 days'),
              onTap: () => Navigator.pop(context, 90),
            ),
          ],
        ),
      ),
    );

    if (days != null) {
      try {
        final deleted = await _dbHelper.deleteOldReadings(days);
        _showSnackBar('Deleted $deleted old logs', _warningColor);
        _refreshData();
      } catch (e) {
        _showSnackBar('Error deleting logs: $e', _dangerColor);
      }
    }
  }

  // ============================================================================
  //                        UI HELPERS (Modified)
  // ============================================================================
  
  // NOTE: These three methods now use the reading's percentage for rich display.

  String _getRichStatusText(double percentage, String mcuStatus) {
    if (mcuStatus == 'CONTAMINATED') {
      return 'Water Contamination!';
    }
    
    // Use percentage for descriptive text (Logic mirrors SensorDataScreen)
    if (percentage >= 80.0) {
      return 'Overflow Warning';
    } else if (percentage > 50.5) {
      return 'Past Halfway: Filling Well';
    } else if (percentage >= 49.5) {
      return 'Tank is Half Full';
    } else if (percentage > 5.0) {
      return 'Tank is Filling Up';
    } else {
      return 'Tank is Empty';
    }
  }

  Color _getRichStatusColor(double percentage, String mcuStatus) {
    if (mcuStatus == 'CONTAMINATED') {
      return _dangerColor;
    }
    
    // Use percentage for fine-grained color (Logic mirrors SensorDataScreen)
    if (percentage >= 80.0) {
      return _warningColor; // Overflow
    } else if (percentage > 50.5) {
      return _primaryGreen; // Past Halfway
    } else if (percentage >= 49.5) {
      return Colors.blue[600]!; // Half Full
    } else if (percentage > 5.0) {
      return _primaryBlue; // Filling
    } else {
      return _neutralColor; // Empty
    }
  }

  IconData _getRichStatusIcon(double percentage, String mcuStatus) {
    if (mcuStatus == 'CONTAMINATED') {
      return Icons.warning_amber_rounded;
    }

    // Use percentage for level-based icons (Logic mirrors SensorDataScreen)
    if (percentage >= 80.0) {
      return Icons.water_drop_rounded; // Overflow
    } else if (percentage > 50.5) {
      return Icons.arrow_circle_up_rounded; // Past Half Way
    } else if (percentage >= 49.5) {
      return Icons.waves_rounded; // Half Full
    } else if (percentage > 5.0) {
      return Icons.water_outlined; // Filling
    } else {
      return Icons.delete_outline_rounded; // Empty Tank
    }
  }

  // NOTE: This is the old simple color method, used only for the filter chips.
  // It only looks at the simple MCU status string.
  Color _getStatusColor(String status) {
    switch (status) {
      case 'CONTAMINATED':
        return _dangerColor;
      case 'OVERFLOW':
        return _warningColor;
      case 'HALF_FULL':
        return _accentColor; // Use theme accent color
      case 'EMPTY':
      default:
        return _neutralColor;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'CONTAMINATED':
        return Icons.warning_amber_rounded;
      case 'OVERFLOW':
        return Icons.water_drop_rounded;
      case 'HALF_FULL':
        return Icons.waves_rounded;
      case 'EMPTY':
      default:
        return Icons.check_circle_outline_rounded;
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return DateFormat('MMM dd, yyyy HH:mm:ss').format(dateTime);
  }

  // ============================================================================
  //                        UI BUILD METHOD
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: const Text('Logged Data', textAlign: TextAlign.center),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 2.0,
        actions: [
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshData,
            tooltip: 'Refresh',
          ),
          // More options menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'delete_all') {
                _deleteAllReadings();
              } else if (value == 'delete_old') {
                _deleteOldReadings();
              } else if (value == 'statistics') {
                _showStatisticsDialog();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'statistics',
                child: Row(
                  children: [
                    Icon(Icons.analytics_outlined, color: _primaryColor),
                    const SizedBox(width: 10),
                    const Text('View Statistics'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete_old',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep_outlined, color: _warningColor),
                    const SizedBox(width: 10),
                    const Text('Delete Old Logs'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete_all',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever_outlined, color: _dangerColor),
                    const SizedBox(width: 10),
                    const Text('Delete All Logs'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Bar
          _buildFilterBar(),

          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _readings.isEmpty
                ? _buildEmptyState()
                : _buildReadingsList(),
          ),

          // Pagination Controls
          if (!_isLoading &&
              _readings.isNotEmpty &&
              _filterStatus == 'ALL' &&
              !_showAlertsOnly)
            _buildPaginationControls(),
        ],
      ),
    );
  }

  // ============================================================================
  //                        REFACTORED UI WIDGETS
  // ============================================================================

  /// A clean, floating filter bar
  Widget _buildFilterBar() {
    return Material(
      color: Colors.white,
      elevation: 1.0,
      child: Container(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            // Status Filter
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _buildFilterChip('ALL', Icons.all_inclusive_rounded),
                  const SizedBox(width: 8),
                  _buildFilterChip('EMPTY', Icons.check_circle_outline_rounded),
                  const SizedBox(width: 8),
                  _buildFilterChip('HALF_FULL', Icons.waves_rounded),
                  const SizedBox(width: 8),
                  _buildFilterChip('OVERFLOW', Icons.water_drop_rounded),
                  const SizedBox(width: 8),
                  _buildFilterChip('CONTAMINATED', Icons.warning_amber_rounded),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Alerts Toggle
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Text(
                    'Total: ${_statistics['total'] ?? 0} readings',
                    style: const TextStyle(fontSize: 12, color: _secondaryText),
                  ),
                ),
                FilterChip(
                  label: const Text('Alerts Only'),
                  selected: _showAlertsOnly,
                  onSelected: (_) => _toggleAlertsFilter(),
                  selectedColor: _dangerColor.withOpacity(0.2),
                  backgroundColor: _backgroundColor,
                  showCheckmark: false,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20.0),
                    side: BorderSide(
                      color: _showAlertsOnly
                          ? _dangerColor.withOpacity(0.5)
                          : _lightGrayBlue,
                    ),
                  ),
                  avatar: Icon(
                    Icons.notification_important_rounded,
                    size: 18,
                    color: _showAlertsOnly ? _dangerColor : _neutralColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String status, IconData icon) {
    final isSelected = _filterStatus == status;
    // Use simple status color for filter chips to match MCU status strings
    final color = isSelected ? _getStatusColor(status) : _neutralColor; 

    return FilterChip(
      label: Text(status.replaceAll('_', ' ')),
      selected: isSelected,
      onSelected: (_) => _applyFilter(status),
      avatar: Icon(icon, size: 18, color: color),
      selectedColor: _getStatusColor(status).withOpacity(0.2),
      backgroundColor: _backgroundColor,
      showCheckmark: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20.0),
        side: BorderSide(
          color: isSelected
              ? _getStatusColor(status).withOpacity(0.5)
              : _lightGrayBlue,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox_outlined, size: 80, color: _secondaryColor),
          const SizedBox(height: 20),
          Text(
            'No Logs Found',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _secondaryColor,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _showAlertsOnly
                ? 'No alert readings recorded'
                : _filterStatus != 'ALL'
                ? 'No readings with status: $_filterStatus'
                : 'Start monitoring to log data',
            style: TextStyle(
              fontSize: 14,
              color: _secondaryColor.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadingsList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      itemCount: _readings.length,
      itemBuilder: (context, index) {
        final reading = _readings[index];
        return _buildReadingCard(reading);
      },
    );
  }

  Widget _buildReadingCard(SensorReading reading) {
    // Use the rich display logic for the card visuals
    final percent = reading.percentage ?? 0.0;
    final statusColor = _getRichStatusColor(percent, reading.status);
    final statusText = _getRichStatusText(percent, reading.status);
    final statusIcon = _getRichStatusIcon(percent, reading.status);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1.0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
        side: BorderSide(
          color: reading.alert ? _dangerColor : Colors.transparent,
          width: 1.0,
        ),
      ),
      child: ExpansionTile(
        shape: const Border(), // Remove default expansion borders
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(statusIcon, color: statusColor),
        ),
        title: Text(
          statusText, // Display the rich description
          style: TextStyle(fontWeight: FontWeight.bold, color: statusColor),
        ),
        subtitle: Text(
          _formatDateTime(reading.timestamp),
          style: const TextStyle(fontSize: 12, color: _secondaryText),
        ),
        trailing: reading.alert
            ? Icon(Icons.notification_important_rounded, color: _dangerColor)
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 16.0),
        children: [
          const Divider(),
          const SizedBox(height: 8),
          _buildDetailRow(
            Icons.percent_rounded, // New icon for percentage
            'Petrol Level',
            '${reading.percentage?.toStringAsFixed(1) ?? 'N/A'} %',
            _getRichStatusColor(reading.percentage ?? 0.0, reading.status),
          ),
          const SizedBox(height: 8),
          _buildDetailRow(
            Icons.height_rounded,
            'Distance (Top)',
            '${reading.distance} cm',
            _secondaryColor, // Keep distance detail color neutral
          ),
          const SizedBox(height: 8),
          _buildDetailRow(
            Icons.opacity_rounded,
            'Water Contamination percentage',
            '${(reading.waterQuality.toDouble() / 1023.0 * 100).toStringAsFixed(1)}%',
            reading.waterQuality > 100 ? _dangerColor : _successColor,
          ),
          const SizedBox(height: 8),
          _buildDetailRow(
            Icons.timer_outlined,
            'Arduino Uptime',
            reading.toJson()['Arduino Uptime'], 
            _secondaryColor,
          ),
          const SizedBox(height: 8),
          _buildDetailRow(
            Icons.bluetooth_rounded,
            'Device',
            reading.deviceName,
            _primaryColor,
          ),
          const SizedBox(height: 8),
          _buildDetailRow(
            Icons.fingerprint_rounded,
            'MAC Address',
            reading.deviceAddress,
            _secondaryText,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color.withOpacity(0.8)),
        const SizedBox(width: 12),
        Text(
          '$label: ',
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            color: _secondaryText,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  Widget _buildPaginationControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: _backgroundColor,
        border: Border(top: BorderSide(color: _lightGrayBlue.withOpacity(0.5))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            onPressed: _currentPage > 0 ? _previousPage : null,
            icon: const Icon(Icons.chevron_left_rounded),
            label: const Text('Previous'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _primaryColor,
              side: BorderSide(color: _lightGrayBlue),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
            ),
          ),
          Text(
            'Page ${_currentPage + 1}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: _secondaryColor,
            ),
          ),
          OutlinedButton.icon(
            onPressed: _hasMoreData ? _nextPage : null,
            icon: const Icon(Icons.chevron_right_rounded),
            label: const Text('Next'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _primaryColor,
              side: BorderSide(color: _lightGrayBlue),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showStatisticsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.0),
        ),
        title: Row(
          children: [
            Icon(Icons.analytics_rounded, color: _primaryColor),
            const SizedBox(width: 10),
            const Text('Database Statistics'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStatRow(
                'Total Readings',
                '${_statistics['total'] ?? 0}',
                Icons.storage_rounded,
              ),
              const Divider(),
              _buildStatRow(
                'Average Distance',
                '${(_statistics['averageDistance'] ?? 0).toStringAsFixed(1)} cm',
                Icons.height_rounded,
              ),
              const Divider(),
              _buildStatRow(
                'Average Petrol Quality',
                '${(_statistics['averageWaterQuality'] ?? 0).toStringAsFixed(1)}',
                Icons.opacity_rounded,
              ),
              const Divider(),
              _buildStatRow(
                'Average Percentage',
                '${(_statistics['averagePercentage'] ?? 0).toStringAsFixed(1)} %',
                Icons.percent_rounded,
              ),
              const Divider(),
              _buildStatRow(
                'Alert Count',
                '${_statistics['alertCount'] ?? 0}',
                Icons.notification_important_rounded,
                isAlert: true,
              ),
              const Divider(),
              const SizedBox(height: 10),
              Text(
                'Status Breakdown:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _primaryColor,
                ),
              ),
              const SizedBox(height: 10),
              ...(_buildStatusBreakdown()),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: _primaryColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(
    String label,
    String value,
    IconData icon, {
    bool isAlert = false,
  }) {
    final color = isAlert ? _dangerColor : _primaryColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color.withOpacity(0.8)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: _secondaryText,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildStatusBreakdown() {
    final breakdown = _statistics['statusBreakdown'] as Map<String, int>? ?? {};
    if (breakdown.isEmpty) {
      return [
        const Text(
          'No status data available.',
          style: TextStyle(color: _secondaryText),
        ),
      ];
    }
    return breakdown.entries.map((entry) {
      final color = _getStatusColor(entry.key); // Use simple status color here
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(_getStatusIcon(entry.key), size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.key.replaceAll('_', ' '),
                style: const TextStyle(color: _secondaryText),
              ),
            ),
            Text(
              '${entry.value}',
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      );
    }).toList();
  }

  void _showSnackBar(String message, Color backgroundColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}