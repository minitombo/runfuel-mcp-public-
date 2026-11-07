import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'data/runfuel_database.dart';
import 'data/number_formatting.dart';
import 'data/planned_workouts_panel.dart';
import 'data/training_data_service.dart';
import 'data/backend_health_service.dart';
import 'data/mobile_connection_service.dart';
import 'data/sleep_recovery_panel.dart';
import 'data/runfuel_dashboard_page.dart';
import 'data/training_nutrition_insights_panel.dart';
import 'data/training_lifecycle_panel.dart';
import 'data/background_sync_service.dart';
import 'data/gemini_coach_service.dart';
import 'data/coaching_calculation_engine.dart';
import 'package:flutter/material.dart';
import 'coaching_report_card.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class RunFuelAppearance {
  static const preferenceKey = 'runfuel_appearance_v1';
  static final ValueNotifier<String> choice = ValueNotifier<String>('system');

  static const options = <String, String>{
    'system': 'System Default',
    'light': 'Light',
    'dark': 'Dark',
    'blue': 'Soft blue',
    'sage': 'Sage green',
    'pink': 'Soft pink',
    'lavender': 'Lavender',
    'neutral': 'Warm neutral',
    'yellow': 'Soft yellow',
  };

  static Color seed(String value) => switch (value) {
    'blue' => const Color(0xFF789BB8),
    'sage' => const Color(0xFF789985),
    'pink' => const Color(0xFFC58D9E),
    'lavender' => const Color(0xFF9A8DB8),
    'neutral' => const Color(0xFFAA947D),
    'yellow' => const Color(0xFFD3B34A),
    _ => const Color(0xFF78A95A),
  };

  static ThemeData theme(String value, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed(value),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardColor: scheme.surfaceContainer,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primary.withValues(alpha: .16),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

Future<void> _removeRetiredGemmaDownloads() async {
  try {
    final directory = await getApplicationSupportDirectory();
    const retiredFiles = [
      'gemma-4-E2B-it-qat-mobile-Q2_K_XL.gguf',
      'gemma-4-E4B-it-qat-mobile-Q2_K_XL.gguf',
      'gemma-4-E2B-it-qat-mobile-Q2_K_XL.gguf.download',
      'gemma-4-E4B-it-qat-mobile-Q2_K_XL.gguf.download',
    ];
    for (final name in retiredFiles) {
      final file = File('${directory.path}/$name');
      if (await file.exists()) await file.delete();
    }
  } catch (_) {
    // Removing retired model files is best-effort and must not block startup.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  RunFuelAppearance.choice.value =
      prefs.getString(RunFuelAppearance.preferenceKey) ?? 'system';
  await RunFuelDatabase.instance.initialize();
  unawaited(_removeRetiredGemmaDownloads());
  try {
    await RunFuelBackgroundSyncService.initialize();
  } catch (_) {
    // Background history refresh is best-effort; manual sync remains available.
  }
  runApp(const RunFuelApp());
}

class RunFuelApp extends StatelessWidget {
  const RunFuelApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: RunFuelAppearance.choice,
    builder: (context, choice, _) => MaterialApp(
      title: 'RunFuel',
      debugShowCheckedModeBanner: false,
      theme: RunFuelAppearance.theme(choice, Brightness.light),
      darkTheme: RunFuelAppearance.theme(choice, Brightness.dark),
      themeMode: choice == 'system'
        ? ThemeMode.system
        : choice == 'dark' ? ThemeMode.dark : ThemeMode.light,
      home: const RunFuelShell(),
    ),
  );
}

class RunFuelShell extends StatefulWidget {
  const RunFuelShell({super.key});

  @override
  State<RunFuelShell> createState() => _RunFuelShellState();
}

class _RunFuelShellState extends State<RunFuelShell> {
  static const _syncCacheKey = 'runfuel_last_sync_v1';
  int _index = 0;
  final PageController _pageController = PageController();
  Map<String, dynamic>? _syncData;
  bool _syncing = false;
  String? _syncError;
  DateTime _selectedDate = DateTime.now();
  int _reportingDays = 7;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreAndSyncOnLaunch());
  }

  Future<void> _restoreAndSyncOnLaunch() async {
    await _loadLastSync();
    await _syncOnLaunch();
  }

  Future<void> _syncOnLaunch() async {
    // Refresh the current local calendar day whenever the app is opened.
    // Keep startup quiet: cached data remains available if the network fails.
    if (!await MobileConnectionService().isAuthorized() || _syncing) return;
    if (mounted) setState(() { _syncing = true; _syncError = null; });
    try {
      final today = DateTime.now();
      final currentDay = DateTime(today.year, today.month, today.day);
      final data = await MobileConnectionService().sync(date: currentDay);
      await TrainingDataService.instance.persistSyncPayload(data);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_syncCacheKey, jsonEncode(data));
      if (mounted) {
        setState(() {
          _selectedDate = currentDay;
          _syncData = data;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _syncError = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_syncCacheKey);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedDay = DateTime.tryParse(data['date']?.toString() ?? '');
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final cacheIsForToday = cachedDay != null &&
          cachedDay.year == today.year &&
          cachedDay.month == today.month &&
          cachedDay.day == today.day;
      if (mounted) {
        setState(() {
          // Only show the cached payload when it belongs to today. Never
          // relabel a historical payload as today's data.
          _syncData = cacheIsForToday ? data : null;
          _selectedDate = today;
        });
      }
    } catch (_) {
      await prefs.remove(_syncCacheKey);
    }
  }

  final _titles = const [
    'RunFuel',
    'Training',
    'AI Coach',
    'Nutrition',
    'Dashboard',
    'Health profile',
    'Settings',
  ];

  Future<void> _manualSync() async {
    if (_syncing) return;
    final authorised = await MobileConnectionService().isAuthorized();
    if (!authorised) {
      if (!mounted) return;
      setState(() => _index = 6);
      _pageController.animateToPage(
        5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect RunFuel Data in Settings to sync. You can keep using local features without connecting.'),
        ),
      );
      return;
    }
    setState(() { _syncing = true; _syncError = null; });
    try {
      final data = await MobileConnectionService().sync(date: _selectedDate);
      await TrainingDataService.instance.persistSyncPayload(data);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_syncCacheKey, jsonEncode(data));
      if (mounted) setState(() => _syncData = data);
      final garmin = data['garmin']?['status'] == 'ok';
      final mfp = data['myfitnesspal']?['status'] == 'ok';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(garmin && mfp ? 'Garmin and MyFitnessPal data synced.' :
            garmin ? 'Garmin synced. MyFitnessPal needs attention.' :
            mfp ? 'MyFitnessPal synced. Garmin needs attention.' :
            'Sync completed, but neither data source returned successfully.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _syncError = e.toString().replaceFirst('Exception: ', ''));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_syncError!)));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _loadDate(DateTime date) async {
    final selected = DateTime(date.year, date.month, date.day);
    if (selected.isAfter(DateTime.now())) return;
    final authorised = await MobileConnectionService().isAuthorized();
    if (!authorised) {
      // Date navigation remains available offline. Local database-backed
      // panels can still show previously saved history for the selected day.
      if (mounted) {
        setState(() {
          _selectedDate = selected;
          _syncData = null;
          _syncError = null;
        });
      }
      return;
    }
    final previousDate = _selectedDate;
    setState(() {
      _selectedDate = selected;
      _syncing = true;
      _syncError = null;
    });
    try {
      final data = await MobileConnectionService().sync(date: selected);
      await TrainingDataService.instance.persistSyncPayload(data);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_syncCacheKey, jsonEncode(data));
      if (mounted) setState(() => _syncData = data);
    } catch (e) {
      if (mounted) {
        setState(() {
          _selectedDate = previousDate;
          _syncError = e.toString().replaceFirst('Exception: ', '');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load selected day: $_syncError')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.bolt, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(_titles[_index], style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          if (_index == 0 || _index == 1 || _index == 3 || _index == 4)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _reportingDays,
                  borderRadius: BorderRadius.circular(12),
                  items: const [
                    DropdownMenuItem(value: 7, child: Text('7 days')),
                    DropdownMenuItem(value: 14, child: Text('14 days')),
                    DropdownMenuItem(value: 28, child: Text('4 weeks')),
                    DropdownMenuItem(value: 90, child: Text('90 days')),
                  ],
                  onChanged: (value) { if (value != null) setState(() => _reportingDays = value); },
                ),
              ),
            ),
          if (_index == 0)
            IconButton(
              tooltip: 'Manual sync',
              onPressed: _syncing ? null : _manualSync,
              icon: _syncing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
            ),
        ],
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (value) => setState(() => _index = value),
        children: [
          HomePage(
            syncData: _syncData,
            syncError: _syncError,
            selectedDate: _selectedDate,
            onDateChanged: _loadDate,
            reportingDays: _reportingDays,
          ),
          TrainingPage(syncData: _syncData, reportingDays: _reportingDays),
          CoachPage(syncData: _syncData),
          NutritionPage(syncData: _syncData, selectedDate: _selectedDate, onDateChanged: _loadDate, reportingDays: _reportingDays),
          RunFuelDashboardPage(selectedDate: _selectedDate, onDateChanged: _loadDate, reportingDays: _reportingDays),
          HealthPage(syncData: _syncData),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 9, fontWeight: FontWeight.w600))),
        child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          setState(() => _index = value);
          _pageController.animateToPage(value,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'Training'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'Coach'),
          NavigationDestination(icon: Icon(Icons.restaurant_outlined), selectedIcon: Icon(Icons.restaurant), label: 'Food'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.health_and_safety_outlined), selectedIcon: Icon(Icons.health_and_safety), label: 'Health'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
        ),
      ),
    );
  }
}

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 40),
        children: children,
      );
}

String runFuelTitleCase(String value) => value
    .split(RegExp(r'\s+'))
    .map((word) => word.isEmpty
        ? word
        : word[0].toUpperCase() + word.substring(1))
    .join(' ');

String _runFuelDateKey(DateTime value) => '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

Future<List<Map<String, Object?>>> _runFuelActivitiesForDay(DateTime day) async {
  final db = await RunFuelDatabase.instance.database;
  final key = _runFuelDateKey(day);
  return db.query(
    'activities',
    where: "sport = 'running' AND started_at >= ? AND started_at < ?",
    whereArgs: ['${key}T00:00:00', '${_runFuelDateKey(day.add(const Duration(days: 1)))}T00:00:00'],
    orderBy: 'started_at DESC',
  );
}

Future<List<Map<String, Object?>>> _runFuelActivitiesForPeriod(int days) async {
  final db = await RunFuelDatabase.instance.database;
  final today = DateTime.now();
  final end = DateTime(today.year, today.month, today.day).add(const Duration(days: 1));
  final start = end.subtract(Duration(days: days));
  return db.query(
    'activities',
    where: "sport = 'running' AND started_at >= ? AND started_at < ?",
    whereArgs: ['${_runFuelDateKey(start)}T00:00:00', '${_runFuelDateKey(end)}T00:00:00'],
    orderBy: 'started_at DESC',
  );
}

Future<Map<String, dynamic>> _runFuelHomePeriodSummary(int days) async {
  final db = await RunFuelDatabase.instance.database;
  final today = DateTime.now();
  final end = DateTime(today.year, today.month, today.day).add(const Duration(days: 1));
  final start = end.subtract(Duration(days: days));
  final activities = await db.query('activities',
    where: "sport = 'running' AND started_at >= ? AND started_at < ?",
    whereArgs: ['${_runFuelDateKey(start)}T00:00:00', '${_runFuelDateKey(end)}T00:00:00']);
  final nutrition = await db.query('nutrition_days',
    where: 'day >= ? AND day < ?',
    whereArgs: [_runFuelDateKey(start), _runFuelDateKey(end)]);
  final distanceM = activities.map((r) => r['distance_m']).whereType<num>()
      .fold<double>(0, (sum, value) => sum + value.toDouble());
  final calories = nutrition.map((r) => r['calories']).whereType<num>()
      .fold<double>(0, (sum, value) => sum + value.toDouble());
  return {
    'distance_km': distanceM / 1000,
    'runs': activities.length,
    'calories_total': calories,
    'calorie_days': nutrition.where((r) => r['calories'] is num).length,
    'days': days,
  };
}

class HomePeriodSummary extends StatefulWidget {
  const HomePeriodSummary({super.key, required this.reportingDays});
  final int reportingDays;
  @override
  State<HomePeriodSummary> createState() => _HomePeriodSummaryState();
}

class _HomePeriodSummaryState extends State<HomePeriodSummary> {
  bool _dailyAverage = false;
  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    key: ValueKey(widget.reportingDays),
    future: _runFuelHomePeriodSummary(widget.reportingDays),
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const SizedBox.shrink();
      final data = snapshot.data!;
      final days = data['days'] as int;
      final calorieDays = data['calorie_days'] as int;
      String amount(num value, int digits) => formatRunFuelNumber(value, decimals: digits);
      final distance = (data['distance_km'] as num).toDouble();
      final runs = data['runs'] as int;
      final calories = (data['calories_total'] as num).toDouble();
      final distanceValue = _dailyAverage ? amount(distance / days, 2) : amount(distance, 1);
      final runsValue = _dailyAverage ? amount(runs / days, 2) : '$runs';
      final caloriesValue = calorieDays == 0 ? '--' :
        amount(_dailyAverage ? calories / calorieDays : calories, 0);
      final period = widget.reportingDays == 28 ? 'Previous 4 weeks' : 'Previous ${widget.reportingDays} days';
      return Card(
        color: Theme.of(context).colorScheme.surfaceContainer,
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('$period summary', style: const TextStyle(fontWeight: FontWeight.w800))),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Total')),
                  ButtonSegment(value: true, label: Text('Daily avg')),
                ],
                selected: {_dailyAverage},
                onSelectionChanged: (value) => setState(() => _dailyAverage = value.first),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _PeriodMetric('Distance', distanceValue, 'km${_dailyAverage ? ' / day' : ' total'}')),
              Expanded(child: _PeriodMetric('Runs', runsValue, _dailyAverage ? ' / day' : ' total')),
              Expanded(child: _PeriodMetric('Calories', caloriesValue, _dailyAverage ? 'kcal / logged day' : 'kcal logged')),
            ]),
            const SizedBox(height: 6),
            Text(_dailyAverage
              ? 'Distance and runs are averaged across all $days calendar days. Calories are averaged across $calorieDays days with recorded diary totals; missing diary days are excluded.'
              : 'Calories include $calorieDays days with recorded diary totals. Missing diary days are not counted as zero.',
              style: TextStyle(fontSize: 10, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
    },
  );
}

class _PeriodMetric extends StatelessWidget {
  const _PeriodMetric(this.label, this.value, this.unit);
  final String label, value, unit;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 5),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      Text(unit, style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(runFuelTitleCase(title), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

class MetricCard extends StatelessWidget {
  const MetricCard(this.label, this.value, this.unit, this.icon, {super.key});
  final String label;
  final String value;
  final String unit;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary, size: 20),
            const SizedBox(height: 12),
            Text(value, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
            Text(unit, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55), fontSize: 11)),
            const SizedBox(height: 5),
            Text(runFuelTitleCase(label), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          ],
        ),
      );
}

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    this.syncData,
    this.syncError,
    required this.selectedDate,
    required this.onDateChanged,
    required this.reportingDays,
  });
  final Map<String, dynamic>? syncData;
  final String? syncError;
  final DateTime selectedDate;
  final int reportingDays;
  final ValueChanged<DateTime> onDateChanged;

  String _value(dynamic value, {int decimals = 1}) {
    if (value == null) return '--';
    if (value is num) return formatRunFuelNumber(value, decimals: decimals);
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final garmin = syncData?['garmin'] as Map<String, dynamic>?;
    final running = garmin?['running_summary'] as Map<String, dynamic>?;
    final mfp = syncData?['myfitnesspal'] as Map<String, dynamic>?;
    final nutrition = mfp?['nutrition'] as Map<String, dynamic>?;
    final totals = nutrition?['totals'] as Map<String, dynamic>?;
        return PageBody(children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary.withValues(alpha: .22), Theme.of(context).colorScheme.surfaceContainer]),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('YOUR TRAINING. YOUR DATA. YOUR COACH.', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
              SizedBox(height: 10),
              Text('Build consistency.', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900)),
              SizedBox(height: 5),
              Text('Your personal running, nutrition and recovery workspace. Sync manually when you are ready.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72))),
            ],
          ),
        ),
        SectionTitle(DateUtils.isSameDay(selectedDate, DateTime.now()) ? 'Today' : 'Selected day'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(children: [
              IconButton(
                tooltip: 'Previous day',
                onPressed: () => onDateChanged(DateTime(selectedDate.year, selectedDate.month, selectedDate.day - 1)),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime(2010),
                      lastDate: DateTime.now(),
                      helpText: 'Choose a day to view',
                    );
                    if (picked != null) onDateChanged(picked);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(children: [
                      Text(
                        MaterialLocalizations.of(context).formatMediumDate(selectedDate),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const Text('Tap to choose date', style: TextStyle(fontSize: 11)),
                    ]),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next day',
                onPressed: DateUtils.isSameDay(selectedDate, DateTime.now())
                    ? null
                    : () => onDateChanged(DateTime(selectedDate.year, selectedDate.month, selectedDate.day + 1)),
                icon: const Icon(Icons.chevron_right),
              ),
              TextButton(
                onPressed: DateUtils.isSameDay(selectedDate, DateTime.now())
                    ? null
                    : () => onDateChanged(DateTime.now()),
                child: const Text('Today'),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        FutureBuilder<List<Map<String, Object?>>>(
          future: _runFuelActivitiesForDay(selectedDate),
          builder: (context, snapshot) {
            final activities = snapshot.data ?? const <Map<String, Object?>>[];
            final distanceKm = activities.fold<double>(0, (sum, a) => sum + ((a['distance_m'] as num?)?.toDouble() ?? 0) / 1000);
            return Row(children: [
              Expanded(child: MetricCard('Distance', snapshot.connectionState == ConnectionState.waiting ? '…' : activities.isEmpty ? '--' : distanceKm.toStringAsFixed(1), DateUtils.isSameDay(selectedDate, DateTime.now()) ? 'km · today' : 'km · selected day', Icons.directions_run)),
              const SizedBox(width: 10),
              Expanded(child: MetricCard('Calories', _value(totals?['calories'], decimals: 0), DateUtils.isSameDay(selectedDate, DateTime.now()) ? 'kcal · today' : 'kcal · selected day', Icons.local_fire_department_outlined)),
              const SizedBox(width: 10),
              Expanded(child: MetricCard('Runs', snapshot.connectionState == ConnectionState.waiting ? '…' : activities.length.toString(), DateUtils.isSameDay(selectedDate, DateTime.now()) ? 'activities · today' : 'activities · selected day', Icons.favorite_border)),
            ]);
          },
        ),
        HomePeriodSummary(key: ValueKey('home-period-$reportingDays'), reportingDays: reportingDays),
        const SectionTitle('Sleep & recovery'),
        SleepRecoveryPanel(
          key: ValueKey('${selectedDate.toIso8601String()}_${syncData?['synced_at']}'),
          selectedDate: selectedDate,
        ),
        if (syncData != null) ...[
          const SectionTitle('Latest data sync'),
          Text('Synced: ${syncData!['synced_at'] ?? 'unknown'}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62), fontSize: 12)),
          ConnectionTile(name: 'Garmin', detail: garmin?['status'] == 'ok' ? '${running?['activity_count'] ?? 0} runs · ${_value(running?['total_distance_km'])} km on selected day' : 'Data unavailable', icon: Icons.watch_outlined),
          ConnectionTile(name: 'MyFitnessPal', detail: mfp?['status'] == 'ok' ? '${_value(totals?['calories'], decimals: 0)} kcal · ${_value(totals?['protein'], decimals: 0)} g protein on selected day' : 'Data unavailable', icon: Icons.restaurant_outlined),
        ],
        if (syncError != null) InfoPanel(icon: Icons.warning_amber, title: 'Sync issue', body: syncError!),
        const SectionTitle('Data sources'),
        if (syncData == null)
          const InfoPanel(icon: Icons.offline_bolt_outlined, title: 'Saved data is available', body: 'You can review training plans and data already stored on this device without connecting an account. Connect RunFuel Data in Settings when you want to sync Garmin or MyFitnessPal.'),
        if (syncData != null) ...[
          ConnectionTile(name: 'Garmin', detail: garmin?['status'] == 'ok' ? 'Connected · running and wellness data checked' : 'Needs attention · check Garmin credentials', icon: Icons.watch_outlined),
          ConnectionTile(name: 'MyFitnessPal', detail: mfp?['status'] == 'ok' ? 'Connected · diary data checked' : 'Needs attention · check session cookie', icon: Icons.restaurant_outlined, onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MfpConnectionPage(syncData: syncData)))),
        ],
        const SectionTitle('Privacy'),
        const InfoPanel(icon: Icons.shield_outlined, title: 'Read-Only & Manual', body: 'RunFuel only reads the connected data when you request a sync. GPS tracks are not included in routine sync. Your health profile entries stay encrypted on this device.'),
      ]);
  }
}

class ConnectionTile extends StatelessWidget {
  const ConnectionTile({super.key, required this.name, required this.detail, required this.icon, this.onTap});
  final String name;
  final String detail;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 9),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(15)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(15),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(runFuelTitleCase(name), style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(detail, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55), fontSize: 12)),
                ])),
                if (onTap != null) Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .38)),
              ]),
            ),
          ),
        ),
      );
}

class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key, required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(runFuelTitleCase(title), style: const TextStyle(fontWeight: FontWeight.w800)),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(body, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72), height: 1.4)),
            ],
          ])),
        ]),
      );
}

class TrainingPage extends StatelessWidget {
  const TrainingPage({super.key, this.syncData, required this.reportingDays});
  final Map<String, dynamic>? syncData;
  final int reportingDays;

  @override
  Widget build(BuildContext context) {
    final garmin = syncData?['garmin'] as Map<String, dynamic>?;
    final ok = garmin?['status'] == 'ok';
    final periodLabel = reportingDays == 28 ? 'previous 4 weeks' : 'previous $reportingDays days';
    return PageBody(children: [
      InfoPanel(icon: Icons.calendar_month, title: 'Your training', body: ok
        ? 'Saved Garmin running activities for the $periodLabel. This is your recorded activity history, not a future Garmin calendar.'
        : 'Connect and sync Garmin to load your recent recorded runs.'),
      const TrainingDayPanel(),
      const SizedBox(height: 12),
      TrainingPeriodPanel(reportingDays: reportingDays),
      const SizedBox(height: 14),
      const TrainingLifecyclePanel(),
      const PlannedWorkoutsPanel(),
      const SectionTitle('Training guidance'),
      const InfoPanel(icon: Icons.trending_up, title: 'Build consistency first', body: 'Keep easy sessions genuinely easy and allow recovery between runs. Increase weekly distance gradually rather than chasing pace.'),
      const InfoPanel(icon: Icons.flag_outlined, title: 'Progression target', body: 'Build from comfortable 5 km runs towards 8 km, then regular 10 km long runs before deciding on a half-marathon build.'),
      const InfoPanel(icon: Icons.info_outline, title: 'Data boundaries', body: 'Garmin scheduled calendar workouts and future training-plan sessions are not included in this activity-history feed yet.'),
    ]);
  }
}

class TrainingDayPanel extends StatelessWidget {
  const TrainingDayPanel({super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    future: _runFuelActivitiesForDay(DateTime.now()),
    builder: (context, snapshot) {
      final activities = snapshot.data ?? const <Map<String, Object?>>[];
      final distanceM = activities.fold<double>(0, (sum, a) => sum + ((a['distance_m'] as num?)?.toDouble() ?? 0));
      final durationS = activities.fold<double>(0, (sum, a) => sum + ((a['duration_s'] as num?)?.toDouble() ?? 0));
      final pace = distanceM > 0 && durationS > 0 ? durationS / (distanceM / 1000) / 60 : null;
      final hrPairs = activities.where((a) => a['avg_hr'] is num && a['duration_s'] is num).toList();
      final hrWeight = hrPairs.fold<double>(0, (sum, a) => sum + (a['duration_s'] as num).toDouble());
      final hr = hrWeight > 0 ? hrPairs.fold<double>(0, (sum, a) => sum + (a['avg_hr'] as num).toDouble() * (a['duration_s'] as num).toDouble()) / hrWeight : null;
      final waiting = snapshot.connectionState == ConnectionState.waiting;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionTitle('Today'),
        Row(children: [
          Expanded(child: MetricCard('Distance', waiting ? '…' : activities.isEmpty ? '--' : (distanceM / 1000).toStringAsFixed(1), 'km today', Icons.route)),
          const SizedBox(width: 10),
          Expanded(child: MetricCard('Runs', waiting ? '…' : activities.length.toString(), 'activities today', Icons.directions_run)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: MetricCard('Average pace', pace == null ? '--' : pace.toStringAsFixed(2), 'min/km · today', Icons.speed)),
          const SizedBox(width: 10),
          Expanded(child: MetricCard('Average HR', hr == null ? '--' : hr.toStringAsFixed(0), 'bpm · today', Icons.favorite_border)),
        ]),
      ]);
    },
  );
}

class TrainingPeriodPanel extends StatefulWidget {
  const TrainingPeriodPanel({super.key, required this.reportingDays});
  final int reportingDays;
  @override
  State<TrainingPeriodPanel> createState() => _TrainingPeriodPanelState();
}

class _TrainingPeriodPanelState extends State<TrainingPeriodPanel> {
  bool _dailyAverage = false;

  String _fmtDuration(dynamic seconds) {
    if (seconds is! num || seconds <= 0) return '--';
    final mins = (seconds / 60).round();
    return '${mins ~/ 60}h ${mins % 60}m';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    key: ValueKey(widget.reportingDays),
    future: _runFuelActivitiesForPeriod(widget.reportingDays),
    builder: (context, snapshot) {
      final activities = snapshot.data ?? const <Map<String, Object?>>[];
      final distanceM = activities.fold<double>(0, (sum, a) => sum + ((a['distance_m'] as num?)?.toDouble() ?? 0));
      final durationS = activities.fold<double>(0, (sum, a) => sum + ((a['duration_s'] as num?)?.toDouble() ?? 0));
      final pace = distanceM > 0 && durationS > 0 ? durationS / (distanceM / 1000) / 60 : null;
      final hrPairs = activities.where((a) => a['avg_hr'] is num && a['duration_s'] is num).toList();
      final hrWeight = hrPairs.fold<double>(0, (sum, a) => sum + (a['duration_s'] as num).toDouble());
      final hr = hrWeight > 0 ? hrPairs.fold<double>(0, (sum, a) => sum + (a['avg_hr'] as num).toDouble() * (a['duration_s'] as num).toDouble()) / hrWeight : null;
      final waiting = snapshot.connectionState == ConnectionState.waiting;
      final distance = distanceM / 1000;
      final distanceValue = _dailyAverage ? (distance / widget.reportingDays).toStringAsFixed(2) : distance.toStringAsFixed(1);
      final runsValue = _dailyAverage ? (activities.length / widget.reportingDays).toStringAsFixed(2) : activities.length.toString();
      final period = widget.reportingDays == 28 ? 'Previous 4 weeks' : 'Previous ${widget.reportingDays} days';
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('$period training summary', style: const TextStyle(fontWeight: FontWeight.w800))),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Total')),
                    ButtonSegment(value: true, label: Text('Daily avg')),
                  ],
                  selected: {_dailyAverage},
                  onSelectionChanged: (value) => setState(() => _dailyAverage = value.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: MetricCard('Distance', waiting ? '…' : activities.isEmpty ? '--' : distanceValue, _dailyAverage ? 'km / calendar day' : 'km total', Icons.route)),
                const SizedBox(width: 10),
                Expanded(child: MetricCard('Runs', waiting ? '…' : _dailyAverage ? runsValue : activities.length.toString(), _dailyAverage ? 'runs / calendar day' : 'activities total', Icons.directions_run)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: MetricCard('Average pace', pace == null ? '--' : pace.toStringAsFixed(2), 'min/km · recorded runs', Icons.speed)),
                const SizedBox(width: 10),
                Expanded(child: MetricCard('Average HR', hr == null ? '--' : hr.toStringAsFixed(0), 'bpm · duration weighted', Icons.favorite_border)),
              ]),
              const SizedBox(height: 6),
              Text(_dailyAverage
                ? 'Distance and run count are averaged across all ${widget.reportingDays} calendar days, including rest days. Pace and heart rate describe recorded runs only.'
                : 'Totals include saved running activities in this period. Pace and heart rate describe recorded runs only.',
                style: TextStyle(fontSize: 10, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
        const SectionTitle('Recorded runs'),
        if (waiting)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
        else if (activities.isEmpty)
          const InfoPanel(icon: Icons.directions_run, title: 'No saved runs in this period', body: 'Sync Garmin on the Home screen to add activity history for this reporting period.')
        else
          ...activities.map((a) {
            final time = a['started_at']?.toString() ?? 'Date unavailable';
            final metres = (a['distance_m'] as num?)?.toDouble();
            final km = metres == null ? 'Distance unavailable' : '${(metres / 1000).toStringAsFixed(2)} km';
            final details = [km, _fmtDuration(a['duration_s']), a['avg_hr'] is num ? '${(a['avg_hr'] as num).toStringAsFixed(0)} bpm' : null].whereType<String>().join(' · ');
            return ConnectionTile(name: 'Running activity', detail: '$time\n$details', icon: Icons.directions_run);
          }),
      ]);
    },
  );
}

class _ChatGPTReplyDialog extends StatefulWidget {
  const _ChatGPTReplyDialog();

  @override
  State<_ChatGPTReplyDialog> createState() => _ChatGPTReplyDialogState();
}

class _ChatGPTReplyDialogState extends State<_ChatGPTReplyDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Add ChatGPT response'),
    content: SizedBox(
      width: double.maxFinite,
      child: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 5,
        maxLines: 12,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          hintText: 'Paste the response from ChatGPT here…',
          helperText: 'Long-press here and choose Paste.',
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: Text('Add to conversation'),
      ),
    ],
  );
}

class CoachPage extends StatefulWidget {
  const CoachPage({super.key, this.syncData});
  final Map<String, dynamic>? syncData;

  @override
  State<CoachPage> createState() => _CoachPageState();
}

class _CoachPageState extends State<CoachPage> with WidgetsBindingObserver {
  static const _historyKey = 'runfuel_coach_drafts_v1';
  static const _archiveKey = 'runfuel_coach_archives_v1';
  final _input = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'RunFuel coach question');
  final _scroll = ScrollController();
  final List<Map<String, String>> _messages = [];
  final List<Map<String, dynamic>> _archivedConversations = [];
  bool _loaded = false;
  bool _startupArchiveChecked = false;
  bool _geminiConfigured = false;
  bool _geminiChecking = false;
  bool? _geminiReachable;
  String? _geminiConnectionError;
  String _geminiModel = GeminiCoachService.defaultModelId;
  bool _sending = false;
  String? _generationStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadHistory();
  }

  static const _pendingArchiveKey = 'runfuel_coach_pending_archive_v1';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    SharedPreferences.getInstance().then((prefs) async {
      if (state == AppLifecycleState.paused) {
        // Record that the app went to the background. If Android later kills
        // the process, the next cold launch archives the previous chat.
        await prefs.setString(_pendingArchiveKey, DateTime.now().toIso8601String());
      } else if (state == AppLifecycleState.resumed && _startupArchiveChecked) {
        // Returning from ChatGPT or another app is not an app close; keep the
        // current conversation open for the handoff/paste-reply workflow.
        await prefs.remove(_pendingArchiveKey);
      }
    });
  }

  Future<File> _coachCacheFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/runfuel_coach_context_cache.json');
  }

  Future<File> _legacyCoachCacheFile() async {
    final directory = await getTemporaryDirectory();
    return File('${directory.path}/runfuel_coach_context_cache.json');
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final savedGeminiModel = prefs.getString('runfuel_gemini_model_v1');
    _geminiModel = GeminiCoachService.supportedModels.containsKey(savedGeminiModel)
        ? savedGeminiModel!
        : GeminiCoachService.defaultModelId;
    try {
      _geminiConfigured = await GeminiCoachService.hasApiKey();
    } catch (_) {
      // Secure storage may be unavailable in widget tests or restricted devices.
      _geminiConfigured = false;
    }
    try {
      final archivedRaw = prefs.getString(_archiveKey);
      if (archivedRaw != null) {
        final decodedArchives = jsonDecode(archivedRaw);
        if (decodedArchives is List) {
          _archivedConversations.addAll(decodedArchives.whereType<Map>().map((item) => <String, dynamic>{
            'id': item['id']?.toString() ?? '',
            'title': item['title']?.toString() ?? 'Archived conversation',
            'updatedAt': item['updatedAt']?.toString() ?? '',
            'messages': (item['messages'] is List ? item['messages'] as List : const [])
                .whereType<Map>()
                .map((message) => <String, String>{
                  'role': message['role']?.toString() ?? 'user',
                  'text': message['text']?.toString() ?? '',
                  'time': message['time']?.toString() ?? '',
                  'source': message['source']?.toString() ?? '',
                }).toList(),
          }));
        }
      }
    } catch (_) {
      _archivedConversations.clear();
    }
    // Keep the active conversation in application support storage so Android
    // cache cleanup cannot erase it before the next-launch archive runs.
    try {
      String? raw;
      if (Platform.isAndroid || Platform.isIOS) {
        final cache = await _coachCacheFile().timeout(
          const Duration(milliseconds: 300),
        );
        if (await cache.exists().timeout(const Duration(milliseconds: 300))) {
          raw = await cache.readAsString().timeout(const Duration(milliseconds: 300));
        } else {
          final legacy = await _legacyCoachCacheFile();
          if (await legacy.exists().timeout(const Duration(milliseconds: 300))) {
            raw = await legacy.readAsString().timeout(const Duration(milliseconds: 300));
            await cache.writeAsString(raw, flush: true);
            await legacy.delete();
          } else {
            raw = prefs.getString(_historyKey);
            if (raw != null) {
              await cache.writeAsString(raw, flush: true);
              await prefs.remove(_historyKey);
            }
          }
        }
      } else {
        raw = prefs.getString(_historyKey);
      }
      if (raw != null) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _messages.addAll(decoded.whereType<Map>().map((item) => {
          'role': item['role']?.toString() ?? 'user',
          'text': item['text']?.toString() ?? '',
          'time': item['time']?.toString() ?? '',
          'source': item['source']?.toString() ?? '',
        }));
        if (_messages.length > 12) {
          _messages.removeRange(0, _messages.length - 12);
        }
      }
    } catch (_) {
      // A missing or expired cache is normal; it must never block coaching.
      _messages.clear();
    }
    if (mounted) setState(() => _loaded = true);
    // A pending marker only survives if Android terminated the previous app
    // process while it was backgrounded. Normal returns clear it on resume.
    final previousSessionWasClosed = prefs.containsKey(_pendingArchiveKey);
    if (previousSessionWasClosed) {
      await prefs.remove(_pendingArchiveKey);
      if (_messages.isNotEmpty) await _archiveCurrentConversation(startFresh: true);
    }
    _startupArchiveChecked = true;
    if (_geminiConfigured) unawaited(_checkGeminiConnection());
  }

  Future<void> _checkGeminiConnection() async {
    if (_geminiChecking) return;
    if (!mounted) return;
    setState(() {
      _geminiChecking = true;
      _geminiReachable = null;
      _geminiConnectionError = null;
    });
    try {
      final key = await GeminiCoachService.readApiKey();
      if (key == null || key.trim().isEmpty) {
        throw StateError('No API key saved');
      }
      await GeminiCoachService().verifyConnection(apiKey: key);
      if (mounted) setState(() { _geminiReachable = true; });
    } catch (error) {
      if (mounted) {
        setState(() {
          _geminiReachable = false;
          _geminiConnectionError = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() { _geminiChecking = false; });
    }
  }

  Widget _geminiConnectionIndicator() {
    final Color color;
    final String label;
    if (!_geminiConfigured) {
      color = Colors.red;
      label = 'Gemini not configured';
    } else if (_geminiChecking) {
      color = Colors.amber;
      label = 'Checking Gemini…';
    } else if (_geminiReachable == true) {
      color = Colors.green;
      label = 'Gemini connected';
    } else if (_geminiReachable == false) {
      color = Colors.red;
      label = 'Gemini unreachable';
    } else {
      color = Colors.amber;
      label = 'Gemini status not checked';
    }
    return Row(children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Expanded(child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
      if (_geminiConfigured)
        IconButton(
          tooltip: 'Check Gemini connection',
          visualDensity: VisualDensity.compact,
          onPressed: _geminiChecking ? null : _checkGeminiConnection,
          icon: const Icon(Icons.refresh, size: 18),
        ),
    ]);
  }

  Future<void> _saveHistory() async {
    // Keep only the most recent six exchanges. Android may evict this cache
    // independently; Garmin/MFP records live in the separate app database.
    if (_messages.length > 12) {
      _messages.removeRange(0, _messages.length - 12);
    }
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final cache = await _coachCacheFile();
        await cache.writeAsString(jsonEncode(_messages), flush: true);
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_historyKey, jsonEncode(_messages));
      }
    } catch (_) {
      // Caching is optional; the current in-memory conversation still works.
    }
  }

  Future<Map<String, dynamic>> _buildAiContext() async {
    final db = await RunFuelDatabase.instance.database;
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    final activities = await db.query(
      'activities',
      columns: ['started_at', 'sport', 'distance_m', 'duration_s', 'avg_hr', 'avg_pace_s_per_km'],
      where: 'started_at >= ?',
      whereArgs: [cutoff],
      orderBy: 'started_at DESC',
      limit: 40,
    );
    final nutrition = await db.query(
      'nutrition_days',
      columns: ['day', 'calories', 'protein_g', 'carbs_g', 'fat_g', 'fibre_g'],
      where: 'day >= ?',
      whereArgs: [cutoff.substring(0, 10)],
      orderBy: 'day DESC',
      limit: 30,
    );
    final sleep = await db.query(
      'sleep_records',
      columns: ['sleep_date', 'total_sleep_s', 'deep_sleep_s', 'light_sleep_s', 'rem_sleep_s', 'awake_s', 'sleep_score'],
      where: 'sleep_date >= ?',
      whereArgs: [cutoff.substring(0, 10)],
      orderBy: 'sleep_date DESC',
      limit: 30,
    );
    final recovery = await db.query(
      'health_measurements',
      columns: ['measured_at', 'metric', 'value', 'unit'],
      where: "category = 'recovery' AND measured_at >= ?",
      whereArgs: [cutoff.substring(0, 10)],
      orderBy: 'measured_at DESC',
      limit: 60,
    );
    final planned = await db.query(
      'planned_workouts',
      columns: ['scheduled_at', 'workout_type', 'title', 'target_distance_m', 'intensity', 'status'],
      where: "status IN ('planned', 'needs_review', 'replan_required')",
      orderBy: 'scheduled_at ASC',
      limit: 15,
    );
    final events = await db.query(
      'training_events',
      columns: ['title', 'event_date', 'distance_m', 'goal_type', 'priority', 'event_kind', 'recurrence', 'notes'],
      where: "status = 'active'",
      orderBy: 'event_date ASC',
      limit: 20,
    );
    final pauses = await db.query(
      'training_pauses',
      columns: ['start_date', 'end_date', 'reason', 'notes', 'status', 'return_notes'],
      orderBy: 'start_date DESC',
      limit: 5,
    );
    final reviews = await db.query(
      'daily_reviews',
      columns: ['review_date', 'energy', 'soreness', 'mood', 'sleep_quality', 'notes', 'coach_summary'],
      where: 'review_date >= ?',
      whereArgs: [cutoff.substring(0, 10)],
      orderBy: 'review_date DESC',
      limit: 7,
    );
    final prefs = await SharedPreferences.getInstance();
    final garmin = widget.syncData?['garmin'] as Map<String, dynamic>?;
    final mfp = widget.syncData?['myfitnesspal'] as Map<String, dynamic>?;
    final liveNutrition = mfp?['nutrition'] as Map<String, dynamic>?;
    final primarySport = prefs.getString('primary_training_focus') ?? 'running';
    final weeklyProgress = _weeklyProgressSummary(activities, nutrition, sleep, primarySport: primarySport);
    return {
      'coach_memory': prefs.getString('runfuel_coach_memory_v1') ?? '',
      'weekly_progress_comparison': weeklyProgress,
      'primary_training_focus': primarySport,
      'nutrition_goals': liveNutrition?['goals'] ?? const <String, dynamic>{},
      'selected_day_nutrition': {
        'date': liveNutrition?['day'] ?? widget.syncData?['date'],
        'totals': liveNutrition?['totals'] ?? const <String, dynamic>{},
        'goals': liveNutrition?['goals'] ?? const <String, dynamic>{},
        'diary_status': mfp?['status'] ?? 'unknown',
        'diary_completeness': 'unknown',
      },
      'history_window_days': 30,
      'garmin_sync_status': garmin?['status'] ?? 'not_available',
      'myfitnesspal_sync_status': mfp?['status'] ?? 'not_available',
      'activities': activities,
      'nutrition_days': nutrition,
      'sleep_records': sleep,
      'recovery_measurements': recovery,
      'upcoming_planned_workouts': planned,
      'events_and_goals': events,
      'training_pauses_and_returns': pauses,
      'daily_reviews_and_user_feedback': reviews,
      'data_notes': [
        'Only locally stored records are included.',
        'Missing diary and sleep records mean unavailable data, not zero.',
        'Activity and nutrition comparisons are descriptive and do not prove causation.',
      ],
    };
  }

  Map<String, dynamic> _weeklyProgressSummary(
    List<Map<String, Object?>> activities,
    List<Map<String, Object?>> nutrition,
    List<Map<String, Object?>> sleep, {
    String primarySport = 'running',
  }) {
    final now = DateTime.now();
    final currentStart = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final previousStart = currentStart.subtract(const Duration(days: 7));

    String sportGroup(dynamic value) {
      final sport = (value ?? '').toString().trim().toLowerCase();
      if (sport.contains('run') || sport.contains('jog')) {
        return 'running';
      }
      if (sport.contains('cycl') || sport.contains('bike')) {
        return 'cycling';
      }
      if (sport.contains('swim')) {
        return 'swimming';
      }
      if (sport.contains('strength') || sport.contains('gym') ||
          sport.contains('weight')) {
        return 'strength';
      }
      if (sport.isEmpty) {
        return 'unknown';
      }
      return sport.replaceAll(RegExp(r'[_-]+'), ' ');
    }

    Map<String, dynamic> period(DateTime start, DateTime end) {
      final sessions = activities.where((row) {
        final date = DateTime.tryParse(row['started_at']?.toString() ?? '');
        return date != null && !date.isBefore(start) && date.isBefore(end);
      }).toList();
      final food = nutrition.where((row) {
        final date = DateTime.tryParse(row['day']?.toString() ?? '');
        return date != null && !date.isBefore(start) && date.isBefore(end);
      }).toList();
      final sleepRows = sleep.where((row) {
        final date = DateTime.tryParse(row['sleep_date']?.toString() ?? '');
        return date != null && !date.isBefore(start) && date.isBefore(end);
      }).toList();

      double sum(String key, List<Map<String, Object?>> rows) => rows
          .map((row) => row[key])
          .whereType<num>()
          .fold<double>(0, (total, value) => total + value.toDouble());

      final bySport = <String, List<Map<String, Object?>>>{};
      for (final row in sessions) {
        bySport.putIfAbsent(sportGroup(row['sport']), () => []).add(row);
      }
      final sportSummary = <String, dynamic>{};
      for (final entry in bySport.entries) {
        final rows = entry.value;
        final distanceM = sum('distance_m', rows);
        final durationS = sum('duration_s', rows);
        sportSummary[entry.key] = {
          'activity_count': rows.length,
          'duration_minutes': durationS > 0 ? (durationS / 60).round() : null,
          if (distanceM > 0) 'distance_km': double.parse((distanceM / 1000).toStringAsFixed(2)),
        }..removeWhere((key, value) => value == null);
      }

      final running = sessions.where((row) => sportGroup(row['sport']) == 'running').toList();
      final runningDistanceM = sum('distance_m', running);
      final runningDurationS = sum('duration_s', running);
      // Prefer Garmin's recorded pace over duration ÷ distance: activity
      // duration may include warm-up/cool-down or separately logged pauses.
      final paceRows = running.where((row) =>
          row['avg_pace_s_per_km'] is num &&
          (row['avg_pace_s_per_km'] as num) > 0 &&
          row['distance_m'] is num &&
          (row['distance_m'] as num) > 0).toList();
      final paceDistanceM = sum('distance_m', paceRows);
      final runningPace = paceDistanceM > 0
          ? paceRows.fold<double>(
                0,
                (weighted, row) => weighted +
                    (row['avg_pace_s_per_km'] as num).toDouble() *
                        (row['distance_m'] as num).toDouble(),
              ) /
              paceDistanceM
          : null;
      final longestRunM = running
          .map((row) => row['distance_m'])
          .whereType<num>()
          .fold<double>(0, (longest, value) => value.toDouble() > longest ? value.toDouble() : longest);
      final calorieRows = food.where((row) => row['calories'] is num).toList();
      final sleepRowsValid = sleepRows.where((row) => row['total_sleep_s'] is num).toList();

      return {
        'activity_count': sessions.length,
        'activity_by_sport': sportSummary,
        'running_count': running.length,
        'distance_km': double.parse((runningDistanceM / 1000).toStringAsFixed(2)),
        'longest_run_km': longestRunM > 0 ? double.parse((longestRunM / 1000).toStringAsFixed(2)) : null,
        'running_duration_minutes': runningDurationS > 0 ? (runningDurationS / 60).round() : null,
        'average_pace_seconds_per_km': runningPace?.round(),
        'nutrition_days_logged': calorieRows.length,
        'average_logged_calories': calorieRows.isEmpty ? null : (sum('calories', calorieRows) / calorieRows.length).round(),
        'sleep_nights_logged': sleepRowsValid.length,
        'average_sleep_hours': sleepRowsValid.isEmpty ? null : double.parse((sum('total_sleep_s', sleepRowsValid) / sleepRowsValid.length / 3600).toStringAsFixed(1)),
      }..removeWhere((key, value) => value == null);
    }

    final current = period(currentStart, now.add(const Duration(days: 1)));
    final previous = period(previousStart, currentStart);
    return {
      'current_period': 'last 7 calendar days',
      'previous_period': '7 calendar days before that',
      'primary_training_focus': sportGroup(primarySport),
      'current': current,
      'previous': previous,
      'interpretation_rules': [
        'Activity counts include all sports; running distance, longest run and average pace include running sessions only.',
        'Do not combine distance or pace across different sports.',
        'Compare like-for-like periods only where data exists and identify differences in session frequency and longest session.',
        'A missing diary or sleep day is unavailable, not zero; logged-day averages are not full-week averages.',
        'Diary completeness is not established by the presence of a sync record.',
        'A change in distance, pace or heart rate is descriptive and does not prove fitness improvement or explain its cause.',
        'Do not infer recovery or readiness from one metric alone.',
      ],
    };
  }

  Future<bool> _confirmAiShare(
    String question,
    Map<String, dynamic> aiContext,
    List<Map<String, String>> conversation,
  ) async {
    final preview = jsonEncode({
      'question': question,
      'recent_conversation': conversation,
      'context': const CoachingCalculationEngine().enrich(aiContext),
    });
    return await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Send this to Google Gemini?'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'This sends your question, recent coach messages and up to 30 days of saved activity, nutrition, sleep, recovery, goals and training history directly to Google Gemini. Daily check-in notes shown in the preview are included; GPS tracks, provider credentials and saved health-profile documents are excluded. IMPORTANT: on Google\'s unpaid API tier, Google may use prompts and responses to improve products and human reviewers may review them. Do not send sensitive, confidential or personal health information using the unpaid tier. Google states paid API use with an active billing account is not used to improve its products. Review the exact data below before continuing.',
                  style: TextStyle(height: 1.4),
                ),
                const SizedBox(height: 12),
                Text('Exact data to be sent:', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                SelectableText(preview, style: const TextStyle(fontSize: 10, height: 1.3)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text('Send to Google Gemini')),
        ],
      ),
    ) ?? false;
  }

  Future<void> _exportCoachingContext() async {
    try {
      final contextData = await _buildAiContext();
      final report = {
        'app': 'RunFuel',
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'history_window_days': 30,
        'purpose': 'User-approved coaching context export for an external AI coach',
        'context': contextData,
      };
      final jsonText = const JsonEncoder.withIndent('  ').convert(report);
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Export coaching history?'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('This creates a JSON file containing up to 30 days of saved activities, sleep, recovery, nutrition, planned sessions, events, pauses and daily check-ins. It may include your own check-in notes. It excludes GPS tracks, provider credentials and saved health-profile documents. Review the exact content before sharing it with another app or AI service.'),
                const SizedBox(height: 10),
                SelectableText(jsonText, style: const TextStyle(fontSize: 10, height: 1.3)),
              ],
            )),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text('Create export')),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/runfuel-coaching-context.json');
      await file.writeAsString(jsonText, flush: true);
      await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')], subject: 'RunFuel coaching context');
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export coaching context: $error')));
    }
  }

  Future<void> _editCoachMemory() async {
    final prefs = await SharedPreferences.getInstance();
    final controller = TextEditingController(
      text: prefs.getString('runfuel_coach_memory_v1') ?? '',
    );
    if (!mounted) { controller.dispose(); return; }
    final updated = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Coach memory'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            minLines: 4,
            maxLines: 9,
            maxLength: 1200,
            decoration: const InputDecoration(
              hintText: 'Add context you want RunFuel to remember, such as preferences, goals or recurring constraints.',
              helperText: 'Stored on this phone and included in future coaching context.',
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, ''), child: const Text('Clear memory')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (updated == null) return;
    await prefs.setString('runfuel_coach_memory_v1', updated);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coach memory updated on this device.')),
      );
    }
  }

  Future<void> _openDailyReview() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('Daily Review & Training Status')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: const [TrainingLifecyclePanel()],
        ),
      ),
    ));
  }

  Future<void> _configureGemini() async {
    final existingKey = await GeminiCoachService.readApiKey() ?? '';
    final controller = TextEditingController(text: existingKey);
    var selectedModel = _geminiModel;
    if (!mounted) { controller.dispose(); return; }
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Configure Google Gemini'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Use your own Google AI Studio API key. It is stored in Android secure storage and is not sent to RunFuel or Vercel.'),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'Google AI Studio API key', hintText: 'Paste your API key'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedModel,
                    decoration: const InputDecoration(labelText: 'Gemini model'),
                    items: GeminiCoachService.supportedModels.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
                    onChanged: (value) { if (value != null) setDialogState(() => selectedModel = value); },
                  ),
                  const SizedBox(height: 12),
                  const Text('Privacy: Google\'s unpaid tier may use prompts and responses to improve its products, and human reviewers may review them. Do not send sensitive health information on the unpaid tier. Google says paid API requests made through a project with active billing are not used to improve its products. Check Google\'s current terms and your project billing status before using real personal data.', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            if (existingKey.isNotEmpty) TextButton(onPressed: () => Navigator.pop(dialogContext, {'delete': 'true'}), child: const Text('Remove key')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, {'key': controller.text.trim(), 'model': selectedModel}), child: const Text('Save')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (result['delete'] == 'true') {
      await GeminiCoachService.deleteApiKey();
      if (mounted) setState(() { _geminiConfigured = false; _geminiReachable = false; _geminiConnectionError = null; });
      return;
    }
    final key = result['key'] ?? '';
    if (key.isEmpty) {
      await GeminiCoachService.deleteApiKey();
      await prefs.setBool('runfuel_use_ai_coach_v1', false);
      if (mounted) setState(() { _geminiConfigured = false; _geminiReachable = false; _geminiConnectionError = null; });
      return;
    }
    try {
      await GeminiCoachService.saveApiKey(key);
      final model = result['model'] ?? GeminiCoachService.defaultModelId;
      await prefs.setString('runfuel_gemini_model_v1', model);
      if (!mounted) return;
      setState(() { _geminiConfigured = true; _geminiModel = model; _geminiReachable = null; _geminiConnectionError = null; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gemini API key saved securely on this device.')));
      await _checkGeminiConnection();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save Gemini key: $error')));
    }
  }

  Future<void> _sendDraft() async {
    final question = _input.text.trim();
    if (question.isEmpty || _sending) return;
    if (!_geminiConfigured || !await GeminiCoachService.hasApiKey()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configure your Google Gemini API key for in-app answers, or use Open ChatGPT to export your RunFuel context.')),
        );
        await _configureGemini();
      }
      return;
    }
    setState(() { _sending = true; _generationStatus = 'Preparing your RunFuel data…'; });
    var answer = '';
    var answerSource = 'gemini';
    try {
      final aiContext = await _buildAiContext();
      final conversation = _messages
          .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
          .toList().reversed.take(8).toList().reversed
          .map((m) => <String, String>{
            'role': m['role'] ?? 'user',
            'text': (m['text'] ?? '').length > 1200 ? (m['text'] ?? '').substring(0, 1200) : (m['text'] ?? ''),
          }).toList();
      if (!mounted || !await _confirmAiShare(question, aiContext, conversation)) return;
      _generationStatus = 'Waiting for Google Gemini…';
      final apiKey = await GeminiCoachService.readApiKey();
      if (apiKey == null || apiKey.trim().isEmpty) throw StateError('Your Gemini API key is unavailable. Reconfigure it in RunFuel.');
      answer = await GeminiCoachService().reply(apiKey: apiKey, model: _geminiModel, question: question, context: aiContext, conversation: conversation);
    } catch (error) {
      answer = 'Gemini could not complete this request: $error\n\nYour question has been kept in this chat. You can retry or use Open ChatGPT to continue with an exported RunFuel context.';
      answerSource = 'error';
    } finally {
      if (mounted) setState(() { _sending = false; _generationStatus = null; });
    }
    if (!mounted || answer.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    setState(() {
      _messages.add({'role': 'user', 'text': question, 'time': now});
      _messages.add({'role': 'assistant', 'text': answer, 'time': now, 'source': answerSource});
      _input.clear();
    });
    await _saveHistory();
    if (_scroll.hasClients) {
      await _scroll.animateTo(_scroll.position.maxScrollExtent + 160, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  double? _metricNumber(dynamic source, List<String> aliases) {
    final wanted = aliases.map((key) =>
      key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase()).toSet();
    if (source is Map) {
      for (final entry in source.entries) {
        final key = entry.key.toString()
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
        if (wanted.contains(key)) {
          final value = entry.value;
          if (value is num) return value.toDouble();
          if (value is Map && value['value'] is num) {
            return (value['value'] as num).toDouble();
          }
        }
      }
      for (final value in source.values) {
        final found = _metricNumber(value, aliases);
        if (found != null) return found;
      }
    } else if (source is List) {
      for (final value in source) {
        final found = _metricNumber(value, aliases);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<String> _chatGptContext(String question) async {
    final recentConversation = _messages
        .where((message) => message['role'] == 'user' || message['role'] == 'assistant')
        .toList()
        .reversed
        .take(8)
        .toList()
        .reversed
        .map((message) => {
          'role': message['role'] ?? 'user',
          'source': message['source'] ?? '',
          'text': (message['text'] ?? '').length > 1200
              ? (message['text'] ?? '').substring(0, 1200)
              : (message['text'] ?? ''),
        })
        .toList();
    final garmin = widget.syncData?['garmin'] as Map<String, dynamic>?;
    final summary = garmin?['running_summary'] as Map<String, dynamic>?;
    final mfp = widget.syncData?['myfitnesspal'] as Map<String, dynamic>?;
    final nutrition = mfp?['nutrition'] as Map<String, dynamic>?;
    final totals = nutrition?['totals'] as Map<String, dynamic>?;
    final runs = summary?['activity_count'];
    final distance = summary?['total_distance_km'];
    final pace = summary?['average_pace_min_per_km'];
    Map<String, dynamic> fullHistory;
    try {
      fullHistory = await _buildAiContext();
    } catch (_) {
      fullHistory = {
        'history_status': 'Local history could not be read on this device at the time of export.',
        'data_notes': ['The latest Garmin and MyFitnessPal sync summary shown above is still available. Sync or retry the export later to include the full local history.'],
      };
    }
    final lines = <String>[
      'Help me as a running and nutrition coach. Use the following RunFuel summary to answer my question. Be cautious, explain uncertainty, and do not diagnose.',
      '',
      'My question: $question',
      '',
      'Recent RunFuel coach conversation (oldest first):',
      const JsonEncoder.withIndent('  ').convert(recentConversation),
      '',
      'RunFuel data summary (latest successful sync):',
      'Garmin selected day: ${garmin?['status'] == 'ok' ? 'synced' : 'not available'}.',
    ];
    if (garmin?['status'] == 'ok') {
      lines.add('Running activities: ${runs ?? 'not reported'}; distance: ${distance is num ? distance.toStringAsFixed(1) : 'not reported'} km; average pace: ${pace is num ? pace.toStringAsFixed(2) : 'not reported'} min/km.');
    }
    final health = garmin?['health'] as Map<String, dynamic>?;
    final sleepSeconds = _metricNumber(health?['sleep'], const [
      'sleepTimeSeconds', 'totalSleepSeconds', 'totalSleepDurationSeconds',
    ]);
    final sleepScore = _metricNumber(health?['sleep'], const [
      'overallSleepScore', 'sleepScore', 'overallScore', 'overall',
    ]);
    final restingHr = _metricNumber(health?['daily_summary'], const [
      'restingHeartRate', 'restingHr', 'restingHeartRateInBeatsPerMinute',
    ]);
    final hrv = _metricNumber(health?['hrv'], const [
      'lastNightAvg', 'lastNightAverage', 'weeklyAvg', 'hrvValue',
    ]);
    lines.add('Garmin sleep/recovery: ${health?['status'] == 'ok' ? 'wellness feed synced' : 'not available'}.');
    if (sleepSeconds != null) {
      lines.add('Latest sleep duration: ${(sleepSeconds / 3600).toStringAsFixed(1)} hours.');
    }
    if (sleepScore != null) lines.add('Garmin sleep score: ${sleepScore.toStringAsFixed(0)}.');
    if (restingHr != null) lines.add('Resting heart rate: ${restingHr.toStringAsFixed(0)} bpm.');
    if (hrv != null) lines.add('HRV reading: ${hrv.toStringAsFixed(0)} ms.');
    lines.add('MyFitnessPal diary: ${mfp?['status'] == 'ok' ? 'synced' : 'not available'}.');
    if (mfp?['status'] == 'ok') {
      lines.add('Diary date: ${nutrition?['day'] ?? 'not reported'}; calories: ${totals?['calories'] ?? 'not reported'} kcal; protein: ${totals?['protein'] ?? 'not reported'} g; carbohydrate: ${totals?['carbohydrates'] ?? 'not reported'} g; fat: ${totals?['fat'] ?? 'not reported'} g.');
    }
    lines.add('Complete 30-day structured RunFuel history:');
    lines.add(const JsonEncoder.withIndent('  ').convert(fullHistory));
    lines.addAll([
      '',
      'Privacy limits: this export includes the selected aggregate running, sleep/recovery, diary, events, training-pause and daily check-in information. It excludes GPS tracks, exact routes, account details, credentials and saved health-profile documents. Review the exact text before sharing. Treat missing diary and sleep records as unavailable, not zero.',
      'Please base recommendations on the information above and ask before assuming any missing details.',
    ]);
    return lines.join('\n');
  }

  Future<void> _continueInChatGPT() async {
    var question = _input.text.trim();
    if (question.isEmpty) {
      for (final message in _messages.reversed) {
        if (message['role'] == 'user' && (message['text'] ?? '').trim().isNotEmpty) {
          question = message['text']!.trim();
          break;
        }
      }
    }
    if (question.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ask a question first, or choose a suggested question below.')),
      );
      _inputFocus.requestFocus();
      return;
    }
    final prompt = await _chatGptContext(question);
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Share a summary with ChatGPT?'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('RunFuel will open the Android share sheet. Choose ChatGPT if you want to continue there. Nothing is sent until you choose an app.'),
                const SizedBox(height: 12),
                Text('The exact text to be shared:', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                SelectableText(prompt, style: const TextStyle(fontSize: 12, height: 1.4)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text('Choose app')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await Share.share(prompt, subject: 'RunFuel coach question');
  }

  Future<void> _pasteChatGPTReply() async {
    if (!mounted) return;
    final reply = await showDialog<String>(
      context: context,
      builder: (_) => const _ChatGPTReplyDialog(),
    );
    if (reply == null || reply.trim().isEmpty || !mounted) return;
    final now = DateTime.now().toIso8601String();
    setState(() {
      _messages.add({'role': 'assistant', 'text': reply.trim(), 'time': now, 'source': 'chatgpt'});
    });
    await _saveHistory();
    if (_scroll.hasClients) {
      await _scroll.animateTo(
        _scroll.position.maxScrollExtent + 240,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  String _conversationTitle(List<Map<String, String>> messages) {
    final firstQuestion = messages.firstWhere(
      (message) => message['role'] == 'user' && (message['text'] ?? '').trim().isNotEmpty,
      orElse: () => <String, String>{},
    )['text']?.trim() ?? '';
    if (firstQuestion.isEmpty) return 'RunFuel conversation';
    return firstQuestion.length > 48 ? '${firstQuestion.substring(0, 45)}…' : firstQuestion;
  }

  Future<void> _persistArchives() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_archiveKey, jsonEncode(_archivedConversations));
  }

  Future<void> _archiveCurrentConversation({bool startFresh = false}) async {
    if (_messages.isEmpty) return;
    final snapshot = _messages.map((message) => Map<String, String>.from(message)).toList();
    final now = DateTime.now().toIso8601String();
    setState(() {
      _archivedConversations.insert(0, <String, dynamic>{
        'id': now,
        'title': _conversationTitle(snapshot),
        'updatedAt': now,
        'messages': snapshot,
      });
      if (_archivedConversations.length > 50) {
        _archivedConversations.removeRange(50, _archivedConversations.length);
      }
      _messages.clear();
    });
    await _persistArchives();
    final cache = await _coachCacheFile();
    if (await cache.exists()) await cache.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    if (mounted && !startFresh) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conversation archived on this device.')));
    }
  }

  Future<void> _startNewConversation() async {
    if (_messages.isNotEmpty) {
      final archive = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Start a new chat?'),
          content: const Text('Archive this conversation so you can reopen it later, then start a fresh chat?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Archive & start')),
          ],
        ),
      );
      if (archive != true) return;
      await _archiveCurrentConversation(startFresh: true);
    }
    if (!mounted) return;
    setState(() => _messages.clear());
    final cache = await _coachCacheFile();
    if (await cache.exists()) await cache.delete();
    _input.clear();
  }

  Future<void> _showArchivedConversations() async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refreshDialog) => AlertDialog(
          title: const Text('Archived chats'),
          content: SizedBox(
            width: double.maxFinite,
            child: _archivedConversations.isEmpty
                ? const Text('No archived chats yet. Archive a conversation to keep it here on this device.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _archivedConversations.length,
                    itemBuilder: (context, index) {
                      final item = _archivedConversations[index];
                      final messages = (item['messages'] as List?) ?? const [];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.archive_outlined),
                        title: Text(item['title']?.toString() ?? 'Archived conversation', maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${messages.length ~/ 2} exchanges · ${item['updatedAt']?.toString().split('T').first ?? ''}'),
                        onTap: () => Navigator.pop(dialogContext, item),
                        trailing: IconButton(
                          tooltip: 'Delete archived chat',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            _archivedConversations.removeAt(index);
                            await _persistArchives();
                            refreshDialog(() {});
                            if (mounted) setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (_messages.isNotEmpty) {
      final archiveCurrent = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Save current chat?'),
          content: const Text('Archive the current conversation before opening the selected one?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Replace')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Archive')),
          ],
        ),
      );
      if (archiveCurrent == null) return;
      if (archiveCurrent) await _archiveCurrentConversation(startFresh: true);
    }
    final restored = (selected['messages'] as List? ?? const [])
        .whereType<Map>()
        .map((message) => <String, String>{
          'role': message['role']?.toString() ?? 'user',
          'text': message['text']?.toString() ?? '',
          'time': message['time']?.toString() ?? '',
          'source': message['source']?.toString() ?? '',
        }).toList();
    setState(() {
      _messages
        ..clear()
        ..addAll(restored);
      _archivedConversations.removeWhere((item) => item['id'] == selected['id']);
    });
    await _persistArchives();
    await _saveHistory();
  }

  Future<void> _copyEntireChat() async {
    if (_messages.isEmpty) return;
    final transcript = _messages.map((message) {
      final role = message['role'] == 'assistant' ? 'RUNFUEL COACH' : 'YOU';
      final time = (message['time'] ?? '').toString();
      final text = (message['text'] ?? '').trim();
      return '$role${time.isEmpty ? '' : ' · $time'}\n$text';
    }).join('\n\n---\n\n');
    await Clipboard.setData(ClipboardData(text: transcript));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Entire current conversation copied'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _backToTop() async {
    if (!_scroll.hasClients) return;
    await _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear saved questions?'),
        content: Text('This removes the locally saved coach conversation from this device. Your separate Coach memory is kept until you clear it from the bookmark button.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) {
      setState(_messages.clear);
      try {
        final cache = await _coachCacheFile();
        if (await cache.exists()) await cache.delete();
      } catch (_) {}
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    controller: _scroll,
    padding: const EdgeInsets.only(bottom: 16),
    children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .10))),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: .14), borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your RunFuel coach', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              Text('Your training, nutrition and recovery in one place', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62), fontSize: 11)),
            ])),
          ]),
          const SizedBox(height: 4),
          Wrap(alignment: WrapAlignment.start, spacing: 2, runSpacing: 0, children: [
            IconButton(tooltip: 'Coach memory', visualDensity: VisualDensity.compact,
              onPressed: _loaded && !_sending ? _editCoachMemory : null,
              icon: const Icon(Icons.bookmark_outline, size: 20)),
            IconButton(tooltip: 'Archived chats', visualDensity: VisualDensity.compact,
              onPressed: _loaded ? _showArchivedConversations : null,
              icon: const Icon(Icons.archive_outlined, size: 20)),
            IconButton(tooltip: 'New chat', visualDensity: VisualDensity.compact,
              onPressed: _loaded && !_sending ? _startNewConversation : null,
              icon: const Icon(Icons.add_comment_outlined, size: 20)),
            if (_messages.isNotEmpty)
              IconButton(tooltip: 'Back to top of chat', visualDensity: VisualDensity.compact,
                onPressed: _backToTop, icon: const Icon(Icons.vertical_align_top, size: 20)),
            if (_messages.isNotEmpty)
              IconButton(tooltip: 'Copy entire chat', visualDensity: VisualDensity.compact,
                onPressed: _copyEntireChat, icon: const Icon(Icons.copy_all_outlined, size: 20)),
            if (_messages.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Conversation options',
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (value) {
                  if (value == 'archive') _archiveCurrentConversation();
                  if (value == 'clear') _clearHistory();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'archive', child: ListTile(leading: Icon(Icons.archive_outlined), title: Text('Archive conversation'), dense: true)),
                  PopupMenuItem(value: 'clear', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Clear conversation'), dense: true)),
                ],
              ),
          ]),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: _loaded && !_sending ? _continueInChatGPT : null,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text('Open ChatGPT'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _loaded && !_sending ? _pasteChatGPTReply : null,
              icon: const Icon(Icons.content_paste, size: 18),
              label: Text('Paste Reply'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 11)),
            )),
          ]),
          const SizedBox(height: 4),
          Text(
            'In-app answers use your Google Gemini API key. ChatGPT remains available as an alternative; your RunFuel data is shared only after you review and choose to continue.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62), fontSize: 10, height: 1.3),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Coaching tools', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            children: [
              _geminiConnectionIndicator(),
              if (_geminiConnectionError != null)
                Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(_geminiConnectionError!, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.error))),
              Wrap(spacing: 8, runSpacing: 6, children: [
                OutlinedButton.icon(onPressed: _openDailyReview, icon: const Icon(Icons.rate_review_outlined), label: const Text('Review my day')),
                OutlinedButton.icon(onPressed: _loaded && !_sending ? _exportCoachingContext : null, icon: const Icon(Icons.file_download_outlined), label: const Text('Export coaching history')),
                OutlinedButton.icon(onPressed: _loaded && !_sending ? _configureGemini : null, icon: const Icon(Icons.key_outlined), label: Text(_geminiConfigured ? 'Manage Gemini API key' : 'Configure Gemini API key')),
              ]),
              const SizedBox(height: 8),
              Text(
                _geminiConfigured ? 'Gemini is ready · ${GeminiCoachService.supportedModels[_geminiModel] ?? _geminiModel}. Review the data preview before each request.' : 'Add your Google AI Studio API key for in-app answers. You can still export to ChatGPT without configuring Gemini.',
                style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .7)),
              ),
            ],
          ),
        ]),
      ),
      if (!_loaded)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_messages.isEmpty)
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 28),
              Icon(Icons.chat_bubble_outline, size: 42, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text('What would you like help with?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 16),
              _promptChip('Review my day'),
              _promptChip('Review my last 7 days and compare with the previous week'),
              _promptChip('Review my running progress'),
              _promptChip('Am I eating enough to support training?'),
              _promptChip('How should I approach recovery today?'),
              _promptChip('Help me plan my next week'),
            ],
          ),
        )
      else
        ..._messages.map((message) {
          final isAssistant = message['role'] == 'assistant';
          return Align(
            alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              width: isAssistant ? double.infinity : null,
              constraints: isAssistant ? const BoxConstraints() : const BoxConstraints(maxWidth: 340),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: isAssistant ? Theme.of(context).colorScheme.surfaceContainer : Theme.of(context).colorScheme.primary.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isAssistant ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .12) : Theme.of(context).colorScheme.primary.withValues(alpha: .22)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  isAssistant
                    ? (message['source'] == 'chatgpt' ? 'CHATGPT RESPONSE' : message['source'] == 'openai' ? 'RUNFUEL AI COACH' : message['source'] == 'gemini' ? 'GEMINI ONLINE COACH' : message['source'] == 'error' ? 'AI SERVICE ERROR' : 'RUNFUEL COACH')
                    : 'YOU',
                  style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w800, letterSpacing: .6),
                ),
                const SizedBox(height: 5),
                if (isAssistant)
                  CoachingReportCard(text: message['text'] ?? '', source: message['source'] ?? 'gemini')
                else
                  Text(message['text'] ?? ''),
                if (isAssistant)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(
                          ClipboardData(text: message['text'] ?? ''),
                        );
                        if (!mounted) return;
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Response copied to clipboard'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  isAssistant
                    ? (message['source'] == 'chatgpt' ? 'Added from your ChatGPT app' : message['source'] == 'openai' ? 'OpenAI API response' : message['source'] == 'gemini' ? 'Gemini API response · sent directly to Google' : message['source'] == 'error' ? 'Gemini request did not complete' : 'RunFuel coaching response')
                    : 'Saved on this device · not sent to AI yet',
                  style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .54)),
                ),
              ]),
            ),
          );
        }),
      if (_messages.isNotEmpty && !_sending)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.lightbulb_outline, size: 17, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 7),
                const Text('Suggested next steps', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              ]),
              const SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: _suggestedFollowUps().map((prompt) => ActionChip(
                  avatar: const Icon(Icons.arrow_forward, size: 15),
                  label: Text(prompt),
                  onPressed: () {
                    _input.text = prompt;
                    _sendDraft();
                  },
                )).toList(),
              ),
            ],
          ),
        ),
      if (_sending)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Expanded(child: Text(_generationStatus ?? 'Preparing your answer…', style: const TextStyle(fontSize: 11))),
          ]),
        ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                key: const Key('coach-question-input'),
                controller: _input,
                focusNode: _inputFocus,
                keyboardType: TextInputType.multiline,
                enableInteractiveSelection: true,
                scrollPadding: const EdgeInsets.only(bottom: 140),
                onTap: () => FocusScope.of(context).requestFocus(_inputFocus),
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Ask your running coach…',
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send to Gemini',
              onPressed: !_loaded || _sending ? null : _sendDraft,
              icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
            ),
          ]),
        ),
      ),
    ],
  );

  List<String> _suggestedFollowUps() {
    final latestQuestion = _messages.reversed
        .firstWhere((message) => message['role'] == 'user', orElse: () => {})
        ['text']?.toLowerCase() ?? '';
    if (latestQuestion.contains('7 days') || latestQuestion.contains('week')) {
      return [
        'What should my main focus be next week?',
        'Which change in the data matters most?',
        'What information is missing from this comparison?',
      ];
    }
    if (latestQuestion.contains('food') || latestQuestion.contains('nutrition') ||
        latestQuestion.contains('calor') || latestQuestion.contains('carb')) {
      return [
        'How can I improve my carbohydrate intake?',
        'How complete is my food diary?',
        'How should I fuel my next run?',
      ];
    }
    if (latestQuestion.contains('sleep') || latestQuestion.contains('recover') ||
        latestQuestion.contains('hrv')) {
      return [
        'What should I change about my next session?',
        'How does my recent sleep compare?',
        'What other recovery information would help?',
      ];
    }
    return [
      'What should I focus on next?',
      'How does this compare with my recent history?',
      'What data would make this assessment more reliable?',
    ];
  }

  Widget _promptChip(String prompt) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: ActionChip(
      avatar: const Icon(Icons.add_comment_outlined, size: 17),
      label: Text(prompt),
      onPressed: () => setState(() => _input.text = prompt),
    ),
  );
}

class NutritionPeriodSummary extends StatefulWidget {
  const NutritionPeriodSummary({super.key, required this.reportingDays});
  final int reportingDays;
  @override
  State<NutritionPeriodSummary> createState() => _NutritionPeriodSummaryState();
}

class _NutritionPeriodSummaryState extends State<NutritionPeriodSummary> {
  bool _dailyAverage = false;

  Future<List<Map<String, Object?>>> _load() async {
    final db = await RunFuelDatabase.instance.database;
    final today = DateTime.now();
    final firstDay = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: widget.reportingDays - 1));
    return db.query(
      'nutrition_days',
      columns: ['day', 'calories', 'protein_g', 'carbs_g', 'fat_g', 'fibre_g'],
      where: 'day >= ? AND day <= ?',
      whereArgs: [_runFuelDateKey(firstDay), _runFuelDateKey(today)],
      orderBy: 'day ASC',
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    key: ValueKey(widget.reportingDays),
    future: _load(),
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
      }
      final rows = snapshot.data!;
      const metrics = [
        ('Calories', 'calories', 'kcal', Icons.local_fire_department_outlined),
        ('Protein', 'protein_g', 'g', Icons.egg_alt_outlined),
        ('Carbs', 'carbs_g', 'g', Icons.bakery_dining_outlined),
        ('Fat', 'fat_g', 'g', Icons.water_drop_outlined),
        ('Fibre', 'fibre_g', 'g', Icons.grass_outlined),
      ];
      final period = widget.reportingDays == 28 ? 'Previous 4 weeks' : 'Previous ${widget.reportingDays} days';
      final values = metrics.map((metric) {
        final logged = rows.where((row) => row[metric.$2] is num).toList();
        final total = logged.fold<double>(0, (sum, row) => sum + (row[metric.$2] as num).toDouble());
        return (total, logged.length);
      }).toList();
      return Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('$period nutrition summary', style: const TextStyle(fontWeight: FontWeight.w800))),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Total')),
                  ButtonSegment(value: true, label: Text('Daily avg')),
                ],
                selected: {_dailyAverage},
                onSelectionChanged: (value) => setState(() => _dailyAverage = value.first),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ]),
            const SizedBox(height: 12),
            ...List.generate((metrics.length / 2).ceil(), (row) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                for (var col = 0; col < 2; col++)
                  if (row * 2 + col < metrics.length)
                    Expanded(child: Padding(
                      padding: EdgeInsets.only(right: col == 0 ? 10 : 0),
                      child: MetricCard(
                        metrics[row * 2 + col].$1,
                        values[row * 2 + col].$2 == 0 ? '--' :
                          (_dailyAverage
                            ? formatRunFuelNumber(values[row * 2 + col].$1 / values[row * 2 + col].$2)
                            : formatRunFuelNumber(values[row * 2 + col].$1)),
                        _dailyAverage ? '${metrics[row * 2 + col].$3} / logged day' : '${metrics[row * 2 + col].$3} total',
                        metrics[row * 2 + col].$4,
                      ),
                    ))
                  else
                    const Expanded(child: SizedBox.shrink()),
              ]),
            )),
            Text(
              _dailyAverage
                ? 'Averages use only days with a recorded value for each nutrient. Missing diary days are excluded, not counted as zero. ${rows.length} diary dates found.'
                : 'Totals include only saved diary entries in this period. Missing diary days are excluded, not counted as zero. ${rows.length} diary dates found.',
              style: TextStyle(fontSize: 10, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
      );
    },
  );
}

class NutritionPage extends StatefulWidget {
  const NutritionPage({super.key, this.syncData, required this.selectedDate, required this.onDateChanged, required this.reportingDays});
  final Map<String, dynamic>? syncData;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateChanged;
  final int reportingDays;

  @override
  State<NutritionPage> createState() => _NutritionPageState();
}

class _NutritionPageState extends State<NutritionPage> {
  bool _mfpConnected = false;
  bool _mfpChecking = true;
  bool _mfpStatusKnown = false;

  @override
  void initState() {
    super.initState();
    _refreshMfpStatus();
  }

  Future<void> _refreshMfpStatus() async {
    if (mounted) setState(() => _mfpChecking = true);
    try {
      final status = await MobileConnectionService().mfpStatus();
      if (mounted) {
        setState(() {
          _mfpConnected = status['connected'] == true;
          _mfpStatusKnown = true;
          _mfpChecking = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _mfpConnected = false;
          _mfpStatusKnown = false;
          _mfpChecking = false;
        });
      }
    }
  }

  String _num(dynamic value, {int digits = 0}) =>
      value is num ? formatRunFuelNumber(value, decimals: digits) : '--';

  Future<void> _copyFoodMeal(Map meal, DateTime date) async {
    final lines = <String>[
      'RunFuel food diary - ${MaterialLocalizations.of(context).formatMediumDate(date)}',
      '',
      (meal['meal'] ?? 'Meal').toString(),
    ];
    final entries = (meal['entries'] as List?)?.whereType<Map>() ?? const [];
    for (final entry in entries) {
      final nutrients = entry['nutrients'] as Map? ?? {};
      lines.add('');
      lines.add((entry['name'] ?? 'Food').toString());
      for (final nutrient in [
        ('Calories', 'calories', 'kcal'),
        ('Protein', 'protein', 'g'),
        ('Carbs', 'carbohydrates', 'g'),
        ('Fat', 'fat', 'g'),
        ('Fibre', 'fiber', 'g'),
        ('Sugar', 'sugar', 'g'),
      ]) {
        final value = nutrients[nutrient.$2];
        if (value is num) {
          lines.add('${nutrient.$1}: ${_num(value)} ${nutrient.$3}');
        }
      }
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${(meal['meal'] ?? 'Meal').toString()} copied')),
      );
    }
  }

  Future<void> _copyFoodDiary({
    required DateTime date,
    required Map? totals,
    required Map? goals,
    required List<Map> meals,
  }) async {
    final lines = <String>[
      'RunFuel food diary - ${MaterialLocalizations.of(context).formatMediumDate(date)}',
      '',
      'Daily intake',
    ];
    for (final nutrient in [
      ('Calories', 'calories', 'kcal'),
      ('Protein', 'protein', 'g'),
      ('Carbs', 'carbohydrates', 'g'),
      ('Fat', 'fat', 'g'),
      ('Fibre', 'fiber', 'g'),
      ('Sugar', 'sugar', 'g'),
    ]) {
      final value = totals?[nutrient.$2];
      final goal = goals?[nutrient.$2];
      if (value is num) {
        final amount = '${nutrient.$1}: ${_num(value)} ${nutrient.$3}';
        final goalText = goal is num
            ? ' / ${_num(goal)} ${nutrient.$3} goal'
            : '';
        lines.add('$amount$goalText');
      }
    }
    for (final meal in meals) {
      lines
        ..add('')
        ..add((meal['meal'] ?? 'Meal').toString());
      final entries = (meal['entries'] as List?)?.whereType<Map>() ?? const [];
      for (final entry in entries) {
        final nutrients = entry['nutrients'] as Map? ?? {};
        final calories = nutrients['calories'];
        final name = (entry['name'] ?? 'Food').toString();
        lines.add('- $name${calories is num ? ' - ${_num(calories)} kcal' : ''}');
      }
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Daily food diary copied')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mfp = widget.syncData?['myfitnesspal'] as Map<String, dynamic>?;
    final nutrition = mfp?['nutrition'] as Map<String, dynamic>?;
    final totals = nutrition?['totals'] as Map<String, dynamic>?;
    final goals = nutrition?['goals'] as Map<String, dynamic>?;
    final meals = (nutrition?['meals'] as List?)?.whereType<Map>().toList() ?? [];
    final ok = mfp?['status'] == 'ok';
    final nutrients = [
      ('Calories', 'calories', 'kcal', Icons.local_fire_department_outlined),
      ('Protein', 'protein', 'g', Icons.egg_alt_outlined),
      ('Carbs', 'carbohydrates', 'g', Icons.bakery_dining_outlined),
      ('Fat', 'fat', 'g', Icons.water_drop_outlined),
      ('Fibre', 'fiber', 'g', Icons.grass_outlined),
      ('Sugar', 'sugar', 'g', Icons.cake_outlined),
    ];
    return PageBody(children: [
      const InfoPanel(icon: Icons.restaurant, title: 'MyFitnessPal Diary', body: ''),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            IconButton(
              tooltip: 'Previous day',
              onPressed: () => widget.onDateChanged(DateTime(
                widget.selectedDate.year, widget.selectedDate.month,
                widget.selectedDate.day - 1,
              )),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: widget.selectedDate,
                    firstDate: DateTime(2010),
                    lastDate: DateTime.now(),
                    helpText: 'Choose a diary date',
                  );
                  if (picked != null) widget.onDateChanged(picked);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(children: [
                    Text(
                      MaterialLocalizations.of(context).formatMediumDate(widget.selectedDate),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const Text('Tap to choose date', style: TextStyle(fontSize: 11)),
                  ]),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: DateUtils.isSameDay(widget.selectedDate, DateTime.now())
                  ? null
                  : () => widget.onDateChanged(DateTime(
                      widget.selectedDate.year, widget.selectedDate.month,
                      widget.selectedDate.day + 1,
                    )),
              icon: const Icon(Icons.chevron_right),
            ),
            TextButton(
              onPressed: DateUtils.isSameDay(widget.selectedDate, DateTime.now())
                  ? null
                  : () => widget.onDateChanged(DateTime.now()),
              child: const Text('Today'),
            ),
          ]),
        ),
      ),
      Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
        onPressed: _mfpChecking ? null : () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MfpConnectionPage()),
          );
          _refreshMfpStatus();
        },
        icon: Icon(_mfpChecking
            ? Icons.sync
            : _mfpConnected ? Icons.verified_user_outlined : Icons.link),
        label: Text(_mfpChecking
            ? 'Checking MyFitnessPal…'
            : _mfpConnected
                ? 'Disconnect MyFitnessPal'
                : _mfpStatusKnown
                    ? 'Connect MyFitnessPal'
                    : 'MyFitnessPal Status Unavailable · Retry'),
      )),
      SectionTitle(DateUtils.isSameDay(widget.selectedDate, DateTime.now()) ? 'Today’s Intake' : 'Selected Day’s Intake'),
      if (!ok)
        const InfoPanel(icon: Icons.sync_problem, title: 'No diary data yet', body: 'Connect your MyFitnessPal account below, then sync from Home.'),
      ...List.generate(3, (row) => Row(children: [
        for (var col = 0; col < 2; col++)
          Expanded(child: Padding(
            padding: EdgeInsets.only(right: col == 0 ? 10 : 0, bottom: 10),
            child: MetricCard(
              nutrients[row * 2 + col].$1,
              _num(totals?[nutrients[row * 2 + col].$2]),
              nutrients[row * 2 + col].$3,
              nutrients[row * 2 + col].$4,
            ),
          )),
      ])),
      const SectionTitle('Selected Period Summary'),
      NutritionPeriodSummary(reportingDays: widget.reportingDays),
      const SectionTitle('Training & Nutrition Patterns'),
      TrainingNutritionInsightsPanel(key: ValueKey('${widget.syncData?['synced_at']}_$widget.reportingDays'), reportingDays: widget.reportingDays),
      const SectionTitle('Daily goals'),
      ...nutrients.where((n) => goals?.containsKey(n.$2) == true).map((n) {
        final current = totals?[n.$2];
        final goal = goals?[n.$2];
        final progress = current is num && goal is num && goal > 0 ? (current / goal).clamp(0.0, 1.0).toDouble() : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(n.$1, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${_num(current)} / ${_num(goal)} ${n.$3}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72), fontSize: 12)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: progress, minHeight: 8, backgroundColor: Theme.of(context).colorScheme.surfaceContainer)),
          ]),
        );
      }),
      Row(
        children: [
          const Expanded(child: SectionTitle('Meals & Food Entries')),
          if (ok)
            IconButton(
              tooltip: 'Copy daily food diary',
              onPressed: () => _copyFoodDiary(
                date: widget.selectedDate,
                totals: totals,
                goals: goals,
                meals: meals,
              ),
              icon: const Icon(Icons.copy_outlined),
            ),
        ],
      ),
      if (ok && meals.isEmpty)
        const InfoPanel(icon: Icons.no_food, title: 'No meals returned', body: 'The diary has no meal entries for this date.'),
      ...meals.map((meal) {
        final entries = (meal['entries'] as List?)?.whereType<Map>().toList() ?? [];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(15)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text((meal['meal'] ?? 'Meal').toString(), style: const TextStyle(fontWeight: FontWeight.w800))),
              IconButton(
                tooltip: 'Copy ${(meal['meal'] ?? 'meal').toString()}',
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyFoodMeal(meal, widget.selectedDate),
                icon: const Icon(Icons.copy_outlined),
              ),
            ]),
            const SizedBox(height: 8),
            ...entries.map((entry) {
              final values = entry['nutrients'] as Map? ?? {};
              return Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(children: [
                  Expanded(child: Text((entry['name'] ?? 'Food').toString())),
                  Text('${_num(values['calories'])} kcal', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72))),
                ]),
              );
            }),
          ]),
        );
      }),
      if (ok)
        Text('Only nutrient fields actually supplied by MyFitnessPal are displayed. Missing values are not estimated.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .54), fontSize: 12)),
    ]);
  }
}

class HealthPage extends StatefulWidget {
  const HealthPage({super.key, this.syncData});
  final Map<String, dynamic>? syncData;

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  static const _filesKey = 'runfuel_health_files_v1';
  final List<Map<String, String>> _selectedFiles = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<Directory> _recordsDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'health_records'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _loadFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_filesKey);
    if (raw != null) {
      try {
        final items = (jsonDecode(raw) as List).whereType<Map>();
        _selectedFiles.addAll(items.map((item) => {
          'name': item['name']?.toString() ?? 'Health record',
          'path': item['path']?.toString() ?? '',
        }).where((item) => item['path']!.isNotEmpty && File(item['path']!).existsSync()));
      } catch (_) {
        // Ignore corrupt local index; original files remain private in app storage.
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveFiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_filesKey, jsonEncode(_selectedFiles));
  }

  Future<void> _storeFile(String sourcePath, String name) async {
    final dir = await _recordsDirectory();
    final safeName = p.basename(name).replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final destination = p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$safeName');
    final saved = await File(sourcePath).copy(destination);
    _selectedFiles.add({'name': name, 'path': saved.path});
    await _saveFiles();
    if (mounted) setState(() {});
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp'],
      withData: false,
    );
    if (result != null) {
      var savedCount = 0;
      for (final file in result.files) {
        if (file.path == null) continue;
        await _storeFile(file.path!, file.name);
        savedCount++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$savedCount file(s) saved privately on this device. Nothing was uploaded.')),
        );
      }
    }
  }

  Future<void> _takePhoto() async {
    final image = await ImagePicker().pickImage(source: ImageSource.camera);
    if (image != null) {
      await _storeFile(image.path, image.name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo saved privately on this device. Nothing was uploaded.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final garmin = widget.syncData?['garmin'] as Map<String, dynamic>?;
    final summary = garmin?['running_summary'] as Map<String, dynamic>?;
    final health = garmin?['health'] as Map<String, dynamic>?;
    final healthOk = health?['status'] == 'ok';
    final runningOk = garmin?['status'] == 'ok';
    String show(dynamic value, String unit) => value is num ? '${value.toStringAsFixed(0)} $unit' : '--';
    List<Widget> dataRows(String heading, dynamic source) {
      if (source is! Map || source.isEmpty) return [];
      final readings = <Widget>[];
      const labels = <String, String>{
        'steps': 'Steps', 'resting_heart_rate': 'Resting heart rate',
        'restingHeartRate': 'Resting heart rate', 'average_heart_rate': 'Average heart rate',
        'stress': 'Stress', 'body_battery': 'Body Battery', 'bodyBattery': 'Body Battery',
        'sleep_score': 'Sleep score', 'sleepScore': 'Sleep score',
        'duration_minutes': 'Sleep duration', 'duration': 'Duration',
        'average_hrv': 'Average HRV', 'hrv': 'Heart-rate variability',
      };
      for (final entry in source.entries) {
        final value = entry.value;
        if (value == null || value is Map || value is List) continue;
        final raw = entry.key.toString();
        final label = labels[raw] ?? raw
          .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
          .replaceAll('_', ' ')
          .split(' ')
          .map((word) => word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
          .join(' ');
        final display = value is num ? (value is double ? value.toStringAsFixed(1) : value.toString()) : value.toString();
        readings.add(ListTile(dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(label), trailing: Text(display, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72)))));
      }
      if (readings.isEmpty) return [];
      return [Card(color: Theme.of(context).colorScheme.surfaceContainer, margin: const EdgeInsets.only(bottom: 8),
        child: ExpansionTile(leading: const Icon(Icons.monitor_heart_outlined),
          title: Text(heading, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${readings.length} readings · tap to view', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62))),
          children: readings))];
    }
    return PageBody(children: [
        const InfoPanel(
          icon: Icons.health_and_safety,
          title: 'Health & Athlete Profile',
          body: 'Your Garmin wellness readings and private athlete notes are shown separately. This is a training record, not a medical record or diagnosis.',
        ),
        const SectionTitle('Garmin wellness'),
        if (!healthOk)
          InfoPanel(icon: Icons.info_outline, title: 'Wellness metrics not synced', body: runningOk
            ? 'Running activities are connected. Sleep, resting heart rate, HRV, stress and Body Battery need the expanded Garmin wellness sync.'
            : 'Sync Garmin from Home to load available data.'),
        if (healthOk) ...[
          ...dataRows('Daily Wellness · Garmin', health?['daily_summary']),
          ...dataRows('Sleep · Garmin', health?['sleep']),
          ...dataRows('Heart-Rate Variability · Garmin', health?['hrv']),
          if ((health?['unavailable_metrics'] as List?)?.isNotEmpty == true)
            InfoPanel(icon: Icons.info_outline, title: 'Some wellness feeds unavailable', body: 'Garmin did not return: ${(health?['unavailable_metrics'] as List).join(', ')}.'),
        ],
        if (runningOk) ...[
          const SectionTitle('Activity-Derived Health'),
          Row(children: [
            Expanded(child: MetricCard('Average run HR', show(summary?['duration_weighted_average_hr_bpm'], 'bpm'), 'selected day', Icons.monitor_heart)),
            const SizedBox(width: 10),
            Expanded(child: MetricCard('Elevation', show(summary?['total_elevation_gain_m'], 'm'), 'selected day', Icons.terrain)),
          ]),
        ],
        const SectionTitle('Add information'),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: _pickDocument, icon: const Icon(Icons.upload_file), label: Text('Choose File'))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(onPressed: _takePhoto, icon: const Icon(Icons.camera_alt), label: Text('Upload Photo'))),
        ]),
        const SectionTitle('Health records'),
        if (_selectedFiles.isEmpty)
          const InfoPanel(icon: Icons.folder_open, title: 'No saved records', body: 'Add PDF or image records. Files are copied into RunFuel’s private app storage on this device and are not uploaded.')
        else
          ..._selectedFiles.map((file) => ConnectionTile(name: file['name'] ?? 'Health record', detail: 'Saved privately on this device · not uploaded', icon: Icons.description_outlined)),
        const SectionTitle('Profile categories'),
        ConnectionTile(name: 'Injuries & Limitations', detail: 'Current and previous injuries, restrictions', icon: Icons.healing, onTap: () => _openProfileCategory(context, 'injuries')),
        ConnectionTile(name: 'Blood Tests & Results', detail: 'Dated measurements, units and reference ranges', icon: Icons.science_outlined, onTap: () => _openProfileCategory(context, 'blood_tests')),
        ConnectionTile(name: 'Medical guidance', detail: 'Clinician recommendations and follow-up', icon: Icons.medical_information_outlined, onTap: () => _openProfileCategory(context, 'medical_guidance')),
      ]);
  }
}


void _openProfileCategory(BuildContext context, String category) {
  final definitions = _profileDefinitions[category]!;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ProfileCategoryPage(
      categoryId: category,
      title: definitions.title,
      description: definitions.description,
      fields: definitions.fields,
    ),
  ));
}

class _ProfileDefinition {
  const _ProfileDefinition(this.title, this.description, this.fields);
  final String title;
  final String description;
  final List<String> fields;
}

const Map<String, _ProfileDefinition> _profileDefinitions = {
  'injuries': _ProfileDefinition(
    'Injuries & Limitations',
    'Record current or previous injuries, symptoms and any restrictions relevant to training.',
    ['Injury or condition', 'Current symptoms', 'Body area / side', 'Date started or diagnosed', 'Previous injuries', 'Training limitations or movements to avoid', 'Rehabilitation and recovery notes'],
  ),
  'blood_tests': _ProfileDefinition(
    'Blood Tests & Results',
    'Record results with their dates, units and laboratory reference ranges so values are not taken out of context.',
    ['Test name', 'Test date', 'Result', 'Units', 'Laboratory reference range', 'Laboratory / provider', 'Additional notes'],
  ),
  'medical_guidance': _ProfileDefinition(
    'Medical guidance',
    'Keep clinician advice, activity guidance and follow-up notes together.',
    ['Clinician / provider', 'Appointment or advice date', 'Medical guidance', 'Exercise or activity restrictions', 'Medication or treatment notes (optional)', 'Follow-up date and plan'],
  ),
};

class ProfileCategoryPage extends StatefulWidget {
  const ProfileCategoryPage({
    super.key,
    required this.categoryId,
    required this.title,
    required this.description,
    required this.fields,
  });
  final String categoryId;
  final String title;
  final String description;
  final List<String> fields;

  @override
  State<ProfileCategoryPage> createState() => _ProfileCategoryPageState();
}

class _ProfileCategoryPageState extends State<ProfileCategoryPage> {
  static const _storage = FlutterSecureStorage();
  final Map<String, TextEditingController> _controllers = {};
  bool _loading = true;
  bool _saving = false;
  bool _hasSavedData = false;

  String get _storageKey => 'runfuel_health_profile_${widget.categoryId}';

  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      _controllers[field] = TextEditingController();
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw != null) {
        final values = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in values.entries) {
          _controllers[entry.key]?.text = entry.value?.toString() ?? '';
        }
        _hasSavedData = true;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read the saved profile on this device.')),
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final values = <String, String>{
        for (final entry in _controllers.entries) entry.key: entry.value.text.trim(),
      };
      await _storage.write(key: _storageKey, value: jsonEncode(values));
      if (mounted) {
        setState(() {
          _saving = false;
          _hasSavedData = values.values.any((value) => value.isNotEmpty);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved securely on this device. Nothing has been uploaded or shared.')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save securely. Your entries have not been uploaded.')),
        );
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete this profile section?'),
        content: Text('This permanently deletes the saved entries for this category from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _storage.delete(key: _storageKey);
    for (final controller in _controllers.values) {
      controller.clear();
    }
    if (mounted) {
      setState(() => _hasSavedData = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved profile entries deleted from this device.')),
      );
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              InfoPanel(icon: Icons.lock_outline, title: 'Private on this device', body: widget.description),
              const SizedBox(height: 8),
              ...widget.fields.map((field) {
                final multiline = field.length > 32 || field.contains('notes') || field.contains('guidance') || field.contains('limitations');
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: _controllers[field],
                    minLines: multiline ? 3 : 1,
                    maxLines: multiline ? 5 : 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(labelText: field, alignLabelWithHint: true),
                  ),
                );
              }),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.lock_outline),
                label: Text(_saving ? 'Saving…' : 'Save securely on this device'),
              ),
              if (_hasSavedData) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Delete saved entries'),
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'These entries are not sent to RunFuel, Vercel or an AI model. You will choose what to share if a secure sync and consent feature is added later. This is a record-keeping tool, not a medical diagnosis.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62), fontSize: 12, height: 1.4),
              ),
            ],
          ),
  );
}

class MfpConnectionPage extends StatefulWidget {
  const MfpConnectionPage({super.key, this.syncData});
  final Map<String, dynamic>? syncData;

  @override
  State<MfpConnectionPage> createState() => _MfpConnectionPageState();
}

class _MfpConnectionPageState extends State<MfpConnectionPage> with WidgetsBindingObserver {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _checking = true;
  bool _connected = false;
  bool _showPassword = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await MobileConnectionService().mfpStatus();
      if (mounted) {
        setState(() {
          _connected = status['connected'] == true;
          _message = _connected ? 'Native MyFitnessPal connection is saved securely.' : 'No native MyFitnessPal connection yet.';
          _checking = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _checking = false;
          _message = 'Could not verify the MyFitnessPal connection. Check that your RunFuel backend URL is saved and this device is authorised, then retry. Details: ${error.toString().replaceFirst('Exception: ', '')}';
        });
      }
    }
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() { _busy = true; _message = null; });
    try {
      await MobileConnectionService().connectMfp(_username.text, _password.text);
      _password.clear();
      if (mounted) {
        setState(() {
          _connected = true;
          _message = 'MyFitnessPal connected. Your password was not saved by RunFuel.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() { _busy = true; _message = null; });
    try {
      await MobileConnectionService().disconnectMfp();
      if (mounted) {
        setState(() {
          _connected = false;
          _message = 'Native MyFitnessPal tokens removed from the backend.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTokenManager() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final base = prefs.getString('backend_url')?.trim();
    if (base == null || base.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Save your RunFuel backend URL in Settings first.')));
      return;
    }
    final clean = base.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$clean/settings');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please check your HTTPS backend URL in Settings.')));
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('MyFitnessPal connection')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const InfoPanel(
        icon: Icons.lock_outline,
        title: 'Native read-only connection',
        body: 'This experimental connection signs in through MyFitnessPal’s mobile identity service and reads your diary. RunFuel sends your login details only to your own HTTPS backend for the sign-in exchange. The password is used in memory only and is not stored by RunFuel.',
      ),
      const SizedBox(height: 12),
      ConnectionTile(
        name: 'Native MyFitnessPal session',
        detail: _checking
            ? 'Checking connection…'
            : _connected
                ? 'Connected · encrypted token pair stored on your backend'
                : 'Not connected',
        icon: _checking
            ? Icons.sync
            : _connected
                ? Icons.verified_user_outlined
                : Icons.warning_amber,
      ),
      if (!_connected) ...[
        const SectionTitle('Connect your account'),
        TextField(
          controller: _username,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'MyFitnessPal email or username', prefixIcon: Icon(Icons.person_outline)),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'MyFitnessPal password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          onSubmitted: (_) { if (!_busy) _connect(); },
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: _busy ? const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.link),
          label: Text(_busy ? 'Connecting securely…' : 'Connect MyFitnessPal'),
        ),
      ] else ...[
        const SectionTitle('Manage connection'),
        OutlinedButton.icon(
          onPressed: _busy ? null : _disconnect,
          icon: const Icon(Icons.link_off),
          label: Text('Disconnect MyFitnessPal'),
        ),
      ],
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _busy || _checking ? null : _refreshStatus,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refresh connection status'),
        ),
      ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72), height: 1.4)),
        ),
      const SectionTitle('Existing cookie connection'),
      const InfoPanel(
        icon: Icons.backup_outlined,
        title: 'Keep your current connection available',
        body: 'Your existing MyFitnessPal cookie connection is not removed. If native sign-in is not configured or does not work, you can continue using the existing secure Token Manager method.',
      ),
      OutlinedButton.icon(
        onPressed: _openTokenManager,
        icon: const Icon(Icons.open_in_browser),
        label: Text('Open secure Token Manager'),
      ),
      const SectionTitle('Testing notes'),
      Text(
        'The native mobile API is undocumented and may change. This first test is read-only: it checks sign-in, saves encrypted access/refresh tokens, renews them when needed, and reads diary nutrition. It does not log or edit food, weight, water, or exercise.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .62), height: 1.45, fontSize: 12),
      ),
    ]),
  );
}

class SetupAssistantPage extends StatefulWidget {
  const SetupAssistantPage({super.key});

  @override
  State<SetupAssistantPage> createState() => _SetupAssistantPageState();
}

class _SetupAssistantPageState extends State<SetupAssistantPage> {
  static const _key = 'runfuel_setup_completed_steps';
  static const _steps = [
    ('GitHub repository', 'Use this public repository for the backend and Android app source, then deploy your own copy.', 'https://github.com/minitombo/runfuel-mcp-public'),
    ('Deploy with Vercel', 'Import the public repository into your own Vercel account. Review the project settings before deploying.', 'https://vercel.com/new'),
    ('Create Upstash Redis', 'Create your own Redis database, then connect it to your Vercel project using the Upstash integration. Never reuse someone else’s database.', 'https://console.upstash.com/'),
    ('Configure environment variables', 'Follow the repository setup guide for required variables and encryption settings. Keep all values in Vercel, not in the app or GitHub.', 'https://github.com/minitombo/runfuel-mcp-public'),
    ('Connect Garmin and MyFitnessPal', 'Use your own backend Token Manager to configure credentials. Garmin and MyFitnessPal credentials must remain server-side.', null),
    ('Verify your installation', 'Enter your backend URL in RunFuel Settings and run the backend health check. Provider connectivity needs its own read-only verification.', null),
  ];

  Set<int> _completed = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key) ?? [];
    if (!mounted) return;
    setState(() {
      _completed = saved.map(int.tryParse).whereType<int>().toSet();
      _loaded = true;
    });
  }

  Future<void> _toggle(int index, bool value) async {
    final next = Set<int>.from(_completed);
    value ? next.add(index) : next.remove(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next.map((v) => v.toString()).toList());
    if (mounted) setState(() => _completed = next);
  }

  Future<void> _openStep(String? url) async {
    if (url == null) {
      final prefs = await SharedPreferences.getInstance();
      final base = prefs.getString('backend_url')?.trim();
      if (!mounted) return;
      if (base == null || base.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Save your backend URL in Settings first.')),
        );
        return;
      }
      final cleanBase = base.replaceFirst(RegExp(r'/+$'), '');
      final uri = Uri.tryParse('$cleanBase/settings');
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('RunFuel setup assistant')),
    body: !_loaded
      ? const Center(child: CircularProgressIndicator())
      : ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            InfoPanel(
              icon: Icons.rocket_launch_outlined,
              title: 'Set up your own RunFuel backend',
              body: '${_completed.length} of ${_steps.length} steps marked complete. This assistant guides you through the third-party setup; account creation, authorisation and secret entry remain under your control.',
            ),
            const SectionTitle('Setup checklist'),
            ...List.generate(_steps.length, (index) {
              final step = _steps[index];
              return Card(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _completed.contains(index),
                        onChanged: (value) => _toggle(index, value ?? false),
                        title: Text('${index + 1}. ${step.$1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 48, bottom: 8),
                        child: Text(step.$2, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72), height: 1.4)),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 48),
                        child: TextButton.icon(
                          onPressed: () => _openStep(step.$3),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(step.$3 == null ? 'Open my Token Manager' : 'Open ${step.$1}'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 12),
            const InfoPanel(
              icon: Icons.security_outlined,
              title: 'Security reminder',
              body: 'RunFuel will not ask for your GitHub, Vercel, Upstash or Garmin passwords inside the app. Do not paste API keys or cookies into notes or chat. A future version may automate approved steps through official authorisation flows; this checklist does not provision accounts or deploy projects automatically.',
            ),
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove(_key);
                if (mounted) setState(() => _completed = {});
              },
              child: Text('Reset checklist'),
            ),
          ],
        ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _endpoint = TextEditingController();
  bool _loaded = false;
  bool _checking = false;
  bool _connecting = false;
  bool _runFuelAuthorised = false;
  bool _mfpConnected = false;
  bool _mfpChecking = true;
  bool _mfpStatusKnown = false;
  String? _healthStatus;
  String? _connectionStatus;
  String _primaryTrainingFocus = 'running';
  List<String> _trainingModes = ['running'];

  static const _trainingFocusOptions = <String, String>{
    'running': 'Running',
    'cycling': 'Cycling',
    'swimming': 'Swimming',
    'strength': 'Gym / strength training',
    'triathlon': 'Triathlon',
    'team_sports': 'Team sports',
    'walking_hiking': 'Walking / hiking',
    'mobility': 'Mobility / yoga / Pilates',
    'general_fitness': 'General fitness',
    'lifestyle': 'Active lifestyle / wellbeing',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString('backend_url') ?? '').trim();
    final primary = prefs.getString('primary_training_focus') ?? 'running';
    final modes = prefs.getStringList('training_modes') ?? [primary];
    // Keep the backend field empty until the user enters their own server URL.
    _endpoint.text = saved;
    final authorised = await MobileConnectionService().isAuthorized();
    if (mounted) {
      setState(() {
        _runFuelAuthorised = authorised;
        _primaryTrainingFocus = _trainingFocusOptions.containsKey(primary) ? primary : 'running';
        _trainingModes = modes.where(_trainingFocusOptions.containsKey).toList();
        if (_trainingModes.isEmpty) _trainingModes = [_primaryTrainingFocus];
        _loaded = true;
      });
      if (saved.isNotEmpty) _checkBackend();
      _checkMfpConnection();
    }
  }

  Future<void> _checkMfpConnection() async {
    if (!_runFuelAuthorised) {
      if (mounted) {
        setState(() {
          _mfpConnected = false;
          _mfpStatusKnown = false;
          _mfpChecking = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _mfpChecking = true);
    try {
      final status = await MobileConnectionService().mfpStatus();
      if (mounted) {
        setState(() {
          _mfpConnected = status['connected'] == true;
          _mfpStatusKnown = true;
          _mfpChecking = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _mfpConnected = false;
          _mfpStatusKnown = false;
          _mfpChecking = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final value = _endpoint.text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid HTTPS backend URL.')));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final previous = (prefs.getString('backend_url') ?? '').trim();
    if (previous.isNotEmpty && previous != value) {
      // Preserve the device credentials when the backend URL changes.
      // A server switch must not silently log the user out or erase the
      // registered OAuth client. The next authenticated request will verify
      // whether the existing authorisation is valid for the selected server.
      if (mounted) {
        setState(() {
          _connectionStatus = 'Backend URL changed. Existing sign-in has been preserved and will be checked on the next sync.';
        });
      }
    }
    await prefs.setString('backend_url', value);
    if (mounted) {
      setState(() => _healthStatus = null);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backend URL saved on this device.')));
      _checkBackend();
    }
  }
  Future<void> _checkBackend() async {
    final base = _endpoint.text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(base);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save a valid HTTPS backend URL first.')),
      );
      return;
    }
    setState(() => _checking = true);
    final result = await const BackendHealthService().check(base);
    if (mounted) {
      setState(() {
        _checking = false;
        _healthStatus = result;
      });
    }
  }

  Future<void> _connectRunFuel() async {
    setState(() { _connecting = true; _connectionStatus = null; });
    try {
      await MobileConnectionService().connect();
      if (mounted) setState(() { _runFuelAuthorised = true; _connectionStatus = 'Connected. Your RunFuel backend is authorised on this device.'; });
    } catch (e) {
      if (mounted) setState(() => _connectionStatus = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _logOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Logout of RunFuel?'),
        content: Text('This removes the RunFuel sign-in from this device. Your account, backend setup, saved training data and MyFitnessPal connection will remain intact.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text('Logout')),
        ],
      ),
    );
    if (confirmed != true) return;
    await MobileConnectionService().disconnect();
    if (!mounted) return;
    setState(() {
      _runFuelAuthorised = false;
      _connectionStatus = 'Logged out on this device. Your RunFuel data has not been deleted.';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('You have been logged out of RunFuel on this device.')),
    );
  }

  Future<void> _openExternal(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _openSettings() async {
    final base = _endpoint.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save your backend URL first.')),
      );
      return;
    }
    await _openExternal('$base/settings');
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageBody(key: const Key('settings-page-body'), children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Appearance'),
              const InfoPanel(icon: Icons.palette_outlined, title: 'Make RunFuel yours', body: 'Choose system light/dark mode or a soft colour theme. Your choice is saved on this phone.'),
              DropdownButtonFormField<String>(
                key: const Key('runfuel-appearance-choice'),
                initialValue: RunFuelAppearance.choice.value,
                decoration: const InputDecoration(labelText: 'App theme', prefixIcon: Icon(Icons.palette_outlined)),
                items: RunFuelAppearance.options.entries.map((entry) =>
                  DropdownMenuItem<String>(value: entry.key, child: Text(entry.value))
                ).toList(),
                onChanged: (value) async {
                  if (value == null) return;
                  RunFuelAppearance.choice.value = value;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(RunFuelAppearance.preferenceKey, value);
                },
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionTitle('Training preferences'),
              const InfoPanel(
                icon: Icons.fitness_center,
                title: 'Make RunFuel multi-sport',
                body: 'Choose your main focus and every activity you want included. RunFuel is being expanded beyond running to support gym work, other sports, mobility and everyday wellbeing.',
              ),
              DropdownButtonFormField<String>(
                key: const Key('runfuel-primary-training-focus'),
                initialValue: _primaryTrainingFocus,
                decoration: const InputDecoration(labelText: 'Primary training focus', prefixIcon: Icon(Icons.flag_outlined)),
                items: _trainingFocusOptions.entries.map((entry) =>
                  DropdownMenuItem<String>(value: entry.key, child: Text(entry.value))
                ).toList(),
                onChanged: (value) async {
                  if (value == null) return;
                  final prefs = await SharedPreferences.getInstance();
                  setState(() {
                    _primaryTrainingFocus = value;
                    if (!_trainingModes.contains(value)) _trainingModes = [..._trainingModes, value];
                  });
                  await prefs.setString('primary_training_focus', value);
                  await prefs.setStringList('training_modes', _trainingModes);
                },
              ),
              const SizedBox(height: 8),
              Text('Include these training modes', style: Theme.of(context).textTheme.titleSmall),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _trainingFocusOptions.entries.map((entry) => FilterChip(
                  label: Text(entry.value),
                  selected: _trainingModes.contains(entry.key),
                  onSelected: (selected) async {
                    final next = [..._trainingModes];
                    if (selected) {
                      if (!next.contains(entry.key)) next.add(entry.key);
                    } else if (next.length > 1 && entry.key != _primaryTrainingFocus) {
                      next.remove(entry.key);
                    }
                    final prefs = await SharedPreferences.getInstance();
                    setState(() => _trainingModes = next);
                    await prefs.setStringList('training_modes', next);
                  },
                )).toList(),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const InfoPanel(icon: Icons.settings, title: 'Connection setup', body: 'RunFuel is designed to use your own public-repository deployment. No maintainer credentials or shared backend are built into this app.'),
        const SectionTitle('Your backend'),
        TextField(
          controller: _endpoint,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Backend Base URL',
            hintText: 'Paste your HTTPS backend URL',
            prefixIcon: Icon(Icons.cloud_outlined),
          ),
          onChanged: (_) {
            if (_healthStatus != null) setState(() => _healthStatus = null);
          },
        ),
        const SizedBox(height: 10),
        ConnectionTile(
          name: 'Backend connection',
          detail: _checking ? 'Checking server…' : (_healthStatus ?? 'Not checked yet'),
          icon: _healthStatus?.contains('reachable') == true
              ? Icons.cloud_done_outlined
              : _checking ? Icons.sync : Icons.cloud_off_outlined,
        ),
        FilledButton.icon(onPressed: _loaded ? _save : null, icon: const Icon(Icons.save_outlined), label: Text('Save Backend URL')),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: _openSettings, icon: const Icon(Icons.open_in_new), label: Text('Open Token Manager')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _loaded && !_checking ? _checkBackend : null,
          icon: const Icon(Icons.wifi_tethering),
          label: Text(_checking ? 'Checking backend…' : 'Check Backend Health'),
        ),
        if (_healthStatus != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_healthStatus!, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72))),
          ),
        const SectionTitle('Secure data connection'),
        const InfoPanel(icon: Icons.lock_outline, title: 'Authorise this app', body: 'Sign in with your RunFuel access password to allow this device to read Garmin and MyFitnessPal data from your own backend. Garmin and MyFitnessPal passwords are not entered here.'),
        const SizedBox(height: 8),
        if (_runFuelAuthorised)
          ConnectionTile(name: 'RunFuel data', detail: 'Connected · this device is authorised', icon: Icons.verified_outlined)
        else
          FilledButton.icon(
            onPressed: _loaded && !_connecting ? _connectRunFuel : null,
            icon: _connecting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link),
            label: Text(_connecting ? 'Opening secure sign-in…' : 'Connect RunFuel Data'),
          ),
        if (_connectionStatus != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(_connectionStatus!, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .72)))),
        OutlinedButton.icon(
          key: const Key('settings-mfp-connection-button'),
          // Show the real native-session state instead of always prompting
          // users to connect an account that is already connected.
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MfpConnectionPage()),
            );
            _checkMfpConnection();
          },
          icon: Icon(_mfpChecking
              ? Icons.sync
              : _mfpConnected
                  ? Icons.verified_user_outlined
                  : Icons.restaurant_outlined),
          label: Text(_mfpChecking
              ? 'Checking MyFitnessPal…'
              : _mfpConnected
                  ? 'Disconnect MyFitnessPal'
                  : _runFuelAuthorised && !_mfpStatusKnown
                      ? 'MyFitnessPal Status Unavailable · Retry'
                      : 'Connect MyFitnessPal'),
        ),
        if (_mfpStatusKnown && _mfpConnected)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Your encrypted MyFitnessPal token session is connected.'),
          ),
        const SectionTitle('Deployment setup'),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SetupAssistantPage()),
          ),
          icon: const Icon(Icons.checklist_outlined),
          label: Text('Guided First-Time Setup'),
        ),
        OutlinedButton.icon(
          onPressed: () => _openExternal('https://github.com/minitombo/runfuel-mcp-public'),
          icon: const Icon(Icons.code),
          label: Text('Open Canonical GitHub Repository'),
        ),
        OutlinedButton.icon(
          onPressed: () => _openExternal('https://vercel.com/new'),
          icon: const Icon(Icons.rocket_launch),
          label: Text('Deploy Your Own RunFuel on Vercel'),
        ),
        const SectionTitle('Security'),
        const InfoPanel(icon: Icons.lock_outline, title: 'Secrets are not embedded', body: 'No maintainer API keys or backend credentials are embedded in the app. Your optional Gemini API key is stored in Android secure storage and sent directly to Google only after you approve each request. Garmin and MyFitnessPal credentials remain server-side. In-app AI requests go directly from this phone to Google Gemini after your approval.'),
        const SectionTitle('Account'),
        if (_runFuelAuthorised)
          OutlinedButton.icon(
            key: const Key('runfuel-logout-button'),
            onPressed: _logOut,
            icon: const Icon(Icons.logout),
            label: Text('Logout of RunFuel'),
          )
        else
          const InfoPanel(icon: Icons.person_outline, title: 'Not signed in', body: 'Connect RunFuel data above to authorise this device. Logging out does not delete your account or saved data.'),
        const SizedBox(height: 8),
        const SectionTitle('Sync policy'),
        const ConnectionTile(name: 'Manual only', detail: 'No automatic sync or background polling', icon: Icons.sync),
        const ConnectionTile(name: 'GPS Tracks', detail: 'Only retrieve when you explicitly request route analysis', icon: Icons.route),
      ]);
}