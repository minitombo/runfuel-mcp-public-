import 'package:sqflite/sqflite.dart';

import 'runfuel_database.dart';

/// Persists provider summaries locally and makes conservative workout matches.
/// It never writes back to Garmin or MyFitnessPal.
class TrainingDataService {
  TrainingDataService._();

  static final TrainingDataService instance = TrainingDataService._();

  Future<void> persistSyncPayload(Map<String, dynamic> payload) async {
    final db = await RunFuelDatabase.instance.database;
    final garmin = payload['garmin'];
    if (garmin is Map && garmin['status'] == 'ok') {
      final discovered = <String, Map>{};
      _collectActivities(garmin, 'general_fitness', discovered);
      final batch = db.batch();
      for (final item in discovered.values) {
        final rawStart = _findString(item, const ['startTime', 'start_time', 'startTimestampLocal', 'startTimeLocal']);
        final startedAt = _normaliseStartTime(rawStart);
        if (startedAt == null) continue;
        final distance = _findNumber(item, const ['distanceMeters', 'distance_m', 'distance']);
        final duration = _findNumber(item, const ['durationSeconds', 'duration_s', 'movingDuration', 'elapsedDuration']);
        final sport = _sportFor(item['sport'] ?? item['activityType'] ?? item['activity_type'] ??
            item['type'] ?? item['activityName'] ?? item['_sport']);
        if (sport == null) continue;
        final sourceId = _findString(item, const ['activityId', 'activity_id', 'id']);
        final id = sourceId != null && sourceId.isNotEmpty
            ? 'garmin_$sourceId'
            : 'garmin_${sport}_${startedAt}_${distance ?? 0}_${duration ?? 0}';
        final pace = sport == 'running' && distance != null && distance > 0 && duration != null
            ? duration / (distance / 1000) : null;
        batch.insert('activities', {
          'id': id, 'started_at': startedAt, 'sport': sport,
          'distance_m': distance, 'duration_s': duration,
          'avg_hr': _findNumber(item, const ['averageHR', 'average_hr_bpm', 'averageHeartRate']),
          'avg_pace_s_per_km': pace,
          'source_updated_at': DateTime.now().toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }

    // Garmin sleep is persisted independently from activities so it builds a
    // real nightly history across repeated daily syncs.
    final garminHealth = garmin is Map ? garmin['health'] : null;
    if (garminHealth is Map && garminHealth['status'] == 'ok') {
      final sleep = garminHealth['sleep'];
      final day = payload['date']?.toString();
      final sleepDay = sleep is Map
          ? (_findString(sleep, const ['calendarDate', 'sleepDate', 'date']) ?? day)
          : day;
      if (sleep is Map && sleepDay != null && DateTime.tryParse(sleepDay) != null) {
        final total = _findNumber(sleep, const [
          'sleepTimeSeconds', 'totalSleepSeconds', 'totalSleepDurationSeconds',
          'totalSleepS', 'sleepDurationSeconds',
        ]);
        final deep = _findNumber(sleep, const [
          'deepSleepSeconds', 'deepSleepDurationSeconds', 'deepSleepS',
        ]);
        final light = _findNumber(sleep, const [
          'lightSleepSeconds', 'lightSleepDurationSeconds', 'lightSleepS',
        ]);
        final rem = _findNumber(sleep, const [
          'remSleepSeconds', 'remSleepDurationSeconds', 'remSleepS',
        ]);
        final awake = _findNumber(sleep, const [
          'awakeSleepSeconds', 'awakeSeconds', 'awakeDurationSeconds',
        ]);
        final score = _findNumber(sleep, const [
          'overallSleepScore', 'sleepScore', 'overallScore', 'overall',
        ]);
        // Do not create an empty/zero night when Garmin did not return sleep.
        if (total != null || deep != null || light != null || rem != null || score != null) {
          await db.insert('sleep_records', {
            'sleep_date': sleepDay,
            'sleep_start': _findString(sleep, const [
              'sleepStartTimestampLocal', 'sleepStartTimeLocal', 'sleepStart',
            ]),
            'sleep_end': _findString(sleep, const [
              'sleepEndTimestampLocal', 'sleepEndTimeLocal', 'sleepEnd',
            ]),
            'total_sleep_s': total,
            'deep_sleep_s': deep,
            'light_sleep_s': light,
            'rem_sleep_s': rem,
            'awake_s': awake,
            'sleep_score': score,
            'source_updated_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      final daily = garminHealth['daily_summary'];
      final hrv = garminHealth['hrv'];
      if (day != null && DateTime.tryParse(day) != null) {
        await _persistRecoveryMetric(db, day, 'resting_hr_bpm', 'bpm',
            daily, const ['restingHeartRate', 'restingHr', 'restingHeartRateInBeatsPerMinute']);
        await _persistRecoveryMetric(db, day, 'body_battery', 'score',
            daily, const ['bodyBatteryMostRecentValue', 'bodyBattery']);
        await _persistRecoveryMetric(db, day, 'stress_level', 'score',
            daily, const ['averageStressLevel', 'avgStressLevel']);
        await _persistRecoveryMetric(db, day, 'hrv_ms', 'ms',
            hrv, const ['lastNightAvg', 'lastNightAverage', 'hrvValue']);
        await _persistRecoveryMetric(db, day, 'active_calories', 'kcal',
            daily, const ['activeKilocalories', 'activeCalories', 'activeCalorieBurned', 'activeCaloriesBurned']);
        await _persistRecoveryMetric(db, day, 'resting_calories', 'kcal',
            daily, const ['restingKilocalories', 'restingCalories', 'restingCalorieBurned']);
        await _persistRecoveryMetric(db, day, 'bmr_calories', 'kcal',
            daily, const ['basalMetabolicCalories', 'basalMetabolicRateCalories', 'bmrCalories', 'basalCalories']);
        await _persistRecoveryMetric(db, day, 'total_calories_burned', 'kcal',
            daily, const ['totalKilocalories', 'totalCaloriesBurned', 'totalCalories', 'totalCalorieBurned']);
        await _persistRecoveryMetric(db, day, 'weight_kg', 'kg',
            daily, const ['weightKg', 'weightInKilograms', 'weight']);
      }
    }

    final mfp = payload['myfitnesspal'];
    if (mfp is Map && mfp['status'] == 'ok') {
      final nutrition = mfp['nutrition'];
      if (nutrition is Map) {
        final history = <Map>[];
        final totals = nutrition['totals'];
        if (totals is Map) history.add({'day': nutrition['day'] ?? payload['date'], 'totals': totals});
        for (final key in const ['days', 'daily', 'history', 'daily_summaries', 'entries']) {
          final value = nutrition[key];
          if (value is List) history.addAll(value.whereType<Map>());
        }
        for (final entry in history) {
          final day = (entry['day'] ?? entry['date'] ?? entry['calendarDate'])?.toString();
          final dayTotals = entry['totals'] is Map ? entry['totals'] as Map : entry;
          if (day == null || day.length != 10 || DateTime.tryParse(day) == null) continue;
          await db.insert('nutrition_days', {
            'day': day,
            'calories': _findNumber(dayTotals, const ['calories', 'calorie']),
            'protein_g': _findNumber(dayTotals, const ['protein', 'protein_g']),
            'carbs_g': _findNumber(dayTotals, const ['carbohydrates', 'carbs', 'carbs_g']),
            'fat_g': _findNumber(dayTotals, const ['fat', 'fat_g']),
            'fibre_g': _findNumber(dayTotals, const ['fiber', 'fibre', 'fibre_g']),
            'source_updated_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }

    await matchPlannedWorkouts();
  }

  void _collectActivities(dynamic node, String inheritedSport, Map<String, Map> found) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final sport = key.contains('running') ? 'running'
            : key.contains('cycling') || key.contains('biking') ? 'cycling'
            : key.contains('swimming') ? 'swimming'
            : key.contains('strength') || key.contains('weight') ? 'strength'
            : key.contains('walking') || key.contains('hiking') ? 'walking_hiking'
            : inheritedSport;
        if (key == 'activities' && entry.value is List) {
          for (final raw in entry.value as List) {
            if (raw is! Map) {
              continue;
            }
            final item = Map<String, dynamic>.from(raw);
            item['_sport'] ??= sport;
            final id = _findString(item, const ['activityId', 'activity_id', 'id']) ??
                '${item['start_time'] ?? item['startTime']}_${item['distance_m'] ?? item['distanceMeters']}';
            found[id] = item;
          }
        } else {
          _collectActivities(entry.value, sport, found);
        }
      }
    } else if (node is List) {
      for (final value in node) {
        _collectActivities(value, inheritedSport, found);
      }
    }
  }

  String? _sportFor(dynamic raw) {
    if (raw is Map) {
      raw = raw['sportTypeKey'] ?? raw['typeKey'] ?? raw['sportType'] ??
          raw['activityType'] ?? raw['type'] ?? raw['name'] ?? raw['key'];
    }
    final value = (raw ?? '').toString().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (value.contains('run') || value.contains('treadmill')) return 'running';
    if (value.contains('cycl') || value.contains('bike') || value.contains('bmx')) return 'cycling';
    if (value.contains('swim')) return 'swimming';
    if (value.contains('strength') || value.contains('weight') || value.contains('gym')) return 'strength';
    if (value.contains('triathlon') || value.contains('multisport')) return 'triathlon';
    if (value.contains('walk') || value.contains('hike')) return 'walking_hiking';
    if (value.contains('yoga') || value.contains('pilates') || value.contains('mobility')) return 'mobility';
    if (value.contains('team') || value.contains('soccer') || value.contains('football') || value.contains('basketball')) return 'team_sports';
    if (value.contains('fitness') || value.contains('cardio') || value.contains('elliptical')) return 'general_fitness';
    return null;
  }

  String? _normaliseStartTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toIso8601String();
    final date = raw.length >= 10 ? raw.substring(0, 10) : '';
    if (date.length != 10 || DateTime.tryParse(date) == null) return null;
    return date;
  }

  /// Links a completed run only when date/time and workout targets agree.
  /// Close or ambiguous candidates are deliberately left for user review.
  Future<void> matchPlannedWorkouts() async {
    final db = await RunFuelDatabase.instance.database;
    final planned = await db.query(
      'planned_workouts',
      where: "status IN ('planned', 'needs_review') AND completed_activity_id IS NULL",
      orderBy: 'scheduled_at ASC',
    );
    final activities = await db.query(
      'activities',
      where: "sport = 'running'",
      orderBy: 'started_at DESC',
      limit: 100,
    );

    for (final workout in planned) {
      final scheduledAt = DateTime.tryParse(workout['scheduled_at']?.toString() ?? '');
      if (scheduledAt == null) continue;

      final candidates = <({Map<String, Object?> activity, double score})>[];
      for (final activity in activities) {
        final activityId = activity['id']?.toString();
        if (activityId == null) continue;
        final alreadyMatched = await db.query(
          'workout_matches',
          columns: ['id'],
          where: 'activity_id = ?',
          whereArgs: [activityId],
          limit: 1,
        );
        if (alreadyMatched.isNotEmpty) continue;

        final startedAt = DateTime.tryParse(activity['started_at']?.toString() ?? '');
        if (startedAt == null) continue;
        final score = _matchScore(workout, activity, scheduledAt, startedAt);
        if (score >= 0.55) candidates.add((activity: activity, score: score));
      }

      candidates.sort((a, b) => b.score.compareTo(a.score));
      if (candidates.isEmpty) continue;

      final best = candidates.first;
      final secondScore = candidates.length > 1 ? candidates[1].score : 0.0;
      final unambiguous = best.score >= 0.72 && best.score - secondScore >= 0.12;
      final now = DateTime.now().toUtc().toIso8601String();
      await db.transaction((txn) async {
        await txn.insert(
          'workout_matches',
          {
            'planned_workout_id': workout['id'],
            'activity_id': best.activity['id'],
            'confidence': best.score,
            'match_method': 'time_distance_duration',
            'reviewed': unambiguous ? 1 : 0,
            'matched_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (unambiguous) {
          await txn.update(
            'planned_workouts',
            {
              'status': 'completed',
              'completed_activity_id': best.activity['id'],
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [workout['id']],
          );
        } else {
          await txn.update(
            'planned_workouts',
            {'status': 'needs_review', 'updated_at': now},
            where: 'id = ?',
            whereArgs: [workout['id']],
          );
        }
      });
    }
  }

  double _matchScore(
    Map<String, Object?> workout,
    Map<String, Object?> activity,
    DateTime scheduledAt,
    DateTime startedAt,
  ) {
    final hasTarget = _number(workout['target_distance_m']) != null ||
        _number(workout['target_duration_s']) != null;
    if (!hasTarget) return 0;

    final hours = startedAt.difference(scheduledAt).inMinutes.abs() / 60;
    if (hours > 36) return 0;

    final timeScore = hours <= 3
        ? 0.45
        : hours <= 8
            ? 0.40
            : hours <= 16
                ? 0.30
                : hours <= 24
                    ? 0.20
                    : 0.10;
    var score = timeScore;
    var availableWeight = 0.45;

    final targetDistance = _number(workout['target_distance_m']);
    final actualDistance = _number(activity['distance_m']);
    if (targetDistance != null && targetDistance > 0 &&
        actualDistance != null && actualDistance > 0) {
      final difference = (actualDistance - targetDistance).abs() / targetDistance;
      score += difference <= 0.15 ? 0.35 : difference <= 0.30 ? 0.27 : difference <= 0.50 ? 0.15 : 0;
      availableWeight += 0.35;
    }

    final targetDuration = _number(workout['target_duration_s']);
    final actualDuration = _number(activity['duration_s']);
    if (targetDuration != null && targetDuration > 0 &&
        actualDuration != null && actualDuration > 0) {
      final difference = (actualDuration - targetDuration).abs() / targetDuration;
      score += difference <= 0.20 ? 0.20 : difference <= 0.35 ? 0.14 : difference <= 0.50 ? 0.07 : 0;
      availableWeight += 0.20;
    }

    return score / availableWeight;
  }

  Future<void> _persistRecoveryMetric(
    Database db,
    String day,
    String metric,
    String unit,
    dynamic source,
    List<String> aliases,
  ) async {
    if (source is! Map) return;
    final value = _findNumber(source, aliases);
    if (value == null) return;
    await db.insert('health_measurements', {
      'id': '${metric}_$day',
      'measured_at': day,
      'category': 'recovery',
      'metric': metric,
      'value': value,
      'unit': unit,
      'source': 'garmin',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  double? _findNumber(dynamic source, List<String> aliases) {
    final wanted = aliases.map(_normaliseKey).toSet();
    if (source is Map) {
      for (final entry in source.entries) {
        if (wanted.contains(_normaliseKey(entry.key))) {
          final raw = entry.value;
          if (raw is num) return raw.toDouble();
          if (raw is Map && raw['value'] is num) {
            return (raw['value'] as num).toDouble();
          }
          final parsed = raw is String ? double.tryParse(raw) : null;
          if (parsed != null) return parsed;
        }
      }
      for (final value in source.values) {
        final found = _findNumber(value, aliases);
        if (found != null) return found;
      }
    } else if (source is List) {
      for (final value in source) {
        final found = _findNumber(value, aliases);
        if (found != null) return found;
      }
    }
    return null;
  }

  String? _findString(dynamic source, List<String> aliases) {
    final wanted = aliases.map(_normaliseKey).toSet();
    if (source is Map) {
      for (final entry in source.entries) {
        if (wanted.contains(_normaliseKey(entry.key)) && entry.value != null) {
          return entry.value.toString();
        }
      }
      for (final value in source.values) {
        final found = _findString(value, aliases);
        if (found != null) return found;
      }
    } else if (source is List) {
      for (final value in source) {
        final found = _findString(value, aliases);
        if (found != null) return found;
      }
    }
    return null;
  }

  String _normaliseKey(dynamic key) =>
      key.toString().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

  double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return null;
  }
}
