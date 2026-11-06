import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mobile_connection_service.dart';
import 'runfuel_database.dart';
import 'training_data_service.dart';

/// Compares diary and recovery data against the primary sport selected in Settings.
class TrainingNutritionInsightsPanel extends StatefulWidget {
  const TrainingNutritionInsightsPanel({super.key, required this.reportingDays});
  final int reportingDays;

  @override
  State<TrainingNutritionInsightsPanel> createState() =>
      _TrainingNutritionInsightsPanelState();
}

class _TrainingNutritionInsightsPanelState extends State<TrainingNutritionInsightsPanel> {
  late Future<_Comparison> _comparison;
  bool _backfilling = false;
  int _backfillDone = 0;
  int _backfillTotal = 0;
  String? _backfillMessage;

  static const _sportLabels = <String, String>{
    'running': 'Running', 'cycling': 'Cycling', 'swimming': 'Swimming',
    'strength': 'Gym / strength', 'triathlon': 'Triathlon',
    'team_sports': 'Team sports', 'walking_hiking': 'Walking / hiking',
    'mobility': 'Mobility / yoga / Pilates',
    'general_fitness': 'General fitness', 'lifestyle': 'Active lifestyle',
  };

  @override
  void initState() {
    super.initState();
    _comparison = _load(widget.reportingDays);
  }

  Future<_Comparison> _load(int reportingDays) async {
    final prefs = await SharedPreferences.getInstance();
    final selectedSport = _sportLabels.containsKey(prefs.getString('primary_training_focus'))
        ? prefs.getString('primary_training_focus')!
        : 'running';
    final db = await RunFuelDatabase.instance.database;
    final today = DateTime.now();
    final firstDay = DateTime(today.year, today.month, today.day).subtract(Duration(days: reportingDays - 1));
    final cutoff = _dateKey(firstDay);
    final activities = await db.query('activities',
      columns: ['started_at', 'sport'], where: 'started_at >= ?', whereArgs: [cutoff]);
    final nutrition = await db.query('nutrition_days',
      where: 'day >= ? AND day <= ?', whereArgs: [cutoff, _dateKey(today)]);
    final sleep = await db.query('sleep_records',
      where: 'sleep_date >= ? AND sleep_date <= ?', whereArgs: [cutoff, _dateKey(today)]);

    // Build all 30 calendar dates first. A date without the selected sport is
    // a rest day for this training focus, even if another sport/activity exists.
    final exerciseDays = <String>{};
    for (final activity in activities) {
      final rawDate = activity['started_at']?.toString() ?? '';
      final sport = activity['sport']?.toString() ?? '';
      if (rawDate.length >= 10 && _matchesFocus(sport, selectedSport)) {
        exerciseDays.add(rawDate.substring(0, 10));
      }
    }
    final calendar = List.generate(reportingDays, (i) => _dateKey(firstDay.add(Duration(days: i))));
    final exerciseCount = calendar.where(exerciseDays.contains).length;
    final restCount = calendar.length - exerciseCount;
    final nutritionByDay = {for (final row in nutrition) row['day'].toString(): row};
    final sleepByDay = {for (final row in sleep) row['sleep_date'].toString(): row};

    final runNutrition = <Map>[];
    final restNutrition = <Map>[];
    final runSleep = <Map>[];
    final restSleep = <Map>[];
    var diaryMissingExercise = 0;
    var diaryMissingRest = 0;
    for (final day in calendar) {
      final isExercise = exerciseDays.contains(day);
      final diary = nutritionByDay[day];
      if (diary == null) {
        if (isExercise) { diaryMissingExercise++; } else { diaryMissingRest++; }
      } else {
        (isExercise ? runNutrition : restNutrition).add(diary);
      }
      final night = sleepByDay[day];
      if (night != null) (isExercise ? runSleep : restSleep).add(night);
    }

    return _Comparison(
      sportLabel: _sportLabels[selectedSport]!,
      exerciseDays: exerciseCount,
      restDays: restCount,
      nutritionExercise: _average(runNutrition.map((r) => _num(r['carbs_g']))),
      nutritionRest: _average(restNutrition.map((r) => _num(r['carbs_g']))),
      caloriesExercise: _average(runNutrition.map((r) => _num(r['calories']))),
      caloriesRest: _average(restNutrition.map((r) => _num(r['calories']))),
      sleepExercise: _average(runSleep.map((r) => _num(r['total_sleep_s']) == null ? null : _num(r['total_sleep_s'])! / 3600)),
      sleepRest: _average(restSleep.map((r) => _num(r['total_sleep_s']) == null ? null : _num(r['total_sleep_s'])! / 3600)),
      nutritionExerciseCount: runNutrition.where((r) => _num(r['carbs_g']) != null || _num(r['calories']) != null).length,
      nutritionRestCount: restNutrition.where((r) => _num(r['carbs_g']) != null || _num(r['calories']) != null).length,
      sleepExerciseCount: runSleep.where((r) => _num(r['total_sleep_s']) != null).length,
      sleepRestCount: restSleep.where((r) => _num(r['total_sleep_s']) != null).length,
      diaryMissingExercise: diaryMissingExercise,
      diaryMissingRest: diaryMissingRest,
    );
  }

  bool _matchesFocus(String raw, String focus) {
    final sport = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    switch (focus) {
      case 'running': return sport == 'running' || sport.contains('run');
      case 'cycling': return sport == 'cycling' || sport.contains('cycl') || sport.contains('bike');
      case 'swimming': return sport == 'swimming' || sport.contains('swim');
      case 'strength': return sport == 'strength' || sport.contains('strength') || sport.contains('gym');
      case 'triathlon': return sport == 'triathlon' || sport.contains('triathlon');
      case 'team_sports': return sport == 'team_sports' || sport.contains('team');
      case 'walking_hiking': return sport == 'walking_hiking' || sport.contains('walk') || sport.contains('hike');
      case 'mobility': return sport == 'mobility' || sport.contains('yoga') || sport.contains('pilates');
      case 'general_fitness': return sport == 'general_fitness' || sport.contains('fitness');
      case 'lifestyle': return sport == 'lifestyle';
      default: return sport == focus;
    }
  }

  Future<void> _backfillDiary() async {
    if (_backfilling) return;
    final authorised = await MobileConnectionService().isAuthorized();
    if (!authorised) {
      setState(() => _backfillMessage = 'Connect RunFuel in Settings before fetching diary history.');
      return;
    }
    final db = await RunFuelDatabase.instance.database;
    final today = DateTime.now();
    final firstDay = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 29));
    final existing = await db.query('nutrition_days', columns: ['day'],
      where: 'day >= ?', whereArgs: [_dateKey(firstDay)]);
    final saved = existing.map((r) => r['day'].toString()).toSet();
    final missing = List.generate(30, (i) => _dateKey(firstDay.add(Duration(days: i))))
        .where((day) => !saved.contains(day)).toList();
    setState(() {
      _backfilling = true;
      _backfillDone = 0;
      _backfillTotal = missing.length;
      _backfillMessage = missing.isEmpty ? 'All 30 diary dates already have records.' : 'Fetching missing diary dates…';
    });
    try {
      for (final day in missing) {
        final date = DateTime.parse(day);
        final payload = await MobileConnectionService().sync(date: date);
        await TrainingDataService.instance.persistSyncPayload(payload);
        if (mounted) setState(() => _backfillDone++);
      }
      if (mounted) {
        setState(() {
          _backfillMessage = 'History refresh complete. Dates with no diary entries remain marked as missing.';
          _comparison = _load(widget.reportingDays);
        });
      }
    } catch (error) {
      if (mounted) setState(() => _backfillMessage = 'History refresh stopped: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  static String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static double? _num(dynamic value) => value is num ? value.toDouble() : null;
  double? _average(Iterable<double?> values) {
    final present = values.whereType<double>().toList();
    if (present.isEmpty) return null;
    return present.reduce((a, b) => a + b) / present.length;
  }
  String _value(double? value, String unit) => value == null ? '--' : '${value.toStringAsFixed(1)} $unit';

  @override
  Widget build(BuildContext context) => FutureBuilder<_Comparison>(
    future: _comparison,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError || !snapshot.hasData) {
        return const Text('Training and nutrition history is not available yet.');
      }
      final data = snapshot.data!;
      return Card(
        color: Theme.of(context).colorScheme.surfaceContainer,
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${data.sportLabel} Exercise Days vs Rest Days · ${widget.reportingDays == 28 ? '4 Weeks' : '${widget.reportingDays} Days'}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              IconButton(
                tooltip: 'Copy training and nutrition patterns',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () async {
                  final period = widget.reportingDays == 28 ? 'Previous 4 weeks' : 'Previous ${widget.reportingDays} days';
                  final report = [
                    'TRAINING & NUTRITION PATTERNS — $period',
                    'Training focus: ${data.sportLabel}',
                    'Exercise days: ${data.exerciseDays}',
                    'Rest days: ${data.restDays}',
                    '',
                    'AVERAGE CALORIES LOGGED',
                    'Exercise days: ${data.caloriesExercise?.toStringAsFixed(0) ?? 'Not enough data'} kcal (n=${data.nutritionExerciseCount})',
                    'Rest days: ${data.caloriesRest?.toStringAsFixed(0) ?? 'Not enough data'} kcal (n=${data.nutritionRestCount})',
                    '',
                    'AVERAGE CARBOHYDRATES',
                    'Exercise days: ${data.nutritionExercise?.toStringAsFixed(1) ?? 'Not enough data'} g (n=${data.nutritionExerciseCount})',
                    'Rest days: ${data.nutritionRest?.toStringAsFixed(1) ?? 'Not enough data'} g (n=${data.nutritionRestCount})',
                    '',
                    'AVERAGE SLEEP',
                    'Exercise days: ${data.sleepExercise?.toStringAsFixed(1) ?? 'Not enough data'} hours (n=${data.sleepExerciseCount})',
                    'Rest days: ${data.sleepRest?.toStringAsFixed(1) ?? 'Not enough data'} hours (n=${data.sleepRestCount})',
                    '',
                    'Diary coverage: ${data.nutritionExerciseCount} exercise days and ${data.nutritionRestCount} rest days recorded.',
                    'Missing diary dates: ${data.diaryMissingExercise} exercise, ${data.diaryMissingRest} rest.',
                    'Missing diary and sleep records are excluded from averages, not counted as zero.',
                  ].join('\n');
                  await Clipboard.setData(ClipboardData(text: report));
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Training and nutrition report copied.')));
                },
              ),
            ]),
            const SizedBox(height: 4),
            Text('${data.exerciseDays} ${data.sportLabel.toLowerCase()} days · ${data.restDays} rest days for this training focus',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .58), fontSize: 11)),
            const SizedBox(height: 12),
            Text('Average carbohydrate intake', style: Theme.of(context).textTheme.labelMedium),
            _ComparisonRow('Exercise days', _value(data.nutritionExercise, 'g'), data.nutritionExerciseCount),
            _ComparisonRow('Rest days', _value(data.nutritionRest, 'g'), data.nutritionRestCount),
            const SizedBox(height: 10),
            Text('Average calories logged', style: Theme.of(context).textTheme.labelMedium),
            _ComparisonRow('Exercise days', _value(data.caloriesExercise, 'kcal'), data.nutritionExerciseCount),
            _ComparisonRow('Rest days', _value(data.caloriesRest, 'kcal'), data.nutritionRestCount),
            const SizedBox(height: 10),
            Text('Average sleep duration', style: Theme.of(context).textTheme.labelMedium),
            _ComparisonRow('Exercise days', _value(data.sleepExercise, 'h'), data.sleepExerciseCount),
            _ComparisonRow('Rest days', _value(data.sleepRest, 'h'), data.sleepRestCount),
            const SizedBox(height: 8),
            Text('Diary coverage: ${data.nutritionExerciseCount} exercise days and ${data.nutritionRestCount} rest days recorded. Missing diary dates: ${data.diaryMissingExercise} exercise, ${data.diaryMissingRest} rest.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62), fontSize: 11, height: 1.4)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _backfilling ? null : _backfillDiary,
              icon: _backfilling ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.history),
              label: Text(_backfilling ? 'Fetching diary history $_backfillDone/$_backfillTotal' : 'Fetch missing 30-day diary history'),
            ),
            if (_backfillMessage != null)
              Text(_backfillMessage!, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .65))),
            const SizedBox(height: 6),
            Text('A day is an exercise day only when the primary sport selected in Settings is recorded. Other activities do not change it from a rest day. Missing diary entries and sleep records are excluded from averages, never treated as zero.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .5), fontSize: 10, height: 1.4)),
          ]),
        ),
      );
    },
  );
}

class _ComparisonRow extends StatelessWidget {
  const _ComparisonRow(this.label, this.value, this.count);
  final String label;
  final String value;
  final int count;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), fontSize: 12))),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(width: 8),
      Text('n=$count', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .38), fontSize: 10)),
    ]),
  );
}

class _Comparison {
  const _Comparison({
    required this.sportLabel, required this.exerciseDays, required this.restDays,
    required this.nutritionExercise, required this.nutritionRest,
    required this.caloriesExercise, required this.caloriesRest,
    required this.sleepExercise, required this.sleepRest,
    required this.nutritionExerciseCount, required this.nutritionRestCount,
    required this.sleepExerciseCount, required this.sleepRestCount,
    required this.diaryMissingExercise, required this.diaryMissingRest,
  });
  final String sportLabel;
  final int exerciseDays, restDays;
  final double? nutritionExercise, nutritionRest, caloriesExercise, caloriesRest, sleepExercise, sleepRest;
  final int nutritionExerciseCount, nutritionRestCount, sleepExerciseCount, sleepRestCount;
  final int diaryMissingExercise, diaryMissingRest;
}
