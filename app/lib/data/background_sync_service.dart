import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'mobile_connection_service.dart';
import 'runfuel_database.dart';
import 'training_data_service.dart';

/// Schedules conservative, read-only refreshes of recent Garmin/MFP history.
/// Android controls the exact execution time and may defer work for battery.
class RunFuelBackgroundSyncService {
  RunFuelBackgroundSyncService._();

  static const taskName = 'runfuel_recent_history_sync';
  static const uniqueName = 'runfuel_recent_history_sync_v1';

  static Future<void> initialize() async {
    await Workmanager().initialize(
      runFuelBackgroundDispatcher,
    );
    await Workmanager().registerPeriodicTask(
      uniqueName,
      taskName,
      frequency: const Duration(hours: 12),
      initialDelay: const Duration(minutes: 5),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}

@pragma('vm:entry-point')
void runFuelBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    if (task != RunFuelBackgroundSyncService.taskName) return true;

    try {
      await RunFuelDatabase.instance.initialize();
      final connection = MobileConnectionService();
      if (!await connection.isAuthorized()) return true;

      // Refresh the most recent seven calendar days. This includes recent
      // history for charts/coaching without repeatedly crawling the full
      // account history or creating excessive provider requests.
      final today = DateTime.now();
      final firstDay = DateTime(today.year, today.month, today.day)
          .subtract(const Duration(days: 6));
      for (var offset = 0; offset < 7; offset++) {
        final day = firstDay.add(Duration(days: offset));
        final payload = await connection.sync(date: day);
        await TrainingDataService.instance.persistSyncPayload(payload);
      }
      return true;
    } catch (_) {
      // WorkManager retries on a later opportunity; never surface a crash
      // from a background refresh into the foreground app.
      return false;
    }
  });
}
