import 'analysis_widgets.dart';
import 'eeg_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_provider.dart';
import 'analysis_provider.dart';
import 'dart:async';
import 'package:location/location.dart' hide PermissionStatus; // ★ locationパッケージをインポート

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _waveformRefreshTimer;
  final Location location = Location(); // ★ Locationのインスタンスを作成

  @override
  void initState() {
    super.initState();
    // ★ アプリ起動時に権限の確認とリクエストを行うメソッドを呼び出す
    _initializePermissions();

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

  // ★ 変更：アプリ起動時に権限状態を包括的にチェックし、リクエストするメソッド
  Future<void> _initializePermissions() async {
    // 1. OS全体のGPS（位置情報サービス）が有効になっているか確認
    bool serviceEnabled = await location.serviceEnabled();
    if (!serviceEnabled) {
      // 有効でない場合、ユーザーに有効にするようリクエスト
      serviceEnabled = await location.requestService();
      if (!serviceEnabled) {
        // ユーザーが有効にしなかった場合は、ここで処理を中断
        print("位置情報サービスが有効にされませんでした。");
        return;
      }
    }

    // 2. アプリに必要な権限（位置情報とBluetooth）をリクエスト
    // このrequest()メソッドは、まだ許可されていない権限についてのみダイアログを表示します。
    await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
  }

// ★★★★★ このメソッドを最終版に完全に置き換えてください ★★★★★
Future<void> _requestPermissionsAndScan(BleProvider bleProvider, AnalysisProvider analysisProvider) async {
  print("--- Starting Final Permission & Scan Logic ---");

  // 1. 位置情報サービスの状態を permission_handler で確認
  bool serviceEnabled = await Permission.location.serviceStatus.isEnabled;
  if (!serviceEnabled) {
    print("Location service is disabled. Prompting user to open settings.");
    _showLocationServiceDisabledDialog();
    await openAppSettings();
    return;
  }

  // 2. 位置情報権限のみを permission_handler でリクエスト (iOSのルールに従う)
  print("Requesting location permissions...");
  final locationWhenInUseStatus = await Permission.locationWhenInUse.request();
  if (!locationWhenInUseStatus.isGranted) {
    // もし「使用中のみ」が許可されなければ、「常に」はリクエストしない
    print("Location 'When in Use' was not granted. Status: $locationWhenInUseStatus");
    _showPermissionDeniedDialog();
    return;
  }

  // 「使用中のみ」が許可されたら、「常に」をリクエスト
  final locationAlwaysStatus = await Permission.locationAlways.request();
  print("Location 'Always' status: $locationAlwaysStatus");

  // 3. Bluetoothのことは flutter_blue_plus に任せ、スキャンを直接開始する
  // bleProvider.startScan() が内部で flutter_blue_plus を呼び出し、
  // 必要なBluetooth権限ダイアログを自動的に表示します。
  print("Location granted. Handing over to BleProvider to start scan (which handles BT permissions)...");
  
  bleProvider.startScan();
  analysisProvider.startPolling();
}
  
  // ★ 追加：位置情報サービスが無効な場合に表示するダイアログ
  void _showLocationServiceDisabledDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('位置情報サービスを有効にしてください'),
        content: const Text('デバイスをスキャンするには、端末の位置情報サービスをオンにする必要があります。'),
        actions: <Widget>[
          TextButton(
            child: const Text('OK'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ★ 権限が拒否された場合に表示するダイアログ (変更なし)
  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('権限が必要です'),
        content: const Text('デバイスをスキャンして接続するには、Bluetoothと位置情報の権限を許可してください。設定アプリから権限を有効にできます。'),
        actions: <Widget>[
          TextButton(
            child: const Text('設定を開く'),
            onPressed: () {
              // 端末の設定画面を開く
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


  void _disconnect(BleProvider bleProvider, AnalysisProvider analysisProvider) {
      bleProvider.disconnect();
      analysisProvider.stopPolling();
  }

  // (以降のbuildメソッドは変更なし)
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

  // (以降の _buildControlButton と _buildStatusCard は変更なし)
  Widget _buildControlButton(BleProvider bleProvider, AnalysisProvider analysisProvider) {
    bool isConnected = bleProvider.connectionState == BleConnectionState.connected;
    bool isScanning = bleProvider.connectionState == BleConnectionState.scanning || bleProvider.connectionState == BleConnectionState.connecting;

    return ElevatedButton.icon(
      icon: Icon(isConnected ? Icons.link_off : Icons.search),
      label: Text(isConnected ? 'Disconnect' : 'Find Device'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: isConnected ? Colors.purple : Colors.blue,
        minimumSize: const Size(220, 50),
        padding: const EdgeInsets.symmetric(vertical: 15),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 5,
      ),
      onPressed: isScanning ? null : () {
        if (isConnected) {
          _disconnect(bleProvider, analysisProvider);
        } else {
          // ★修正：更新された権限リクエストメソッドを呼び出す
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