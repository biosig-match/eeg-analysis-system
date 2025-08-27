import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const String serverIp = "192.168.11.6"; // サーバー（自身のPC）のIPアドレスに置き換えてください（実環境の場合はhttp://）
const String serverResultsUrl = "http://$serverIp:6000/results";

// ★快不快度を削除
class AnalysisResult {
  final Uint8List? psdImage;
  final Uint8List? coherenceImage;
  AnalysisResult({this.psdImage, this.coherenceImage});
}

class AnalysisProvider with ChangeNotifier {
  Timer? _pollingTimer;
  AnalysisResult? _latestAnalysis;
  String _analysisStatus = "サーバーからの解析結果を待っています...";
  bool _isFetching = false;

  AnalysisResult? get latestAnalysis => _latestAnalysis;
  String get analysisStatus => _analysisStatus;

  void startPolling() {
    stopPolling();
    // ★初回はすぐに実行
    fetchLatestResults(); 
    _pollingTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      fetchLatestResults();
    });
  }

  void stopPolling() {
    _pollingTimer?.cancel();
  }

  Future<void> fetchLatestResults() async {
    if (_isFetching) return;
    _isFetching = true;

    try {
      final response = await http.get(Uri.parse(serverResultsUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body);
        if (results.containsKey('psd_image')) {
          _latestAnalysis = AnalysisResult(
            psdImage: base64Decode(results['psd_image']),
            coherenceImage: base64Decode(results['coherence_image']),
          );
          _analysisStatus = "解析結果を更新しました (${DateTime.now().hour}:${DateTime.now().minute})";
        } else {
          _analysisStatus = "サーバーでデータを蓄積中...";
        }
      } else {
        _analysisStatus = "サーバーエラー: ${response.statusCode}";
      }
    } catch (e) {
      _analysisStatus = "解析サーバーへの接続に失敗";
      print("Failed to fetch analysis results: $e");
    }

    _isFetching = false;
    notifyListeners();
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}