import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:math' show max, min;

// Admin Dashboard - Main Entry Point for Dispatch Operators
// This is a Flutter Web application for managing rides, drivers, and analytics

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AdminDashboardApp());
}

class AdminDashboardApp extends StatelessWidget {
  const AdminDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cruise Dispatch Admin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A2463),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A2463),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AdminLoginScreen(),
    );
  }
}

// Login Screen for Admin
class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A2463), Color(0xFF1E3A8F)],
          ),
        ),
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_taxi, size: 64, color: Color(0xFF0A2463)),
                  const SizedBox(height: 16),
                  const Text(
                    'Cruise Dispatch',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Admin Dashboard',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _emailCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0A2463),
                        foregroundColor: Colors.white,
                      ),
                      child: _loading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('LOGIN', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _login() async {
    setState(() => _loading = true);
    // TODO: Implement actual auth
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AdminHomeScreen()),
      );
    }
  }
}

// Main Admin Dashboard Screen
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    const LiveMapScreen(),
    const TripsManagementScreen(),
    const DriversScreen(),
    const AnalyticsScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cruise Dispatch Admin'),
        backgroundColor: const Color(0xFF0A2463),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications),
            onPressed: () {},
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Chip(
              label: const Text('Online'),
              backgroundColor: Colors.green.withValues(alpha: 0.2),
              side: const BorderSide(color: Colors.green),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() => _selectedIndex = index);
            },
            labelType: NavigationRailLabelType.selected,
            backgroundColor: Colors.grey[100],
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.map),
                selectedIcon: Icon(Icons.map_outlined),
                label: Text('Live Map'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.local_taxi),
                selectedIcon: Icon(Icons.local_taxi_outlined),
                label: Text('Trips'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.people),
                selectedIcon: Icon(Icons.people_outline),
                label: Text('Drivers'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.analytics),
                selectedIcon: Icon(Icons.analytics_outlined),
                label: Text('Analytics'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings),
                selectedIcon: Icon(Icons.settings_outlined),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(child: _screens[_selectedIndex]),
        ],
      ),
    );
  }
}

// Live Map Screen - Shows all drivers and trips in real-time
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  mapbox.MapboxMap? _mapController;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  List<mapbox.PointAnnotation> _markerAnnots = [];
  bool _showHeatmap = false;
  bool _showDrivers = true;
  bool _showTrips = true;
  StreamSubscription<QuerySnapshot>? _tripsSubscription;
  StreamSubscription<QuerySnapshot>? _driversSubscription;

  static const _initialLat = 33.5186;
  static const _initialLng = -86.8104;

  @override
  void initState() {
    super.initState();
    _subscribeToFirestore();
  }

  @override
  void dispose() {
    _tripsSubscription?.cancel();
    _driversSubscription?.cancel();
    super.dispose();
  }

  void _subscribeToFirestore() {
    // Subscribe to trips with status requested, accepted, in_progress
    _tripsSubscription = FirebaseFirestore.instance
        .collection('trips')
        .where('status', whereIn: ['requested', 'accepted', 'in_progress'])
        .snapshots()
        .listen(_onTripsUpdate);

    // Subscribe to online drivers (we need a drivers collection for this)
    _driversSubscription = FirebaseFirestore.instance
        .collection('drivers')
        .where('isOnline', isEqualTo: true)
        .snapshots()
        .listen(_onDriversUpdate);
  }

  void _onTripsUpdate(QuerySnapshot snapshot) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null || !_showTrips) return;

    // Clear existing trip markers
    await _clearTripMarkers();

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final lat = (data['pickupLat'] as num?)?.toDouble();
      final lng = (data['pickupLng'] as num?)?.toDouble();
      final status = data['status'] as String? ?? 'requested';

      if (lat == null || lng == null) continue;

      // Color based on status
      final color = status == 'requested'
          ? Colors.orange
          : status == 'accepted'
              ? Colors.blue
              : Colors.green;

      final marker = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
        iconColor: color.toARGB32(),
        iconSize: 1.2,
        textField: '#${doc.id.substring(0, 6)}',
        textSize: 12,
        textColor: Colors.black.toARGB32(),
      ));
      _markerAnnots.add(marker);
    }
  }

  void _onDriversUpdate(QuerySnapshot snapshot) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null || !_showDrivers) return;

    // Clear existing driver markers
    await _clearDriverMarkers();

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final lat = (data['currentLat'] as num?)?.toDouble();
      final lng = (data['currentLng'] as num?)?.toDouble();
      final isOnline = data['isOnline'] as bool? ?? false;

      if (lat == null || lng == null || !isOnline) continue;

      final marker = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
        iconColor: const Color(0xFF4285F4).toARGB32(),
        iconSize: 1.2,
        textField: data['name']?.toString() ?? 'Driver',
        textSize: 12,
        textColor: Colors.black.toARGB32(),
      ));
      _markerAnnots.add(marker);
    }
  }

  Future<void> _clearTripMarkers() async {
    // In a real implementation, track trip markers separately
    // For now, clear all and reload
  }

  Future<void> _clearDriverMarkers() async {
    // In a real implementation, track driver markers separately
    // For now, clear all and reload
  }

  Future<void> _loadMarkers() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    for (final a in _markerAnnots) { try { await mgr.delete(a); } catch (_) {} }
    _markerAnnots = [];
    // Markers now loaded via Firestore subscriptions
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top stats bar
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Row(
            children: [
              _buildStatCard('Active Drivers', '24', Colors.blue),
              const SizedBox(width: 16),
              _buildStatCard('Active Trips', '18', Colors.orange),
              const SizedBox(width: 16),
              _buildStatCard('Pending', '7', Colors.red),
              const SizedBox(width: 16),
              _buildStatCard('Completed Today', '156', Colors.green),
            ],
          ),
        ),
        // Map controls
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.grey[100],
          child: Row(
            children: [
              FilterChip(
                label: const Text('Drivers'),
                selected: _showDrivers,
                onSelected: (v) => setState(() => _showDrivers = v),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Trips'),
                selected: _showTrips,
                onSelected: (v) => setState(() => _showTrips = v),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Heat Map'),
                selected: _showHeatmap,
                onSelected: (v) => setState(() => _showHeatmap = v),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () {
                  // TODO: Refresh data
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        // Map
        Expanded(
          child: mapbox.MapWidget(
            styleUri: MapboxConfig.styleLight,
            cameraOptions: mapbox.CameraOptions(
              center: mapbox.Point(coordinates: mapbox.Position(_initialLng, _initialLat)),
              zoom: 12.0,
            ),
            onMapCreated: (ctrl) async {
              _mapController = ctrl;
              _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
              if (_showDrivers || _showTrips) _loadMarkers();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('trips').snapshots(),
            builder: (context, snapshot) {
              String displayValue = value;
              if (snapshot.hasData) {
                final docs = snapshot.data!.docs;
                switch (title) {
                  case 'Active Drivers':
                    displayValue = docs.where((d) => 
                      (d.data() as Map<String, dynamic>)['status'] == 'accepted').length.toString();
                    break;
                  case 'Active Trips':
                    displayValue = docs.where((d) {
                      final status = (d.data() as Map<String, dynamic>)['status'];
                      return status == 'requested' || status == 'accepted' || status == 'in_progress';
                    }).length.toString();
                    break;
                  case 'Pending':
                    displayValue = docs.where((d) => 
                      (d.data() as Map<String, dynamic>)['status'] == 'requested').length.toString();
                    break;
                  case 'Completed Today':
                    displayValue = docs.where((d) {
                      final data = d.data() as Map<String, dynamic>;
                      final status = data['status'];
                      final completedAt = data['completedAt'] as Timestamp?;
                      if (status != 'completed' || completedAt == null) return false;
                      final now = DateTime.now();
                      final completed = completedAt.toDate();
                      return completed.year == now.year && 
                             completed.month == now.month && 
                             completed.day == now.day;
                    }).length.toString();
                    break;
                }
              }
              return Column(
                children: [
                  Text(
                    displayValue,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  Text(
                    title,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// Trips Management Screen
class TripsManagementScreen extends StatelessWidget {
  const TripsManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Pending', icon: Icon(Icons.pending)),
              Tab(text: 'Active', icon: Icon(Icons.local_taxi)),
              Tab(text: 'Scheduled', icon: Icon(Icons.schedule)),
              Tab(text: 'History', icon: Icon(Icons.history)),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _TripsList(status: 'pending'),
                _TripsList(status: 'active'),
                _TripsList(status: 'scheduled'),
                _TripsList(status: 'completed'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TripsList extends StatelessWidget {
  final String status;
  const _TripsList({required this.status});

  Query<Map<String, dynamic>> _getQuery() {
    switch (status) {
      case 'pending':
        return FirebaseFirestore.instance
            .collection('trips')
            .where('status', isEqualTo: 'requested')
            .orderBy('createdAt', descending: true);
      case 'active':
        return FirebaseFirestore.instance
            .collection('trips')
            .where('status', whereIn: ['accepted', 'in_progress'])
            .orderBy('createdAt', descending: true);
      case 'scheduled':
        return FirebaseFirestore.instance
            .collection('trips')
            .where('status', isEqualTo: 'scheduled')
            .orderBy('scheduledAt', descending: true);
      case 'completed':
        return FirebaseFirestore.instance
            .collection('trips')
            .where('status', isEqualTo: 'completed')
            .orderBy('completedAt', descending: true)
            .limit(50);
      default:
        return FirebaseFirestore.instance
            .collection('trips')
            .orderBy('createdAt', descending: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _getQuery().snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                const SizedBox(height: 16),
                Text('Error loading trips: ${snapshot.error}'),
              ],
            ),
          );
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_taxi_outlined, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  'No $status trips',
                  style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final trip = docs[index].data();
            final tripId = docs[index].id;
            final tripStatus = trip['status'] as String? ?? 'unknown';
            final pickup = trip['pickupAddress']?.toString() ?? 'Unknown pickup';
            final dropoff = trip['dropoffAddress']?.toString() ?? 'Unknown dropoff';
            final riderName = trip['passengerName']?.toString() ?? 'Unknown rider';
            final fare = (trip['fare'] as num?)?.toDouble() ?? 0.0;
            final driverName = trip['driverName']?.toString();

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: _getStatusColor(tripStatus),
                  child: const Icon(Icons.local_taxi, color: Colors.white),
                ),
                title: Text('Trip #${tripId.substring(0, 8).toUpperCase()}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pickup: $pickup'),
                    Text('Dropoff: $dropoff'),
                    Text('Rider: $riderName • \$${fare.toStringAsFixed(2)}'),
                    if (driverName != null)
                      Text('Driver: $driverName', style: TextStyle(color: Colors.blue[700])),
                  ],
                ),
                isThreeLine: driverName != null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tripStatus == 'requested')
                      IconButton(
                        icon: const Icon(Icons.person_add, color: Colors.blue),
                        onPressed: () => _showAssignDriverDialog(context, tripId),
                        tooltip: 'Assign Driver',
                      ),
                    IconButton(
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => _showTripOptions(context, tripId, trip),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAssignDriverDialog(BuildContext context, String tripId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assign Driver'),
        content: const Text('Select a driver to assign to this trip'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              // TODO: Implement driver assignment
              Navigator.pop(context);
            },
            child: const Text('Assign'),
          ),
        ],
      ),
    );
  }

  void _showTripOptions(BuildContext context, String tripId, Map<String, dynamic> trip) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('View Details'),
              onTap: () {
                Navigator.pop(context);
                // TODO: Navigate to trip details
              },
            ),
            if (trip['status'] == 'requested')
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.red),
                title: const Text('Cancel Trip'),
                onTap: () {
                  Navigator.pop(context);
                  _cancelTrip(context, tripId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelTrip(BuildContext context, String tripId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirebaseFirestore.instance.collection('trips').doc(tripId).update({
        'status': 'cancelled',
        'cancelReason': 'Cancelled by dispatch',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Trip cancelled successfully')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to cancel trip: $e')),
      );
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'requested':
        return Colors.orange;
      case 'accepted':
        return Colors.blue;
      case 'in_progress':
        return Colors.green;
      case 'scheduled':
        return Colors.purple;
      case 'completed':
        return Colors.grey;
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

// Drivers Management Screen
class DriversScreen extends StatelessWidget {
  const DriversScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search drivers...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: () {
                  // TODO: Add driver dialog
                },
                icon: const Icon(Icons.add),
                label: const Text('Add Driver'),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('drivers')
                .orderBy('lastName')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                      const SizedBox(height: 16),
                      Text('Error loading drivers: ${snapshot.error}'),
                    ],
                  ),
                );
              }
              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.people_outline, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'No drivers registered',
                        style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final driver = docs[index].data();
                  final driverId = docs[index].id;
                  final firstName = driver['firstName']?.toString() ?? 'Unknown';
                  final lastName = driver['lastName']?.toString() ?? '';
                  final isOnline = driver['isOnline'] as bool? ?? false;
                  final rating = (driver['rating'] as num?)?.toDouble() ?? 0.0;
                  final vehicle = driver['vehicle']?.toString() ?? 'No vehicle';
                  final phone = driver['phone']?.toString();

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: Stack(
                        children: [
                          CircleAvatar(
                            backgroundColor: isOnline ? Colors.green[100] : Colors.grey[200],
                            child: Icon(Icons.person, color: isOnline ? Colors.green : Colors.grey),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: isOnline ? Colors.green : Colors.grey,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                      title: Text('$firstName $lastName'),
                      subtitle: Text(
                        isOnline
                            ? '🟢 Online • $vehicle • ${rating.toStringAsFixed(2)}★'
                            : '⚫ Offline • $vehicle • ${rating.toStringAsFixed(2)}★',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (phone != null)
                            IconButton(
                              icon: const Icon(Icons.phone),
                              onPressed: () => _callDriver(phone),
                              tooltip: 'Call',
                            ),
                          IconButton(
                            icon: const Icon(Icons.message),
                            onPressed: () => _messageDriver(context, driverId),
                            tooltip: 'Message',
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => _showDriverOptions(context, driverId, driver),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _callDriver(String phone) {
    // TODO: Implement phone call
  }

  void _messageDriver(BuildContext context, String driverId) {
    // TODO: Implement messaging
  }

  void _showDriverOptions(BuildContext context, String driverId, Map<String, dynamic> driver) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('View Profile'),
              onTap: () {
                Navigator.pop(context);
                // TODO: Navigate to driver profile
              },
            ),
            ListTile(
              leading: const Icon(Icons.assignment),
              title: const Text('View Trips'),
              onTap: () {
                Navigator.pop(context);
                // TODO: Show driver trips
              },
            ),
            if (driver['isOnline'] == true)
              ListTile(
                leading: const Icon(Icons.block, color: Colors.orange),
                title: const Text('Go Offline'),
                onTap: () {
                  Navigator.pop(context);
                  _setDriverOnlineStatus(context, driverId, false);
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setDriverOnlineStatus(BuildContext context, String driverId, bool online) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirebaseFirestore.instance.collection('drivers').doc(driverId).update({
        'isOnline': online,
        'lastStatusChange': FieldValue.serverTimestamp(),
      });
      messenger.showSnackBar(
        SnackBar(content: Text('Driver set ${online ? 'online' : 'offline'}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to update status: $e')),
      );
    }
  }
}

// Analytics Screen
class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Analytics Dashboard',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              _buildAnalyticsCard(
                'Total Trips Today',
                '174',
                '+12% vs yesterday',
                Colors.blue,
              ),
              const SizedBox(width: 16),
              _buildAnalyticsCard(
                'Revenue',
                '\$4,256.80',
                '+8% vs yesterday',
                Colors.green,
              ),
              const SizedBox(width: 16),
              _buildAnalyticsCard(
                'Avg. Trip Time',
                '18 min',
                '-2 min vs yesterday',
                Colors.orange,
              ),
              const SizedBox(width: 16),
              _buildAnalyticsCard(
                'Driver Utilization',
                '78%',
                '+5% vs yesterday',
                Colors.purple,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hourly Trip Volume',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 200),
                  Center(
                    child: Text('📊 Chart Placeholder - Implement with fl_chart'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Top Pickup Zones',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        _buildZoneRow('Downtown Birmingham', '45 trips'),
                        _buildZoneRow('UAB Campus', '38 trips'),
                        _buildZoneRow('Airport', '29 trips'),
                        _buildZoneRow('Five Points', '22 trips'),
                        _buildZoneRow('Hoover', '18 trips'),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Driver Performance',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        _buildZoneRow('John Smith', '24 trips • 4.95★'),
                        _buildZoneRow('Sarah Johnson', '21 trips • 4.92★'),
                        _buildZoneRow('Mike Davis', '19 trips • 4.88★'),
                        _buildZoneRow('Lisa Wilson', '18 trips • 4.90★'),
                        _buildZoneRow('Tom Brown', '16 trips • 4.85★'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsCard(String title, String value, String subtitle, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildZoneRow(String zone, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(zone),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// Settings Screen
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        _buildSettingsSection('General', [
          _buildSettingTile('Company Name', 'Cruise Rides', Icons.business),
          _buildSettingTile('Service Area', 'Birmingham, AL', Icons.location_on),
          _buildSettingTile('Time Zone', 'Central Time (CT)', Icons.access_time),
        ]),
        _buildSettingsSection('Pricing', [
          _buildSettingTile('Base Fare', '\$3.50', Icons.attach_money),
          _buildSettingTile('Per Mile Rate', '\$1.85', Icons.linear_scale),
          _buildSettingTile('Per Minute Rate', '\$0.25', Icons.timer),
          _buildSettingTile('Minimum Fare', '\$8.00', Icons.money_off),
        ]),
        _buildSettingsSection('Dispatch', [
          _buildSettingTile('Auto-Dispatch Radius', '5 miles', Icons.radar),
          _buildSettingTile('Max Wait Time', '10 minutes', Icons.timelapse),
          _buildSwitchTile('Enable Auto-Dispatch', true),
          _buildSwitchTile('Enable Surge Pricing', true),
        ]),
        _buildSettingsSection('Notifications', [
          _buildSwitchTile('Push Notifications', true),
          _buildSwitchTile('Email Alerts', true),
          _buildSwitchTile('SMS Alerts', false),
        ]),
        _buildSettingsSection('Account', [
          _buildSettingTile('Change Password', '', Icons.lock),
          _buildSettingTile('Two-Factor Auth', 'Enabled', Icons.security),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Logout', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const AdminLoginScreen()),
              );
            },
          ),
        ]),
      ],
    );
  }

  Widget _buildSettingsSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0A2463),
            ),
          ),
        ),
        Card(
          child: Column(children: children),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSettingTile(String title, String subtitle, IconData icon) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: () {},
    );
  }

  Widget _buildSwitchTile(String title, bool value) {
    return SwitchListTile(
      title: Text(title),
      value: value,
      onChanged: (v) {},
    );
  }
}
