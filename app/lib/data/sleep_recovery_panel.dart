import 'package:flutter/material.dart';

import 'runfuel_database.dart';

/// Historical sleep view backed by locally retained Garmin nightly records.
class SleepRecoveryPanel extends StatefulWidget {
  const SleepRecoveryPanel({super.key, required this.selectedDate});
  final DateTime selectedDate;

  @override
  State<SleepRecoveryPanel> createState() => _SleepRecoveryPanelState();
}

class _SleepRecoveryPanelState extends State<SleepRecoveryPanel> {
  late final Future<List<Map<String, Object?>>> _records = _load();

  Future<List<Map<String, Object?>>> _load() async {
    final db = await RunFuelDatabase.instance.database;
    final selectedDay = widget.selectedDate.toIso8601String().substring(0, 10);
    final since = widget.selectedDate.subtract(const Duration(days: 29))
        .toIso8601String().substring(0, 10);
    return db.query(
      'sleep_records',
      where: 'sleep_date >= ? AND sleep_date <= ?',
      whereArgs: [since, selectedDay],
      orderBy: 'sleep_date DESC',
      limit: 30,
    );
  }

  String _hours(double? seconds) {
    if (seconds == null || seconds <= 0) return '--';
    final minutes = (seconds / 60).round();
    return '${minutes ~/ 60}h ${(minutes % 60).toString().padLeft(2, '0')}m';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    future: _records,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return Padding(
          padding: EdgeInsets.all(18),
          child: Center(child: Text('Loading Sleep History…', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6)))),
        );
      }
      if (snapshot.hasError) {
        return const _SleepMessage(
          title: 'Sleep history unavailable',
          body: 'RunFuel could not read the locally saved sleep history.',
        );
      }
      final records = snapshot.data ?? [];
      if (records.isEmpty) {
        return const _SleepMessage(
          title: 'Building Your Sleep History',
          body: 'Sync Garmin each day. RunFuel will retain each available night so the coach can compare sleep with training, nutrition and recovery over time.',
        );
      }

      final latest = records.first;
      final seven = records.take(7).toList();
      final durations = seven
          .map((r) => r['total_sleep_s'])
          .whereType<num>()
          .map((n) => n.toDouble())
          .where((n) => n > 0)
          .toList();
      final scores = seven
          .map((r) => r['sleep_score'])
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      final avgDuration = durations.isEmpty
          ? null
          : durations.reduce((a, b) => a + b) / durations.length;
      final avgScore = scores.isEmpty
          ? null
          : scores.reduce((a, b) => a + b) / scores.length;
      final trend = records.reversed
          .map((r) => r['total_sleep_s'] is num
              ? (r['total_sleep_s'] as num).toDouble() / 3600
              : 0.0)
          .toList();

      return Card(
        color: Theme.of(context).colorScheme.surfaceContainer,
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.bedtime_outlined, color: Color(0xFF9BE15D)),
                SizedBox(width: 9),
                Text('Sleep History', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Spacer(),
                Text('Through ${widget.selectedDate.toIso8601String().substring(0, 10)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .58), fontSize: 12)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: _SleepMetric(
                  label: 'Last night',
                  value: _hours((latest['total_sleep_s'] as num?)?.toDouble()),
                )),
                Expanded(child: _SleepMetric(
                  label: '7-night average',
                  value: _hours(avgDuration),
                )),
                Expanded(child: _SleepMetric(
                  label: 'Avg score',
                  value: avgScore == null ? '--' : avgScore.toStringAsFixed(0),
                )),
              ]),
              const SizedBox(height: 16),
              Text('Nightly Sleep Duration', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), fontSize: 12)),
              const SizedBox(height: 8),
              SizedBox(
                height: 62,
                width: double.infinity,
                child: CustomPaint(painter: _SleepSparkline(trend)),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 14, runSpacing: 8, children: [
                _StageLabel('Deep', _hours((latest['deep_sleep_s'] as num?)?.toDouble())),
                _StageLabel('Light', _hours((latest['light_sleep_s'] as num?)?.toDouble())),
                _StageLabel('REM', _hours((latest['rem_sleep_s'] as num?)?.toDouble())),
                _StageLabel('Awake', _hours((latest['awake_s'] as num?)?.toDouble())),
              ]),
              const SizedBox(height: 10),
              Text(
                '${records.length} nights saved · averages use nights with returned data',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .54), fontSize: 11),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SleepMetric extends StatelessWidget {
  const _SleepMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 3),
      Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .54), fontSize: 11)),
    ],
  );
}

class _StageLabel extends StatelessWidget {
  const _StageLabel(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text(
    '$label  $value',
    style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .7), fontSize: 11),
  );
}

class _SleepMessage extends StatelessWidget {
  const _SleepMessage({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.bedtime_outlined, color: Color(0xFF9BE15D)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(body, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), height: 1.4)),
      ]),
    ),
  );
}

class _SleepSparkline extends CustomPainter {
  const _SleepSparkline(this.values);
  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final valid = values.where((v) => v > 0).toList();
    if (valid.length < 2) return;
    final minimum = valid.reduce((a, b) => a < b ? a : b);
    final maximum = valid.reduce((a, b) => a > b ? a : b);
    final minValue = minimum > 0.75 ? minimum - 0.75 : 0.0;
    final maxValue = maximum + 0.75;
    final range = maxValue - minValue;
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final value = values[i] > 0 ? values[i] : minValue;
      final y = size.height - ((value - minValue) / range) * size.height;
      points.add(Offset(x, y));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    final paint = Paint()
      ..color = const Color(0xFF9BE15D)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SleepSparkline oldDelegate) =>
      oldDelegate.values != values;
}
