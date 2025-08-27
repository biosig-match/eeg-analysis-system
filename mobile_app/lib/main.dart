import 'package:eeg_visualizer_app/analysis_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ble_provider.dart';
import 'home_screen.dart';
import 'config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = await ConfigLoader.loadEnv();
  final serverConfig = ServerConfig.fromEnv(env);
  runApp(MyApp(serverConfig: serverConfig));
}

class MyApp extends StatelessWidget {
  final ServerConfig serverConfig;
  const MyApp({super.key, required this.serverConfig});

  @override
  Widget build(BuildContext context) {
    // ★MultiProviderを使って複数のプロバイダを登録
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => BleProvider(serverConfig.baseUrl)),
        ChangeNotifierProvider(create: (context) => AnalysisProvider(serverConfig.baseUrl)),
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
