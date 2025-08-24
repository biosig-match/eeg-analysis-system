import 'analysis_widgets.dart';
import 'eeg_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_provider.dart';
import 'analysis_provider.dart';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _waveformRefreshTimer;

  @override
  void initState() {
    super.initState();
    _waveformRefreshTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted) {
        context.read<BleProvider>().refreshWaveform();
      }
    });
  }

  @override
  void dispose() {
    _waveformRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissionsAndScan(BleProvider bleProvider, AnalysisProvider analysisProvider) async {
    Map<Permission, PermissionStatus> statuses = await [Permission.location, Permission.bluetoothScan, Permission.bluetoothConnect,].request();
    if (statuses[Permission.location]!.isGranted && statuses[Permission.bluetoothScan]!.isGranted && statuses[Permission.bluetoothConnect]!.isGranted) {
      bleProvider.startScan();
      analysisProvider.startPolling();
    } else {
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bluetoothと位置情報の権限を許可してください')),); }
    }
  }

  void _disconnect(BleProvider bleProvider, AnalysisProvider analysisProvider) {
      bleProvider.disconnect();
      analysisProvider.stopPolling();
  }

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final analysisProvider = context.watch<AnalysisProvider>();
    final channelCount = bleProvider.channelCount;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF161C27),
          title: const Text(
            'EEG Visualizer & Analyzer', 
            style: TextStyle(color: Colors.white)
          ),
          bottom: const TabBar(
            labelColor: Colors.cyanAccent,
            unselectedLabelColor: Colors.white54,
            indicatorColor: Colors.cyanAccent,
            tabs: [
              Tab(icon: Icon(Icons.show_chart), text: "Frequency"),
              Tab(icon: Icon(Icons.hub), text: "Connectivity"),
              Tab(icon: Icon(Icons.sentiment_very_satisfied), text: "Valence"),
            ],
          ),
        ),
        backgroundColor: const Color(0xFF1F2633),
        body: Column(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: channelCount == 0
                  ? const Center(child: Text("Connect to a device", style: TextStyle(color: Colors.white70)))
                  : ListView.builder(
                      itemCount: channelCount,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                          child: Card(
                            color: Colors.black.withOpacity(0.4),
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                                  child: Text("CH${index + 1}", style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                                Expanded(child: EegSingleChannelChart(channelIndex: index)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  AnalysisImageViewer(imageProvider: () => analysisProvider.latestAnalysis?.psdImage),
                  AnalysisImageViewer(imageProvider: () => analysisProvider.latestAnalysis?.coherenceImage),
                  const ValenceMonitor(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 16.0),
              child: Column(
                children: [
                  _buildStatusCard(bleProvider, analysisProvider),
                  const SizedBox(height: 12),
                  _buildControlButton(bleProvider, analysisProvider),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ★★★★★ This is the updated widget ★★★★★
  Widget _buildControlButton(BleProvider bleProvider, AnalysisProvider analysisProvider) {
    bool isConnected = bleProvider.connectionState == BleConnectionState.connected;
    bool isScanning = bleProvider.connectionState == BleConnectionState.scanning || bleProvider.connectionState == BleConnectionState.connecting;

    return ElevatedButton.icon(
      icon: Icon(isConnected ? Icons.link_off : Icons.search),
      label: Text(isConnected ? 'Disconnect' : 'Find Device'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white, // Background color is now white
        foregroundColor: isConnected ? Colors.purple : Colors.blue, // Text/icon color changes
        minimumSize: const Size(220, 50), // Set a minimum width and height
        padding: const EdgeInsets.symmetric(vertical: 15),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 5, // Add a little shadow
      ),
      onPressed: isScanning ? null : () {
        if (isConnected) {
          _disconnect(bleProvider, analysisProvider);
        } else {
          _requestPermissionsAndScan(bleProvider, analysisProvider);
        }
      },
    );
  }

  Widget _buildStatusCard(BleProvider bleProvider, AnalysisProvider analysisProvider) {
    String statusText; IconData statusIcon; Color statusColor;
    switch (bleProvider.connectionState) {
      case BleConnectionState.disconnected: statusText = 'Disconnected'; statusIcon = Icons.bluetooth_disabled; statusColor = Colors.redAccent; break;
      case BleConnectionState.scanning: statusText = 'Scanning...'; statusIcon = Icons.bluetooth_searching; statusColor = Colors.orangeAccent; break;
      case BleConnectionState.connecting: statusText = 'Connecting...'; statusIcon = Icons.bluetooth_connected; statusColor = Colors.lightBlueAccent; break;
      case BleConnectionState.connected: statusText = 'Connected'; statusIcon = Icons.bluetooth_connected; statusColor = Colors.cyanAccent; break;
    }
    return Card(
      elevation: 4,
      color: const Color(0xFF2C3545),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(statusIcon, size: 24, color: statusColor),
                const SizedBox(width: 8),
                Text(statusText, style: TextStyle(fontSize: 18, color: statusColor, fontWeight: FontWeight.bold)),
              ],
            ),
            if (bleProvider.connectionState == BleConnectionState.connected)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  analysisProvider.analysisStatus,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
