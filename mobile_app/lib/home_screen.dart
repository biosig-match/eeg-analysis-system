import 'analysis_widgets.dart';
import 'eeg_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_provider.dart';
import 'analysis_provider.dart';
import 'dart:async';

import 'measurement_provider.dart'; // ★追加

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
    // MeasurementProviderの初期化処理を呼び出す
    context.read<MeasurementProvider>().initialize().then((_) {
      print("MeasurementProvider initialized.");
    });

    _waveformRefreshTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted && context.read<BleProvider>().connectionState == BleConnectionState.connected) {
        context.read<BleProvider>().refreshWaveform();
      }
    });
  }

  @override
  void dispose() {
    _waveformRefreshTimer?.cancel();
    super.dispose();
  }

  // ★ 権限リクエストロジックを更新
  Future<void> _requestPermissionsAndScan(BleProvider bleProvider, AnalysisProvider analysisProvider) async {
    // 必要なすべての権限を一度にリクエスト
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.camera,
      Permission.microphone,
    ].request();

    // 重要な権限が許可されているかチェック
    if (statuses[Permission.location]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothConnect]!.isGranted) {
      print("BLE permissions granted. Starting scan.");
      bleProvider.startScan();
      analysisProvider.startPolling();
    } else {
      print("Core permissions denied.");
      _showPermissionDeniedDialog();
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('権限が必要です'),
        content: const Text('アプリを機能させるには、位置情報、Bluetooth、カメラ、マイクの権限が必要です。'),
        actions: <Widget>[
          TextButton(
            child: const Text('設定を開く'),
            onPressed: () {
              openAppSettings();
              Navigator.of(context).pop();
            },
          ),
          TextButton(
            child: const Text('キャンセル'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  void _disconnect(BleProvider bleProvider, AnalysisProvider analysisProvider, MeasurementProvider measurementProvider) {
      // 計測中であれば停止する
      if (measurementProvider.isMeasuring) {
        measurementProvider.stopMeasurement();
      }
      bleProvider.disconnect();
      analysisProvider.stopPolling();
  }

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final analysisProvider = context.watch<AnalysisProvider>();
    final measurementProvider = context.watch<MeasurementProvider>(); // ★追加
    final channelCount = bleProvider.channelCount;
    final isConnected = bleProvider.connectionState == BleConnectionState.connected;

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
                  _buildStatusCard(bleProvider, analysisProvider, measurementProvider), // ★引数追加
                  const SizedBox(height: 12),
                  // ★ 接続状態に応じて表示するボタンを変更
                  if (!isConnected)
                    _buildScanButton(bleProvider, analysisProvider)
                  else
                    _buildConnectedActionButtons(bleProvider, analysisProvider, measurementProvider),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ★ スキャンボタン
  Widget _buildScanButton(BleProvider bleProvider, AnalysisProvider analysisProvider) {
    bool isScanning = bleProvider.connectionState == BleConnectionState.scanning || bleProvider.connectionState == BleConnectionState.connecting;

    return ElevatedButton.icon(
      icon: const Icon(Icons.search),
      label: const Text('Find Device'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.blue,
        minimumSize: const Size(double.infinity, 50),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      onPressed: isScanning ? null : () {
        _requestPermissionsAndScan(bleProvider, analysisProvider);
      },
    );
  }
  
  // ★ 接続後のアクションボタン
  Widget _buildConnectedActionButtons(BleProvider bleProvider, AnalysisProvider analysisProvider, MeasurementProvider measurementProvider) {
    final isMeasuring = measurementProvider.isMeasuring;

    return Row(
      children: [
        // 計測開始・停止ボタン
        Expanded(
          child: ElevatedButton.icon(
            icon: Icon(isMeasuring ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            label: Text(isMeasuring ? 'Stop Measurement' : 'Start Measurement'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isMeasuring ? Colors.redAccent : Colors.greenAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 50),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            onPressed: () {
              if (isMeasuring) {
                measurementProvider.stopMeasurement();
              } else {
                measurementProvider.startMeasurement();
              }
            },
          ),
        ),
        const SizedBox(width: 12),
        // 切断ボタン
        ElevatedButton.icon(
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.purple,
            minimumSize: const Size(0, 50),
             textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          onPressed: () {
            _disconnect(bleProvider, analysisProvider, measurementProvider);
          },
        ),
      ],
    );
  }

  // ★ ステータス表示を更新
  Widget _buildStatusCard(BleProvider bleProvider, AnalysisProvider analysisProvider, MeasurementProvider measurementProvider) {
    String bleStatusText; IconData bleStatusIcon; Color bleStatusColor;
    switch (bleProvider.connectionState) {
      case BleConnectionState.disconnected: bleStatusText = 'Disconnected'; bleStatusIcon = Icons.bluetooth_disabled; bleStatusColor = Colors.redAccent; break;
      case BleConnectionState.scanning: bleStatusText = 'Scanning...'; bleStatusIcon = Icons.bluetooth_searching; bleStatusColor = Colors.orangeAccent; break;
      case BleConnectionState.connecting: bleStatusText = 'Connecting...'; bleStatusIcon = Icons.bluetooth_connected; bleStatusColor = Colors.lightBlueAccent; break;
      case BleConnectionState.connected: bleStatusText = 'Connected'; bleStatusIcon = Icons.bluetooth_connected; bleStatusColor = Colors.cyanAccent; break;
    }

    return Card(
      elevation: 4,
      color: const Color(0xFF2C3545),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(bleStatusIcon, size: 24, color: bleStatusColor),
                const SizedBox(width: 8),
                Text(bleStatusText, style: TextStyle(fontSize: 18, color: bleStatusColor, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(color: Colors.white24, height: 16),
            // ★ 計測ステータスを追加
            if (bleProvider.connectionState == BleConnectionState.connected)
              Text(
                measurementProvider.statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              )
            else
              Text(
                analysisProvider.analysisStatus,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}
