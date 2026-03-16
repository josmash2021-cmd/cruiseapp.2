import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
        cardTheme: CardTheme(
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
              backgroundColor: Colors.green.withOpacity(0.2),
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
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final Set<Heatmap> _heatmaps = {};
  bool _showHeatmap = false;
  bool _showDrivers = true;
  bool _showTrips = true;

  // Sample initial position (Birmingham, AL)
  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(33.5186, -86.8104),
    zoom: 12,
  );

  @override
  void initState() {
    super.initState();
    _loadMarkers();
  }

  void _loadMarkers() {
    // TODO: Load from Firestore
    setState(() {
      _markers.addAll([
        Marker(
          markerId: const MarkerId('driver_1'),
          position: const LatLng(33.5200, -86.8000),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: const InfoWindow(title: 'Driver: John D.', snippet: 'Available'),
        ),
        Marker(
          markerId: const MarkerId('driver_2'),
          position: const LatLng(33.5100, -86.8200),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: const InfoWindow(title: 'Driver: Sarah M.', snippet: 'On Trip'),
        ),
        Marker(
          markerId: const MarkerId('trip_1'),
          position: const LatLng(33.5300, -86.8100),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: const InfoWindow(title: 'Pickup: 123 Main St', snippet: 'Waiting for driver'),
        ),
      ]);
    });
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
          child: GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: _initialPosition,
            markers: _showDrivers || _showTrips ? _markers : {},
            onMapCreated: (controller) {
              _mapController = controller;
            },
            myLocationEnabled: false,
            zoomControlsEnabled: true,
            mapToolbarEnabled: true,
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
          child: Column(
            children: [
              Text(
                value,
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

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (context, index) {
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: _getStatusColor(status),
              child: const Icon(Icons.local_taxi, color: Colors.white),
            ),
            title: Text('Trip #${1000 + index}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pickup: 123 Main St, Birmingham'),
                Text('Dropoff: 456 Oak Ave, Birmingham'),
                Text('Rider: John Doe • \$24.50'),
              ],
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (status == 'pending')
                  IconButton(
                    icon: const Icon(Icons.person_add, color: Colors.blue),
                    onPressed: () {
                      // TODO: Assign driver manually
                    },
                    tooltip: 'Assign Driver',
                  ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'pending':
        return Colors.orange;
      case 'active':
        return Colors.green;
      case 'scheduled':
        return Colors.blue;
      case 'completed':
        return Colors.grey;
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
                onPressed: () {},
                icon: const Icon(Icons.add),
                label: const Text('Add Driver'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: 10,
            itemBuilder: (context, index) {
              final isOnline = index % 3 == 0;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Stack(
                    children: [
                      const CircleAvatar(
                        child: Icon(Icons.person),
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
                  title: Text('Driver ${index + 1}: John Smith'),
                  subtitle: Text(
                    isOnline ? '🟢 Online • Toyota Camry • 4.92★' : '⚫ Offline • Honda Accord • 4.85★',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.phone),
                        onPressed: () {},
                      ),
                      IconButton(
                        icon: const Icon(Icons.message),
                        onPressed: () {},
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
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
