import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:collection/collection.dart';
import 'package:zstandard/zstandard.dart'; // ★正しいインポート

// ★★★★★ アイソレート関数を修正 ★★★★★
Future<List<SensorDataPoint>> _decompressAndParseIsolate(Uint8List compressedData) async {
  // ★公式ドキュメント通りの正しい非同期デコード
  final decompressedData = await compressedData.decompress();
  
  if (decompressedData == null) { return []; }
  
  final byteData = ByteData.view(decompressedData.buffer);
  final newPoints = <SensorDataPoint>[];
  const int numEegChannels = 8;
  const int pointSize = 68;
  final int numPoints = decompressedData.length ~/ pointSize;
  
  // ESP32のmicros()は起動からの経過時間なので、これをDateTimeに変換
  final now = DateTime.now();
  final lastTimestamp = byteData.getUint32(pointSize * (numPoints - 1) + (pointSize - 4), Endian.little);
  final espBootTime = now.subtract(Duration(microseconds: lastTimestamp));

  for (int i = 0; i < numPoints; i++) {
    int offset = i * pointSize;
    final List<int> eegs = [];
    for (int ch = 0; ch < numEegChannels; ch++) { eegs.add(byteData.getUint16(offset + (ch * 2), Endian.little)); }
    final point = SensorDataPoint(
      eegValues: eegs,
      timestamp: espBootTime.add(Duration(microseconds: byteData.getUint32(offset + (pointSize - 4), Endian.little))),
    );
    newPoints.add(point);
  }
  return newPoints;
}

// (以降のコードは変更ありません)
const String serverIp = "192.168.11.6"; //
const String serverUploadUrl = "http://$serverIp:6000/upload";
const String targetDeviceName = "ESP32_Sensor_Compressed";
final Guid serviceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid characteristicUuidTx = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid characteristicUuidRx = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); 
enum BleConnectionState { disconnected, scanning, connecting, connected }
class SensorDataPoint { final List<int> eegValues; final DateTime timestamp; SensorDataPoint({ required this.eegValues, required this.timestamp }); }

class BleProvider with ChangeNotifier {
  BleConnectionState _connectionState = BleConnectionState.disconnected;
  BluetoothDevice? _targetDevice;
  StreamSubscription<List<int>>? _valueSubscription;
  final List<int> _receiveBuffer = [];
  int _expectedPacketSize = -1;
  static const int sampleRate = 300;
  static const double timeWindowSec = 5.0;
  static final int bufferSize = (sampleRate * timeWindowSec).toInt();
  final List<SensorDataPoint> _dataBuffer = [];
  double _displayYMin = 1500.0;
  double _displayYMax = 2500.0;
  BluetoothCharacteristic? _rxCharacteristic;
  final List<(DateTime, double)> _valenceHistory = [];
  BleConnectionState get connectionState => _connectionState;
  List<SensorDataPoint> get displayData => _dataBuffer; 
  int get channelCount => _dataBuffer.isNotEmpty ? _dataBuffer.first.eegValues.length : 0;
  double get displayYMin => _displayYMin;
  double get displayYMax => _displayYMax;
  List<(DateTime, double)> get valenceHistory => _valenceHistory;
  BleProvider() { FlutterBluePlus.adapterState.listen((state) { if (state == BluetoothAdapterState.off) { _updateConnectionState(BleConnectionState.disconnected); } }); }
  void _updateConnectionState(BleConnectionState state) { _connectionState = state; notifyListeners(); }
  Future<void> startScan() async { if (_connectionState != BleConnectionState.disconnected) return; _updateConnectionState(BleConnectionState.scanning); _targetDevice = null; _dataBuffer.clear(); _valenceHistory.clear(); try { await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5)); FlutterBluePlus.scanResults.listen((results) { for (ScanResult r in results) { if (r.device.platformName == targetDeviceName) { FlutterBluePlus.stopScan(); _connectToDevice(r.device); break; } } }); } catch (e) { print("SCAN ERROR: $e"); _updateConnectionState(BleConnectionState.disconnected); } await Future.delayed(const Duration(seconds: 5)); if (_connectionState == BleConnectionState.scanning) { FlutterBluePlus.stopScan(); _updateConnectionState(BleConnectionState.disconnected); } }
  Future<void> _connectToDevice(BluetoothDevice device) async { if (_connectionState != BleConnectionState.scanning) return; _updateConnectionState(BleConnectionState.connecting); _targetDevice = device; try { await device.connect(timeout: const Duration(seconds: 10)); _updateConnectionState(BleConnectionState.connected); _discoverServices(device); } catch (e) { print("CONNECTION ERROR: $e"); await device.disconnect(); _updateConnectionState(BleConnectionState.disconnected); } }
  Future<void> _discoverServices(BluetoothDevice device) async { try { List<BluetoothService> services = await device.discoverServices(); for (var service in services) { if (service.uuid == serviceUuid) { BluetoothCharacteristic? tx; BluetoothCharacteristic? rx; for (var characteristic in service.characteristics) { if (characteristic.uuid == characteristicUuidTx) { tx = characteristic; } if (characteristic.uuid == characteristicUuidRx) { rx = characteristic; } } if (tx != null && rx != null) { print("TX and RX characteristics found."); _rxCharacteristic = rx; _subscribeToCharacteristic(tx); await _sendAck(); return; } } } } catch (e) { print("SERVICE DISCOVERY ERROR: $e"); disconnect(); } }
  void _subscribeToCharacteristic(BluetoothCharacteristic characteristic) { _valueSubscription?.cancel(); _receiveBuffer.clear(); _expectedPacketSize = -1; characteristic.setNotifyValue(true); _valueSubscription = characteristic.lastValueStream.listen((value) { _receiveBuffer.addAll(value); _processData(); }); }
  Future<void> _processData() async { 
    if (_expectedPacketSize == -1 && _receiveBuffer.length >= 4) { 
      final header = Uint8List.fromList(_receiveBuffer.sublist(0, 4)); _expectedPacketSize = ByteData.view(header.buffer).getUint32(0, Endian.little); _receiveBuffer.removeRange(0, 4); 
    } 
    if (_expectedPacketSize != -1 && _receiveBuffer.length >= _expectedPacketSize) { 
      final compressedData = Uint8List.fromList(_receiveBuffer.sublist(0, _expectedPacketSize)); 
      _receiveBuffer.removeRange(0, _expectedPacketSize); 
      _expectedPacketSize = -1;
      _sendDataToServer(compressedData);
      try {
        final List<SensorDataPoint> newPoints = await compute(_decompressAndParseIsolate, compressedData);
        _updateDataBuffer(newPoints);
      } catch (e) { print("ISOLATE FAILED: $e"); }
      await _sendAck();
      if (_receiveBuffer.isNotEmpty) { await _processData(); } 
    } 
  }
  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    _dataBuffer.addAll(newPoints);
    if (_dataBuffer.length > bufferSize) {
      _dataBuffer.removeRange(0, _dataBuffer.length - bufferSize);
    }
    _updateYAxisRange();
    _calculateValence();
  }
  void _calculateValence() {
    if (_dataBuffer.length < sampleRate) return;
    final recentData = _dataBuffer.sublist(_dataBuffer.length - sampleRate);
    double powerLeft = 0;
    double powerRight = 0;
    for (var point in recentData) {
      powerLeft += pow(point.eegValues[0] - 2048, 2);
      powerRight += pow(point.eegValues[1] - 2048, 2);
    }
    powerLeft /= recentData.length;
    powerRight /= recentData.length;
    if (powerLeft > 0 && powerRight > 0) {
      final score = log(powerRight) - log(powerLeft);
      final timestamp = recentData.last.timestamp;
      _valenceHistory.add((timestamp, score));
      if (_valenceHistory.length > 200) {
        _valenceHistory.removeAt(0);
      }
    }
  }
  void refreshWaveform() { notifyListeners(); }
  Future<void> _sendDataToServer(Uint8List compressedData) async { try { String base64Data = base64Encode(compressedData); http.post( Uri.parse(serverUploadUrl), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'data': base64Data}), ); print("Data packet sent to server."); } catch (e) { print("Failed to send data to server: $e"); } }
  Future<void> _sendAck() async { if (_rxCharacteristic != null) { try { await _rxCharacteristic!.write([0x01], withoutResponse: true); } catch (e) { print("Failed to send ACK: $e"); } } }
  void _updateYAxisRange() { if (_dataBuffer.isEmpty) return; int minVal = _dataBuffer.first.eegValues.reduce(min); int maxVal = _dataBuffer.first.eegValues.reduce(max); for (var point in _dataBuffer) { for (var val in point.eegValues) { if (val < minVal) minVal = val; if (val > maxVal) maxVal = val; } } if (minVal < _displayYMin || maxVal > _displayYMax) { final range = maxVal - minVal; _displayYMin = (minVal - range * 0.15); _displayYMax = (maxVal + range * 0.15); } }
  Future<void> disconnect() async { _valueSubscription?.cancel(); _valueSubscription = null; if (_targetDevice != null) { await _targetDevice!.disconnect(); } _targetDevice = null; _rxCharacteristic = null; _receiveBuffer.clear(); _expectedPacketSize = -1; _dataBuffer.clear(); _valenceHistory.clear(); _displayYMin = 1500.0; _displayYMax = 2500.0; _updateConnectionState(BleConnectionState.disconnected); }
  @override
  void dispose() { disconnect(); super.dispose(); }
}