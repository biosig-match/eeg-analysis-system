import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_provider.dart';
import 'package:intl/intl.dart';

// ★★★★★ ダウンサンプリング率を 3 から 6 に変更 ★★★★★
const int downsamplingFactor = 6;

class EegSingleChannelChart extends StatelessWidget {
  final int channelIndex;
  
  const EegSingleChannelChart({super.key, required this.channelIndex});

  double _adcToMicrovolts(double adcValue) {
    return (adcValue - 2048.0) * (200.0 / 2048.0);
  }

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final dataPoints = bleProvider.displayData;

    if (dataPoints.isEmpty || dataPoints.first.eegValues.length <= channelIndex) {
      return const AspectRatio(aspectRatio: 2.5, child: Center(child: Text('...')));
    }

    final List<FlSpot> spots = [];
    for (int i = 0; i < dataPoints.length; i += downsamplingFactor) {
      spots.add(FlSpot(i.toDouble(), dataPoints[i].eegValues[channelIndex].toDouble()));
    }

    return AspectRatio(
      aspectRatio: 2.5,
      child: Padding(
        padding: const EdgeInsets.only(right: 18.0, top: 10, bottom: 5),
        child: LineChart(
          LineChartData(
            minY: bleProvider.displayYMin,
            maxY: bleProvider.displayYMax,
            minX: 0,
            maxX: (BleProvider.bufferSize).toDouble() - 1,
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: false,
                color: Colors.cyan.withOpacity(0.8),
                barWidth: 1.2,
                dotData: const FlDotData(show: false),
              ),
            ],
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 45,
                  getTitlesWidget: (value, meta) {
                    final microvolts = _adcToMicrovolts(value);
                    return Text('${microvolts.toStringAsFixed(0)}µV', style: const TextStyle(color: Colors.white70, fontSize: 10));
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 30,
                  interval: BleProvider.sampleRate.toDouble(),
                  getTitlesWidget: (value, meta) {
                    final index = value.toInt();
                    if (index >= 0 && index < dataPoints.length) {
                      final timestamp = dataPoints[index].timestamp;
                      return Text(DateFormat('HH:mm:ss').format(timestamp), style: const TextStyle(color: Colors.white70, fontSize: 10));
                    }
                    return const Text('');
                  },
                ),
              ),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            gridData: const FlGridData(show: true, drawVerticalLine: true),
            borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24)),
          ),
        ),
      ),
    );
  }
}
