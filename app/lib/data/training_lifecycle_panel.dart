import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:share_plus/share_plus.dart';

import 'runfuel_database.dart';

const _green = Color(0xFF9BE15D);

/// Training lifecycle, event priorities, daily check-ins and calendar export.
/// All changes are local until the user explicitly exports or approves them.
class TrainingLifecyclePanel extends StatefulWidget {
  const TrainingLifecyclePanel({super.key});

  @override
  State<TrainingLifecyclePanel> createState() => _TrainingLifecyclePanelState();
}

class _TrainingLifecyclePanelState extends State<TrainingLifecyclePanel> {
  bool _loading = true;
  bool _loadFailed = false;
  bool _returnPlanReview = false;
  List<Map<String, Object?>> _events = [];
  List<Map<String, Object?>> _pauses = [];
  List<Map<String, Object?>> _workouts = [];
  Map<String, Object?>? _todayReview;
  Map<String, Object?>? _latestSleep;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _pauseReasonLabel(Object? value) {
    switch (value?.toString()) {
      case 'illness': return 'Illness';
      case 'injury': return 'Injury';
      case 'fatigue': return 'Fatigue / recovery';
      case 'family_work': return 'Family / work commitments';
      case 'holiday': return 'Holiday / travel';
      case 'motivation': return 'Motivation / personal break';
      default: return 'Other / prefer not to say';
    }
  }

  String _today() => DateTime.now().toIso8601String().substring(0, 10);
  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<void> _load() async {
    try {
    final db = await RunFuelDatabase.instance.database;
    final today = _today();
    final events = await db.query('training_events',
      where: "status = 'active' AND (event_date IS NULL OR event_date >= ? OR recurrence IS NOT NULL)",
      whereArgs: [today], orderBy: 'event_date ASC', limit: 20);
    final pauses = await db.query('training_pauses',
      where: "status = 'active'", orderBy: 'start_date DESC', limit: 5);
    final needsReviewPlans = await db.query('training_plans',
      where: "status = 'needs_review'", limit: 1);
    final returnRequired = await db.query('planned_workouts',
      where: "status = 'replan_required'", limit: 1);
    var returningAfterPause = false;
    final lastPause = await db.query('training_pauses',
      where: "status = 'completed' AND end_date IS NOT NULL",
      orderBy: 'end_date DESC', limit: 1);
    if (lastPause.isNotEmpty) {
      final pauseEnd = lastPause.first['end_date']?.toString();
      if (pauseEnd != null) {
        final postPauseRuns = await db.query('activities',
          where: "sport = 'running' AND started_at >= ?", whereArgs: [pauseEnd]);
        returningAfterPause = postPauseRuns.length < 3;
      }
    }
    final workouts = await db.query('planned_workouts',
      where: "status = 'planned' AND scheduled_at >= ?",
      whereArgs: [today], orderBy: 'scheduled_at ASC', limit: 100);
    final reviews = await db.query('daily_reviews',
      where: 'review_date = ?', whereArgs: [today], limit: 1);
    final sleep = await db.query('sleep_records',
      orderBy: 'sleep_date DESC', limit: 1);
    if (!mounted) return;
    setState(() {
      _events = events;
      _pauses = pauses;
      _returnPlanReview = needsReviewPlans.isNotEmpty || returnRequired.isNotEmpty || returningAfterPause;
      _workouts = workouts;
      _todayReview = reviews.isEmpty ? null : reviews.first;
      _latestSleep = sleep.isEmpty ? null : sleep.first;
      _loading = false;
    });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _addEvent() async {
    final title = TextEditingController();
    final distance = TextEditingController();
    final notes = TextEditingController();
    DateTime? date;
    String priority = 'B';
    String goal = 'finish';
    String kind = 'race';
    bool recurringParkrun = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Add an event or goal'),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(context: ctx, initialDate: DateTime.now().add(const Duration(days: 30)), firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
                if (picked != null) setDialog(() => date = picked);
              },
              icon: const Icon(Icons.event),
              label: Text(date == null ? 'Choose date (optional for ongoing goals)' : '${date!.day}/${date!.month}/${date!.year}'),
            ),
            TextField(controller: distance, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Distance (km, optional)')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(initialValue: priority, decoration: const InputDecoration(labelText: 'Priority'), items: const [
              DropdownMenuItem(value: 'A', child: Text('A · Main goal')),
              DropdownMenuItem(value: 'B', child: Text('B · Secondary goal')),
              DropdownMenuItem(value: 'C', child: Text('C · Low pressure / fun')),
            ], onChanged: (v) => setDialog(() => priority = v ?? 'B')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(initialValue: goal, decoration: const InputDecoration(labelText: 'Goal'), items: const [
              DropdownMenuItem(value: 'finish', child: Text('Complete comfortably')),
              DropdownMenuItem(value: 'time', child: Text('Target a time')),
              DropdownMenuItem(value: 'participate', child: Text('Participate / enjoy')),
              DropdownMenuItem(value: 'fitness', child: Text('General fitness')),
              DropdownMenuItem(value: 'maintain', child: Text('Maintain fitness')),
            ], onChanged: (v) => setDialog(() => goal = v ?? 'finish')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(initialValue: kind, decoration: const InputDecoration(labelText: 'Type'), items: const [
              DropdownMenuItem(value: 'race', child: Text('Race / event')),
              DropdownMenuItem(value: 'parkrun', child: Text('Parkrun / regular event')),
              DropdownMenuItem(value: 'personal', child: Text('Personal goal')),
            ], onChanged: (v) => setDialog(() => kind = v ?? 'race')),
            if (kind == 'parkrun') CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: recurringParkrun,
              title: const Text('Every Saturday'),
              onChanged: (v) => setDialog(() => recurringParkrun = v ?? false),
            ),
            TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes (optional)')),
          ],
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save event')),
        ],
      )),
    );
    if (result != true || title.text.trim().isEmpty) {
      title.dispose(); distance.dispose(); notes.dispose(); return;
    }
    final km = double.tryParse(distance.text.trim());
    final db = await RunFuelDatabase.instance.database;
    final now = _now();
    await db.insert('training_events', {
      'id': 'event_${DateTime.now().microsecondsSinceEpoch}',
      'title': title.text.trim(),
      'event_date': date?.toIso8601String().substring(0, 10),
      'distance_m': km != null && km > 0 ? km * 1000 : null,
      'goal_type': goal,
      'priority': priority,
      'event_kind': kind,
      'recurrence': recurringParkrun ? 'weekly:saturday' : null,
      'status': 'active',
      'notes': notes.text.trim(),
      'created_at': now,
      'updated_at': now,
    });
    title.dispose(); distance.dispose(); notes.dispose();
    await _load();
  }

  Future<void> _pauseTraining() async {
    String reason = 'illness';
    final notes = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Pause training'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('A pause is part of training, not a failure. You can return whenever you are ready.', style: TextStyle(height: 1.4)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: reason, decoration: const InputDecoration(labelText: 'Reason'), items: const [
            DropdownMenuItem(value: 'illness', child: Text('Illness')),
            DropdownMenuItem(value: 'injury', child: Text('Injury')),
            DropdownMenuItem(value: 'fatigue', child: Text('Fatigue / recovery')),
            DropdownMenuItem(value: 'family_work', child: Text('Family / work commitments')),
            DropdownMenuItem(value: 'holiday', child: Text('Holiday / travel')),
            DropdownMenuItem(value: 'motivation', child: Text('Motivation / personal break')),
            DropdownMenuItem(value: 'other', child: Text('Other / prefer not to say')),
          ], onChanged: (v) => setDialog(() => reason = v ?? 'other')),
          const SizedBox(height: 10),
          TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Optional context')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pause plan')),
        ],
      )),
    );
    if (result != true) { notes.dispose(); return; }
    final db = await RunFuelDatabase.instance.database;
    final now = _now();
    await db.insert('training_pauses', {
      'id': 'pause_${DateTime.now().microsecondsSinceEpoch}',
      'start_date': _today(),
      'reason': reason,
      'notes': notes.text.trim(),
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
    await db.update('training_plans', {'status': 'paused', 'updated_at': now}, where: "status = 'active'");
    await db.update('planned_workouts', {'status': 'paused', 'updated_at': now},
      where: "status = 'planned' AND scheduled_at >= ?", whereArgs: [_today()]);
    notes.dispose();
    await _load();
  }

  Future<void> _resumeTraining(Map<String, Object?> pause) async {
    final notes = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Return to training'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('RunFuel will mark the old upcoming sessions for review rather than asking you to catch up. Reassess how you feel before restarting, especially after illness or injury.', style: TextStyle(height: 1.4)),
          const SizedBox(height: 12),
          TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'How are you feeling / what has changed?')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start return review')),
        ],
      ),
    );
    if (result != true) { notes.dispose(); return; }
    final db = await RunFuelDatabase.instance.database;
    final now = _now();
    await db.update('training_pauses', {
      'status': 'completed', 'end_date': _today(),
      'return_notes': notes.text.trim(), 'updated_at': now,
    }, where: 'id = ?', whereArgs: [pause['id']]);
    await db.update('training_plans', {'status': 'needs_review', 'updated_at': now}, where: "status = 'paused'");
    await db.update('planned_workouts', {'status': 'replan_required', 'updated_at': now},
      where: "status = 'paused' AND scheduled_at >= ?", whereArgs: [_today()]);
    notes.dispose();
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Training is marked for a return-to-training review. Old sessions will not be treated as missed workouts.')));
  }

  String _icsEscape(String value) => value.replaceAll('\\', '\\\\').replaceAll(';', '\\;').replaceAll(',', '\\,').replaceAll('\n', '\\n');

  Future<void> _exportCalendar() async {
    final db = await RunFuelDatabase.instance.database;
    final events = await db.query('training_events',
      where: "status = 'active' AND (event_date IS NULL OR event_date >= ? OR recurrence IS NOT NULL)",
      whereArgs: [_today()], orderBy: 'event_date ASC');
    if (_workouts.isEmpty && events.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('There are no upcoming sessions or events to export.')));
      return;
    }
    final eventDates = events.map((e) => e['event_date']?.toString()).whereType<String>().toSet();
    final hasRecurringSaturday = events.any((e) => e['recurrence'] == 'weekly:saturday');
    final buffer = StringBuffer('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//RunFuel//Training Plan//EN\r\nCALSCALE:GREGORIAN\r\nMETHOD:PUBLISH\r\nX-WR-CALNAME:RunFuel Training\r\n');
    String stamp(DateTime d) => '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    String dtstamp() => '${DateTime.now().toUtc().toIso8601String().replaceAll('-', '').replaceAll(':', '').split('.').first}Z';
    for (final workout in _workouts) {
      final raw = DateTime.tryParse(workout['scheduled_at']?.toString() ?? '');
      if (raw == null) continue;
      final date = DateTime(raw.year, raw.month, raw.day);
      final dateKey = date.toIso8601String().substring(0, 10);
      if (eventDates.contains(dateKey) || (hasRecurringSaturday && date.weekday == DateTime.saturday)) continue;
      final next = date.add(const Duration(days: 1));
      final title = _icsEscape(workout['title']?.toString() ?? 'RunFuel training');
      final description = _icsEscape(workout['description']?.toString() ?? '');
      final km = workout['target_distance_m'] is num ? ' · ${((workout['target_distance_m'] as num) / 1000).toStringAsFixed(1)} km' : '';
      buffer.write('BEGIN:VEVENT\r\nUID:${workout['id']}@runfuel\r\nDTSTAMP:${dtstamp()}\r\nDTSTART;VALUE=DATE:${stamp(date)}\r\nDTEND;VALUE=DATE:${stamp(next)}\r\nSUMMARY:${_icsEscape(title + km)}\r\nDESCRIPTION:$description\r\nEND:VEVENT\r\n');
    }
    for (final event in events) {
      final rawDate = DateTime.tryParse(event['event_date']?.toString() ?? '');
      final recurring = event['recurrence'] == 'weekly:saturday';
      if (rawDate == null && !recurring) continue;
      final startDate = rawDate ?? DateTime.now();
      final endDate = startDate.add(const Duration(days: 1));
      final distance = event['distance_m'] is num ? ' · ${((event['distance_m'] as num) / 1000).toStringAsFixed(1)} km' : '';
      buffer.write('BEGIN:VEVENT\r\nUID:${event['id']}@runfuel\r\nDTSTAMP:${dtstamp()}\r\nDTSTART;VALUE=DATE:${stamp(startDate)}\r\nDTEND;VALUE=DATE:${stamp(endDate)}\r\nSUMMARY:${_icsEscape(event['title']?.toString() ?? 'RunFuel event')}$distance\r\n');
      if (recurring) buffer.write('RRULE:FREQ=WEEKLY;BYDAY=SA\r\n');
      buffer.write('END:VEVENT\r\n');
    }
    buffer.write('END:VCALENDAR\r\n');
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/runfuel-training.ics');
    await file.writeAsString(buffer.toString(), flush: true);
    await Share.shareXFiles([XFile(file.path, mimeType: 'text/calendar')], subject: 'RunFuel training calendar');
  }

  Future<void> _reviewToday() async {
    final db = await RunFuelDatabase.instance.database;
    final start = DateTime.parse(_today());
    final end = start.add(const Duration(days: 1));
    final activities = await db.query('activities',
      where: 'started_at >= ? AND started_at < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()]);
    final runKm = activities.fold<double>(0, (sum, row) {
      final distance = row['distance_m'];
      return sum + (distance is num ? distance.toDouble() / 1000 : 0);
    });
    final nutritionRows = await db.query('nutrition_days', where: 'day = ?', whereArgs: [_today()], limit: 1);
    final nutrition = nutritionRows.isEmpty ? null : nutritionRows.first;
    final recoveryRows = await db.query('health_measurements',
      where: "category = 'recovery' AND measured_at = ?",
      whereArgs: [_today()],
      orderBy: 'measured_at DESC', limit: 20);
    final recoverySummary = recoveryRows.map((r) =>
      '${r['metric']}: ${r['value'] ?? 'n/a'} ${r['unit'] ?? ''}'.trim()).join(' · ');
    final energy = ValueNotifier<int>(3);
    final soreness = ValueNotifier<int>(2);
    final mood = ValueNotifier<int>(3);
    final notes = TextEditingController(text: _todayReview?['notes']?.toString() ?? '');
    if (!mounted) { energy.dispose(); soreness.dispose(); mood.dispose(); notes.dispose(); return; }
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Review my day'),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Today so far: ${activities.length} recorded activities · ${runKm.toStringAsFixed(1)} km. '
              '${nutrition == null ? 'No MyFitnessPal diary saved for today.' : 'Food diary: ${nutrition['calories'] ?? 'n/a'} kcal · ${nutrition['carbs_g'] ?? 'n/a'} g carbs · ${nutrition['protein_g'] ?? 'n/a'} g protein.'} '
              '${_latestSleep?['total_sleep_s'] is num ? 'Latest sleep: ${((_latestSleep!['total_sleep_s'] as num) / 3600).toStringAsFixed(1)} hours.' : 'Sleep data unavailable.'} '
              '${recoverySummary.isEmpty ? 'Recovery readings unavailable.' : 'Recovery: $recoverySummary.'}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            _ratingControl('Energy', energy, const ['Exhausted','Low','Okay','Good','Excellent']),
            _ratingControl('Soreness', soreness, const ['None','Mild','Moderate','High','Severe']),
            _ratingControl('Mood', mood, const ['Very low','Low','Okay','Good','Great']),
            const SizedBox(height: 10),
            TextField(controller: notes, maxLines: 4, decoration: const InputDecoration(labelText: 'Anything the watch cannot know? (illness, injury, stress, family, sleep disruption…)')),
          ],
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save review')),
        ],
      ),
    );
    if (result == true) {
      final now = _now();
      final sleep = _latestSleep?['total_sleep_s'];
      final summary = _reviewSummary(energy.value, soreness.value, mood.value, sleep, runKm, nutrition, recoverySummary);
      await db.insert('daily_reviews', {
        'id': 'review_${_today()}',
        'review_date': _today(),
        'energy': energy.value,
        'soreness': soreness.value,
        'mood': mood.value,
        'sleep_quality': _latestSleep?['sleep_score'],
        'notes': notes.text.trim(),
        'coach_summary': summary,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _load();
    }
    energy.dispose(); soreness.dispose(); mood.dispose(); notes.dispose();
  }

  String _reviewSummary(int energy, int soreness, int mood, Object? sleep, double runKm, Map<String, Object?>? nutrition, String recoverySummary) {
    final sleepHours = sleep is num ? sleep.toDouble() / 3600 : null;
    final signals = <String>[];
    final observations = <String>[];
    if (sleepHours != null) {
      observations.add('Sleep: ${sleepHours.toStringAsFixed(1)} hours');
      if (sleepHours < 6.5) signals.add('Sleep was shorter than 6.5 hours');
    } else {
      observations.add('Sleep: unavailable');
    }
    if (runKm > 0) observations.add('Recorded activity: ${runKm.toStringAsFixed(1)} km');
    if (recoverySummary.isNotEmpty) observations.add('Recovery readings: $recoverySummary');
    if (nutrition != null) {
      observations.add('Diary: ${nutrition['calories'] ?? 'n/a'} kcal, ${nutrition['carbs_g'] ?? 'n/a'} g carbs, ${nutrition['protein_g'] ?? 'n/a'} g protein');
    } else {
      observations.add('Food diary: no saved entry; intake is unknown, not zero');
    }
    if (energy <= 2) signals.add('Energy was low');
    if (soreness >= 4) signals.add('Soreness was high');
    if (mood <= 2) signals.add('Mood was low');
    final context = observations.join('. ');
    if (signals.isEmpty) return '$context. Your check-in looks broadly positive. Keep the next session aligned with the plan and how you feel tomorrow.';
    return '$context. ${signals.join('. ')}. Consider an easier session or extra recovery if these signals persist. Your symptoms and judgement matter more than a watch score.';
  }

  Widget _ratingControl(String label, ValueNotifier<int> value, List<String> labels) => ValueListenableBuilder<int>(
    valueListenable: value,
    builder: (context, selected, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(labels[selected - 1], style: const TextStyle(color: _green)),
      ]),
      Slider(value: selected.toDouble(), min: 1, max: 5, divisions: 4, onChanged: (v) => value.value = v.round()),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    if (_loading) return Card(child: Padding(padding: const EdgeInsets.all(20), child: Center(child: Text('Loading Training Status…', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6))))));
    if (_loadFailed) return Card(child: Padding(padding: const EdgeInsets.all(16), child: Text('Training history is not available yet. Sync or reopen RunFuel after local data storage has initialized.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76)))));
    final activePause = _pauses.isNotEmpty ? _pauses.first : null;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(padding: const EdgeInsets.all(15), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.tune, color: _green),
            SizedBox(width: 8),
            Text('Your Training, Adapted to Real Life', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          if (activePause != null) ...[
            const Chip(avatar: Icon(Icons.pause_circle_outline), label: Text('Training paused')),
            Text('Reason: ${_pauseReasonLabel(activePause['reason'])}. Your plan is preserved; upcoming sessions are not counted as missed.'),
            const SizedBox(height: 8),
            FilledButton.icon(onPressed: () => _resumeTraining(activePause), icon: const Icon(Icons.play_arrow), label: const Text('Review return to training')),
          ] else if (_returnPlanReview) ...[
            const Chip(avatar: Icon(Icons.restart_alt), label: Text('Returning to training · review required')),
            Text('Your old sessions are retained, not missed. Build a fresh block using your current comfortable distance; RunFuel will not reuse pre-pause fitness figures until it has enough new activity history.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), height: 1.35)),
            OutlinedButton.icon(onPressed: _pauseTraining, icon: const Icon(Icons.pause), label: const Text('Pause again')),
          ] else ...[
            const Chip(avatar: Icon(Icons.directions_run), label: Text('Training Active')),
            OutlinedButton.icon(onPressed: _pauseTraining, icon: const Icon(Icons.pause), label: const Text('Pause training')),
          ],
          const Divider(height: 22),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Events & Goals', style: TextStyle(fontWeight: FontWeight.w800)),
            TextButton.icon(onPressed: _addEvent, icon: const Icon(Icons.add, size: 18), label: const Text('Add')),
          ]),
          if (_events.isEmpty) Text('No events yet. Add a race, parkrun or personal fitness goal—or train without an event.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76))),
          ..._events.map((event) {
            final km = event['distance_m'] is num ? ' · ${((event['distance_m'] as num) / 1000).toStringAsFixed(1)} km' : '';
            final date = event['event_date']?.toString();
            final repeat = event['recurrence'] == 'weekly:saturday' ? ' · Every Saturday' : '';
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(backgroundColor: _green.withValues(alpha: .15), child: Text(event['priority']?.toString() ?? 'B', style: const TextStyle(color: _green, fontWeight: FontWeight.bold))),
              title: Text(event['title']?.toString() ?? 'Goal'),
              subtitle: Text('${date ?? 'Ongoing'}$km$repeat · ${event['goal_type']}'),
              trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Archive goal', onPressed: () async {
                final db = await RunFuelDatabase.instance.database;
                await db.update('training_events', {'status': 'archived', 'updated_at': _now()}, where: 'id = ?', whereArgs: [event['id']]);
                await _load();
              }),
            );
          }),
          const Divider(height: 22),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Daily Check-In', style: TextStyle(fontWeight: FontWeight.w800)),
            TextButton.icon(onPressed: _reviewToday, icon: const Icon(Icons.rate_review_outlined, size: 18), label: Text(_todayReview == null ? 'Review my day' : 'Update review')),
          ]),
          if (_todayReview != null) Text(_todayReview!['coach_summary']?.toString() ?? 'Your daily review is saved.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), height: 1.35)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: _exportCalendar, icon: const Icon(Icons.ios_share), label: const Text('Export calendar'))),
            const SizedBox(width: 8),
            Expanded(child: Text('${_workouts.length} Upcoming Sessions', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6), fontSize: 12))),
          ]),
          const SizedBox(height: 4),
          Text('Calendar export creates an .ics file for your phone share sheet. Import it into your calendar app. RunFuel remains the source of truth; exporting never edits your personal calendar.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .54), fontSize: 11, height: 1.3)),
        ],
      )),
    );
  }
}
