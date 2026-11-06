import 'package:flutter_test/flutter_test.dart';
import 'package:runfuel/data/coaching_calculation_engine.dart';

void main() {
  const engine = CoachingCalculationEngine();

  test('converts Garmin seconds per kilometre into mm:ss/km', () {
    expect(CoachingCalculationEngine.paceDisplay(480.66), '8:01/km');
    expect(CoachingCalculationEngine.paceDisplay(478.87), '7:59/km');
    expect(CoachingCalculationEngine.paceDisplay(495), '8:15/km');
    expect(CoachingCalculationEngine.paceDisplay(0), isNull);
  });

  test('calculates BMR only when complete profile data is supplied', () {
    expect(
      CoachingCalculationEngine.bmrMifflinStJeor(
        weightKg: 90,
        heightCm: 184,
        ageYears: 37,
        sex: 'male',
      ),
      1870,
    );
    expect(
      CoachingCalculationEngine.bmrMifflinStJeor(
        weightKg: 90,
        heightCm: null,
        ageYears: 37,
        sex: 'male',
      ),
      isNull,
    );
  });

  test('calculates activity duration and pace without changing source data', () {
    final source = <String, dynamic>{
      'activities': [
        {
          'started_at': '2026-11-03',
          'sport': 'running',
          'distance_m': 2000,
          'duration_s': 961.32,
          'avg_pace_s_per_km': 480.66,
          'avg_hr': 148,
        }
      ],
      'nutrition_days': <Map<String, dynamic>>[],
    };
    final enriched = engine.enrich(source);
    final activity = (enriched['verified_calculations']
        as Map<String, dynamic>)['activity_calculations'] as List;
    expect(activity.single['recorded_pace_display'], '8:01/km');
    expect(activity.single['duration_display'], '16m 01s');
    expect(activity.single['distance_km'], 2.0);
    expect(source.containsKey('verified_calculations'), isFalse);
  });

  test('builds weekly coaching evidence without fixed wearable gates', () {
    final now = DateTime.now();
    final recent = now.subtract(const Duration(days: 1)).toIso8601String();
    final older = now.subtract(const Duration(days: 12)).toIso8601String();
    final evidence = CoachingCalculationEngine.weeklyCoachingEvidence({
      'weekly_progress_comparison': {
        'current': {
          'distance_km': 18.9,
          'running_count': 4,
          'longest_run_km': 5.9,
          'average_pace_seconds_per_km': 480,
        },
        'previous': {
          'distance_km': 14.3,
          'running_count': 6,
          'longest_run_km': 3.3,
          'average_pace_seconds_per_km': 500,
        },
      },
      'recovery_measurements': [
        {'measured_at': recent, 'metric': 'resting_hr', 'value': 62, 'unit': 'bpm'},
        {'measured_at': older, 'metric': 'resting_hr', 'value': 58, 'unit': 'bpm'},
        {'measured_at': now.subtract(const Duration(days: 14)).toIso8601String(), 'metric': 'resting_hr', 'value': 59, 'unit': 'bpm'},
        {'measured_at': now.subtract(const Duration(days: 18)).toIso8601String(), 'metric': 'resting_hr', 'value': 57, 'unit': 'bpm'},
        {'measured_at': now.subtract(const Duration(days: 2)).toIso8601String(), 'metric': 'resting_hr', 'value': 60, 'unit': 'bpm'},
      ],
      'daily_reviews_and_user_feedback': [
        {'review_date': recent.substring(0, 10), 'energy': 3, 'soreness': 2, 'notes': 'Legs felt okay'},
      ],
    });

    final running = evidence['weekly_running_comparison'] as Map;
    expect(running['current_7_day_running_km'], 18.9);
    expect(running['previous_7_day_running_km'], 14.3);
    expect(running['running_distance_change_percent'], closeTo(32.2, 0.2));
    final trends = evidence['recovery_trends'] as Map;
    expect((trends['resting_hr'] as Map)['recent_7_day_median'], 61.0);
    expect((trends['resting_hr'] as Map)['preceding_23_day_median'], 58.0);
    expect(evidence['decision_guidance'], isA<List<String>>());
    expect(evidence['subjective_notes_available'], isTrue);
  });

  test('provides rounded macro differences for accurate coaching tables', () {
    final enriched = engine.enrich({
      'activities': <Map<String, dynamic>>[],
      'nutrition_days': <Map<String, dynamic>>[],
      'selected_day_nutrition': {
        'totals': {'fat': 75.5},
        'goals': {'fat': 69.3},
      },
    });
    final verified = enriched['verified_calculations'] as Map<String, dynamic>;
    final macros = verified['nutrition_goal_comparisons'] as Map<String, dynamic>;
    final fat = macros['fat'] as Map<String, dynamic>;
    expect(fat['over_target_by'], closeTo(6.2, 0.000001));
    expect(fat['over_target_by_display'], '6.2');
    expect(fat['remaining_to_target_display'], '0.0');
  });

  test('calculates macro calories and leaves missing values missing', () {
    final enriched = engine.enrich({
      'activities': <Map<String, dynamic>>[],
      'nutrition_days': [
        {
          'day': '2026-11-03',
          'calories': 1600,
          'protein_g': 125,
          'carbs_g': 110,
          'fat_g': 48,
          'fibre_g': null,
        },
        {
          'day': '2026-11-02',
          'calories': 1700,
          'protein_g': 100,
          'carbs_g': 150,
          'fat_g': null,
        }
      ],
    });
    final days = (enriched['verified_calculations']
        as Map<String, dynamic>)['nutrition_calculations'] as List;
    expect(days[0]['calories_from_supplied_macros'], 1372);
    expect(days[0]['reported_minus_macro_calories'], 228);
    expect(days[0].containsKey('fibre_g'), isFalse);
    expect(days[1].containsKey('calories_from_supplied_macros'), isFalse);
  });
}
