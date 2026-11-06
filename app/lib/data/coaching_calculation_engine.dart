import 'dart:convert';

/// Deterministic calculations supplied to AI coaches as verified facts.
/// The model interprets these values; it must not be responsible for arithmetic.
class CoachingCalculationEngine {
  const CoachingCalculationEngine();

  static String? paceDisplay(num secondsPerKm) {
    if (!secondsPerKm.isFinite || secondsPerKm < 120 || secondsPerKm > 1800) {
      return null;
    }
    final total = secondsPerKm.round();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}/km';
  }

  static String? durationDisplay(num seconds) {
    if (!seconds.isFinite || seconds < 0) return null;
    final total = seconds.round();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final remainder = total % 60;
    if (hours > 0) {
      return '${hours.toString()}h ${minutes.toString().padLeft(2, '0')}m';
    }
    return '${minutes}m ${remainder.toString().padLeft(2, '0')}s';
  }

  static double? _number(dynamic value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  static double? bmrMifflinStJeor({
    required num? weightKg,
    required num? heightCm,
    required int? ageYears,
    required String? sex,
  }) {
    if (weightKg == null || heightCm == null || ageYears == null ||
        !weightKg.isFinite || !heightCm.isFinite ||
        weightKg <= 0 || heightCm <= 0 || ageYears <= 0) {
      return null;
    }
    final normalizedSex = (sex ?? '').trim().toLowerCase();
    final sexAdjustment = normalizedSex == 'male'
        ? 5.0
        : normalizedSex == 'female'
            ? -161.0
            : null;
    if (sexAdjustment == null) {
      return null;
    }
    return 10 * weightKg + 6.25 * heightCm - 5 * ageYears + sexAdjustment;
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  /// Summarises comparable weekly training and recovery evidence without
  /// converting wearable values or app targets into pass/fail thresholds.
  static Map<String, dynamic> weeklyCoachingEvidence(
    Map<String, dynamic> context,
  ) {
    final comparison = context['weekly_progress_comparison'];
    final comparisonMap = comparison is Map
        ? Map<String, dynamic>.from(comparison)
        : const <String, dynamic>{};
    final current = comparisonMap['current'] is Map
        ? Map<String, dynamic>.from(comparisonMap['current'] as Map)
        : const <String, dynamic>{};
    final previous = comparisonMap['previous'] is Map
        ? Map<String, dynamic>.from(comparisonMap['previous'] as Map)
        : const <String, dynamic>{};
    final currentKm = _number(current['distance_km']);
    final previousKm = _number(previous['distance_km']);
    final volumeChange = currentKm != null && previousKm != null && previousKm > 0
        ? ((currentKm - previousKm) / previousKm) * 100
        : null;

    final now = DateTime.now();
    final recentStart = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final baselineStart = recentStart.subtract(const Duration(days: 23));
    final measurements = (context['recovery_measurements'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final recoveryTrends = <String, dynamic>{};
    final metricNames = measurements
        .map((row) => row['metric']?.toString().trim().toLowerCase() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();
    for (final metric in metricNames) {
      final rows = measurements.where((row) =>
          (row['metric']?.toString().trim().toLowerCase() ?? '') == metric);
      final recent = <double>[];
      final baseline = <double>[];
      for (final row in rows) {
        final date = DateTime.tryParse(row['measured_at']?.toString() ?? '');
        final value = _number(row['value']);
        if (date == null || value == null) continue;
        if (!date.isBefore(recentStart)) {
          recent.add(value);
        } else if (!date.isBefore(baselineStart) && date.isBefore(recentStart)) {
          baseline.add(value);
        }
      }
      final recentMedian = _median(recent);
      // A personal comparison baseline needs several observations; a
      // single older reading must not be presented as a meaningful trend.
      final baselineMedian = baseline.length >= 3 ? _median(baseline) : null;
      if (recentMedian == null) continue;
      recoveryTrends[metric] = {
        'recent_7_day_median': double.parse(recentMedian.toStringAsFixed(1)),
        'recent_readings': recent.length,
        if (baselineMedian != null)
          'preceding_23_day_median': double.parse(baselineMedian.toStringAsFixed(1)),
        if (baselineMedian != null)
          'difference_from_personal_recent_baseline':
              double.parse((recentMedian - baselineMedian).toStringAsFixed(1)),
        'unit': rows.first['unit'],
      }..removeWhere((key, value) => value == null);
    }

    final reviews = (context['daily_reviews_and_user_feedback'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final reviewNotes = reviews
        .map((row) => row['notes']?.toString().trim() ?? '')
        .where((note) => note.isNotEmpty)
        .toList();

    return {
      'weekly_running_comparison': {
        'current_7_day_running_km': currentKm,
        'previous_7_day_running_km': previousKm,
        if (volumeChange != null)
          'running_distance_change_percent':
              double.parse(volumeChange.toStringAsFixed(1)),
        'current_run_count': current['running_count'],
        'previous_run_count': previous['running_count'],
        'current_longest_run_km': current['longest_run_km'],
        'previous_longest_run_km': previous['longest_run_km'],
        'current_average_pace_seconds_per_km':
            current['average_pace_seconds_per_km'],
        'previous_average_pace_seconds_per_km':
            previous['average_pace_seconds_per_km'],
      }..removeWhere((key, value) => value == null),
      'recovery_trends': recoveryTrends,
      'subjective_review_count': reviews.length,
      'subjective_notes_available': reviewNotes.isNotEmpty,
      if (reviewNotes.isNotEmpty) 'subjective_notes': reviewNotes,
      'decision_guidance': [
        'Choose progress, consolidate or step_back from the combined evidence, not one metric.',
        'Progress only when the current workload has been completed comfortably, effort is appropriate, and there are no meaningful pain or illness concerns.',
        'Consolidate when the workload is manageable but evidence is mixed, incomplete or a recent increase has not yet been absorbed.',
        'Step back when multiple signals point to poor recovery or when pain, altered gait, or illness symptoms warrant stopping or modifying training.',
        'Do not require exact resting-heart-rate, HRV, Body Battery, calorie or carbohydrate values before progression.',
        'Do not apply a universal percentage progression rule. Consider recent training history, longest session, frequency, effort, subjective recovery and goals.',
        'Wearable trends are supporting evidence, not diagnoses or direct measures of tissue recovery.',
      ],
    };
  }

  Map<String, dynamic> enrich(Map<String, dynamic> context) {
    final result = Map<String, dynamic>.from(context);
    final activities = (context['activities'] as List? ?? const [])
        .whereType<Map>()
        .map((row) {
          final distanceM = _number(row['distance_m']);
          final durationS = _number(row['duration_s']);
          final recordedPace = _number(row['avg_pace_s_per_km']);
          final distanceKm = distanceM == null ? null : distanceM / 1000;
          final derivedPace = distanceKm != null &&
                  distanceKm > 0 &&
                  durationS != null &&
                  durationS > 0
              ? durationS / distanceKm
              : null;
          return <String, dynamic>{
            'date': row['started_at'],
            'sport': row['sport'],
            'distance_km': distanceKm == null
                ? null
                : double.parse(distanceKm.toStringAsFixed(2)),
            'duration_seconds': durationS,
            'duration_display':
                durationS == null ? null : durationDisplay(durationS),
            'recorded_pace_seconds_per_km': recordedPace,
            'recorded_pace_display':
                recordedPace == null ? null : paceDisplay(recordedPace),
            'duration_distance_derived_pace_seconds_per_km': derivedPace,
            'duration_distance_derived_pace_display':
                derivedPace == null ? null : paceDisplay(derivedPace),
            'average_heart_rate_bpm': _number(row['avg_hr']),
          }..removeWhere((key, value) => value == null);
        })
        .toList();

    final nutritionDays = (context['nutrition_days'] as List? ?? const [])
        .whereType<Map>()
        .map((row) {
          final calories = _number(row['calories']);
          final protein = _number(row['protein_g']);
          final carbs = _number(row['carbs_g']);
          final fat = _number(row['fat_g']);
          final macrosComplete =
              protein != null && carbs != null && fat != null;
          final macroCalories = macrosComplete
              ? protein * 4 + carbs * 4 + fat * 9
              : null;
          return <String, dynamic>{
            'date': row['day'],
            'reported_calories': calories,
            'protein_g': protein,
            'carbohydrates_g': carbs,
            'fat_g': fat,
            'fibre_g': _number(row['fibre_g']),
            'calories_from_supplied_macros': macroCalories,
            'reported_minus_macro_calories':
                calories != null && macroCalories != null
                    ? calories - macroCalories
                    : null,
          }..removeWhere((key, value) => value == null);
        })
        .toList();

    final profile = context['athlete_profile'];
    final profileMap = profile is Map ? profile : const <String, dynamic>{};
    final bmr = bmrMifflinStJeor(
      weightKg: _number(profileMap['weight_kg']),
      heightCm: _number(profileMap['height_cm']),
      ageYears: profileMap['age_years'] is num
          ? (profileMap['age_years'] as num).toInt()
          : null,
      sex: profileMap['sex']?.toString(),
    );
    final selectedNutrition = context['selected_day_nutrition'];
    final selectedNutritionMap = selectedNutrition is Map
        ? selectedNutrition
        : const <String, dynamic>{};
    final totals = selectedNutritionMap['totals'] is Map
        ? selectedNutritionMap['totals'] as Map
        : const <String, dynamic>{};
    final goals = selectedNutritionMap['goals'] is Map
        ? selectedNutritionMap['goals'] as Map
        : const <String, dynamic>{};
    const macroFields = <String, List<String>>{
      'calories': ['calories', 'calorie'],
      'protein': ['protein', 'protein_g'],
      'carbohydrates': ['carbohydrates', 'carbs', 'carbs_g'],
      'fat': ['fat', 'fat_g'],
      'fibre': ['fibre', 'fiber', 'fibre_g'],
    };
    final macroComparisons = <String, dynamic>{};
    for (final entry in macroFields.entries) {
      final intake = _firstNumber(totals, entry.value);
      final target = _firstNumber(goals, entry.value);
      if (intake == null || target == null || target <= 0) {
        macroComparisons[entry.key] = {
          'intake': intake,
          'target': target,
          'status': 'comparison_unavailable',
        }..removeWhere((key, value) => value == null);
        continue;
      }
      final difference = target - intake;
      macroComparisons[entry.key] = {
        'intake': intake,
        'target': target,
        'remaining_to_target': difference > 0 ? difference : 0,
        'over_target_by': difference < 0 ? -difference : 0,
        'remaining_to_target_display':
            (difference > 0 ? difference : 0).toStringAsFixed(1),
        'over_target_by_display':
            (difference < 0 ? -difference : 0).toStringAsFixed(1),
        'status': difference > 0 ? 'below_target' : difference < 0 ? 'above_target' : 'at_target',
      };
    }

    result['weekly_coaching_evidence'] = weeklyCoachingEvidence(context);

    result['verified_calculations'] = {
      'nutrition_goal_comparisons': macroComparisons,
      'calculation_note':
          'These values are deterministic calculations from supplied local records. BMR is a formula estimate, not total daily energy expenditure or a mandatory minimum intake.',
      'activity_calculations': activities,
      'nutrition_calculations': nutritionDays,
      if (bmr != null) 'mifflin_st_jeor_bmr_kcal_per_day': bmr.round(),
    };
    return result;
  }

  static double? _firstNumber(Map source, List<String> aliases) {
    for (final alias in aliases) {
      final value = source[alias];
      if (value is num && value.isFinite) return value.toDouble();
    }
    return null;
  }

  String encodeForCoach(Map<String, dynamic> context) =>
      const JsonEncoder.withIndent('  ').convert(enrich(context));
}
