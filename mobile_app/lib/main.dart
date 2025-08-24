import 'package:eeg_visualizer_app/analysis_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_provider.dart';
import 'home_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ★MultiProviderを使って複数のプロバイダを登録
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => BleProvider()),
        ChangeNotifierProvider(create: (context) => AnalysisProvider()),
      ],
      child: MaterialApp(
        title: 'EEG Visualizer & Analyzer',
        theme: ThemeData(
          primarySwatch: Colors.blueGrey,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}