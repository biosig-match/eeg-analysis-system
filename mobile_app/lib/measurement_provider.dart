import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

// エポックごとに収集されるデータをまとめるクラス
class EpochData {
  final int epochNumber;
  final Uint8List imageBytes;
  final Uint8List audioBytes;

  EpochData({
    required this.epochNumber,
    required this.imageBytes,
    required this.audioBytes,
  });
}

enum MeasurementState {
  stopped,
  initializing,
  measuring,
  error,
}

class MeasurementProvider with ChangeNotifier {
  final String _baseUrl;
  MeasurementProvider(this._baseUrl);

  // --- 状態変数 ---
  MeasurementState _state = MeasurementState.stopped;
  String _statusMessage = "計測停止中";
  int _epochCount = 0;
  Timer? _epochTimer;

  // --- 外部公開ゲッター ---
  MeasurementState get state => _state;
  String get statusMessage => _statusMessage;
  int get epochCount => _epochCount;
  bool get isMeasuring => _state == MeasurementState.measuring || _state == MeasurementState.initializing;

  // --- 内部リソース ---
  CameraController? _cameraController;
  late final AudioRecorder _audioRecorder;
  CameraDescription? _camera;

  // --- 初期化 ---
  Future<void> initialize() async {
    _audioRecorder = AudioRecorder();
    // 利用可能なカメラを取得
    final cameras = await availableCameras();
    // 背面カメラを選択
    _camera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
  }

  // --- 計測開始 ---
  Future<void> startMeasurement() async {
    if (isMeasuring) return;

    // 1. 権限の確認とリクエスト
    if (!await _requestPermissions()) {
      _updateState(MeasurementState.error, "カメラまたはマイクの権限がありません。");
      return;
    }

    // 2. リソースの初期化
    _updateState(MeasurementState.initializing, "カメラとマイクを準備中...");
    try {
      if (_camera == null) await initialize();
      if (_camera == null) throw Exception("利用可能なカメラがありません。");

      _cameraController = CameraController(_camera!, ResolutionPreset.medium, enableAudio: false);
      await _cameraController!.initialize();
      _epochCount = 0;
    } catch (e) {
      print("Error initializing resources: $e");
      _updateState(MeasurementState.error, "リソースの初期化に失敗しました。");
      await stopMeasurement(); // クリーンアップ
      return;
    }
    
    // 3. エポックタイマーを開始
    _updateState(MeasurementState.measuring, "エポック #1 を開始します...");
    _epochTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _runEpoch();
    });
    // 最初の実行
    _runEpoch(); 
  }

  // --- エポックの実行 ---
  Future<void> _runEpoch() async {
    _epochCount++;
    _updateState(MeasurementState.measuring, "エポック #${_epochCount} を記録中...");

    try {
      // Futureをリストで管理
      final futures = <Future<dynamic>>[];
      
      // 音声録音の開始 (メモリ内)
      final audioStreamCompleter = Completer<Uint8List>();
      futures.add(audioStreamCompleter.future);
      _startAudioRecording(audioStreamCompleter);

      // 5秒後に写真撮影
      final imageCompleter = Completer<XFile>();
      futures.add(imageCompleter.future);
      Future.delayed(const Duration(seconds: 5), () async {
        try {
          final image = await _cameraController!.takePicture();
          imageCompleter.complete(image);
        } catch(e) {
          imageCompleter.completeError(e);
        }
      });
      
      // 10秒待機 (タイマーの周期と同期)
      await Future.delayed(const Duration(seconds: 10));
      
      // 結果を待つ
      final results = await Future.wait(futures);

      // 結果の取り出し
      final audioBytes = results[0] as Uint8List;
      final imageFile = results[1] as XFile;
      final imageBytes = await imageFile.readAsBytes();
      
      final epochData = EpochData(
        epochNumber: _epochCount,
        imageBytes: imageBytes,
        audioBytes: audioBytes,
      );

      // データをサーバーに送信
      _sendEpochDataToServer(epochData);

      _statusMessage = "エポック #${_epochCount} のデータを送信しました。";
      notifyListeners();

    } catch (e) {
      print("Epoch failed: $e");
      _updateState(MeasurementState.error, "エポック #${_epochCount} でエラー発生。");
      await stopMeasurement();
    }
  }

  // --- 音声録音の開始と停止 ---
  Future<void> _startAudioRecording(Completer<Uint8List> completer) async {
    try {
      // メモリ上のストリームに録音
      final stream = await _audioRecorder.startStream(const RecordConfig(encoder: AudioEncoder.aacLc));
      
      final List<int> buffer = [];
      final streamSubscription = stream.listen(
        (data) {
          buffer.addAll(data);
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(Uint8List.fromList(buffer));
          }
        },
        onError: (err) {
          if (!completer.isCompleted) {
            completer.completeError(err);
          }
        }
      );

      // 10秒後に停止
      Future.delayed(const Duration(seconds: 10), () async {
        await _audioRecorder.stop();
        await streamSubscription.cancel();
      });

    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }
  }

  // --- 計測停止 ---
  Future<void> stopMeasurement() async {
    _epochTimer?.cancel();
    _epochTimer = null;
    try {
      // ★★★ 修正点 ★★★
      // isRecording()はFuture<bool>を返すメソッドのため、awaitで呼び出します。
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
      await _cameraController?.dispose();
    } catch (e) {
        print("Error during cleanup: $e");
    } finally {
        _cameraController = null;
        _updateState(MeasurementState.stopped, "計測が停止されました。");
    }
  }

  // --- データ送信 ---
  Future<void> _sendEpochDataToServer(EpochData data) async {
    try {
      final url = Uri.parse('$_baseUrl/upload_epoch');
      final request = http.MultipartRequest('POST', url)
        ..fields['epoch_number'] = data.epochNumber.toString()
        ..fields['timestamp'] = DateTime.now().toIso8601String()
        ..files.add(http.MultipartFile.fromBytes(
          'image',
          data.imageBytes,
          filename: 'epoch_${data.epochNumber}.jpg',
        ))
        ..files.add(http.MultipartFile.fromBytes(
          'audio',
          data.audioBytes,
          filename: 'epoch_${data.epochNumber}.m4a',
        ));

      final response = await request.send();

      if (response.statusCode == 200) {
        print('Epoch ${data.epochNumber} data sent successfully.');
      } else {
        print('Failed to send epoch ${data.epochNumber} data. Status: ${response.statusCode}');
      }
    } catch (e) {
      print('Error sending epoch data: $e');
    }
  }
  
  // --- ヘルパーメソッド ---
  void _updateState(MeasurementState state, String message) {
    _state = state;
    _statusMessage = message;
    notifyListeners();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();
    return statuses[Permission.camera]!.isGranted && statuses[Permission.microphone]!.isGranted;
  }

  @override
  void dispose() {
    stopMeasurement();
    _audioRecorder.dispose();
    super.dispose();
  }
}

