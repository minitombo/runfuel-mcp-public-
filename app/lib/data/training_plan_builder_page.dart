import 'package:flutter/material.dart';

import 'runfuel_database.dart';

/// Creates an editable, user-sized easy-running block. Nothing is written to
/// the local calendar until the user reviews and approves the preview.
class TrainingPlanBuilderPage extends StatefulWidget {
  const TrainingPlanBuilderPage({super.key});

  @override
  State<TrainingPlanBuilderPage> createState() => _TrainingPlanBuilderPageState();
}

class _TrainingPlanBuilderPageState extends State<TrainingPlanBuilderPage> {
  final _weeklyKm = TextEditingController(text: '10');
  final _currentLongRunKm = TextEditingController(text: '5');
  final _maxHr = TextEditingController();
  final _restingHr = TextEditingController();
  final _customNotes = TextEditingController();
  int _sessions = 3;
  int _durationWeeks = 4;
  DateTime? _eventDate;
  final _eventName = TextEditingController();
  int _longRunGoal = 8;
  bool _saturdayParkrun = false;
  bool _useHrTargets = false;
  String _hrZone = 'Zone 2';
  bool _generating = false;
  List<_PlannedSession> _preview = [];
  bool _saving = false;
  bool _trainingPaused = false;
  bool _returningAfterPause = false;
  String? _notice;
  List<Map<String, Object?>> _events = [];

  @override
  void initState() {
    super.initState();
    _loadRecentVolume();
  }

  Future<void> _loadRecentVolume() async {
    try {
      final db = await RunFuelDatabase.instance.database;
      _events = await db.query('training_events', where: "status = 'active'", orderBy: 'event_date ASC, priority ASC', limit: 20);
      final activePauses = await db.query('training_pauses',
        where: "status = 'active'", orderBy: 'start_date DESC', limit: 1);
      if (activePauses.isNotEmpty) {
        _trainingPaused = true;
        _notice = 'Training is currently paused. Complete the return-to-training review before creating a new plan.';
        if (mounted) setState(() {});
        return;
      }
      final completedPauses = await db.query('training_pauses',
        where: "status = 'completed' AND end_date IS NOT NULL",
        orderBy: 'end_date DESC', limit: 1);
      if (completedPauses.isNotEmpty) {
        final pauseEnd = completedPauses.first['end_date']?.toString();
        final sincePause = pauseEnd == null ? <Map<String, Object?>>[] : await db.query(
          'activities',
          columns: ['distance_m'],
          where: "sport = 'running' AND started_at >= ?",
          whereArgs: [pauseEnd],
        );
        if (sincePause.length < 3) {
          _returningAfterPause = true;
          _weeklyKm.clear();
          _currentLongRunKm.clear();
          if (mounted) setState(() {});
          return;
        }
      }
      var volumeStart = DateTime.now().subtract(const Duration(days: 28));
      if (completedPauses.isNotEmpty) {
        final pauseEnd = DateTime.tryParse(completedPauses.first['end_date']?.toString() ?? '');
        if (pauseEnd != null && pauseEnd.isAfter(volumeStart)) volumeStart = pauseEnd;
      }
      final rows = await db.query(
        'activities',
        columns: ['distance_m'],
        where: "sport = 'running' AND started_at >= ?",
        whereArgs: [volumeStart.toIso8601String()],
      );
      final total = rows.fold<double>(0, (sum, row) {
        final value = row['distance_m'];
        return sum + (value is num ? value.toDouble() / 1000 : 0);
      });
      final days = DateTime.now().difference(volumeStart).inDays;
      final weeks = days < 7 ? 1.0 : days / 7.0;
      if (rows.isNotEmpty && mounted) {
        _weeklyKm.text = (total / weeks).toStringAsFixed(1);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Editable starting-volume fields remain available if local history is empty.
    }
  }

  DateTime _nextMonday() {
    final today = DateTime.now();
    final days = (DateTime.monday - today.weekday + 7) % 7;
    final offset = days == 0 ? 7 : days;
    return DateTime(today.year, today.month, today.day).add(Duration(days: offset));
  }

  void _generatePreview() {
    if (_generating) return;
    setState(() { _generating = true; _notice = null; });
    try {
    if (_trainingPaused) {
      setState(() => _notice = 'Training is paused. Complete the return-to-training review before building a new plan.');
      return;
    }
    final base = double.tryParse(_weeklyKm.text.trim());
    final currentLong = double.tryParse(_currentLongRunKm.text.trim());
    if (base == null || base <= 0 || base > 120) {
      setState(() => _notice = 'Enter a realistic current weekly running distance (0.1–120 km).');
      return;
    }
    if (currentLong == null || currentLong < 1 || currentLong > 50) {
      setState(() => _notice = 'Enter a current comfortable long run between 1 and 50 km.');
      return;
    }
    if (_longRunGoal < currentLong) {
      setState(() => _notice = 'Your long-run goal must be at least as far as your current comfortable long run. Choose a higher goal or adjust your current distance.');
      return;
    }
    final maxHr = int.tryParse(_maxHr.text.trim());
    final restingHr = int.tryParse(_restingHr.text.trim());
    if (_useHrTargets && (maxHr == null || maxHr < 100 || maxHr > 240 ||
        restingHr == null || restingHr < 30 || restingHr >= maxHr)) {
      setState(() => _notice = 'For heart-rate targets, enter a measured maximum HR (100–240 bpm) and resting HR (30 bpm or higher, below max HR).');
      return;
    }

    final days = _saturdayParkrun
        ? (_sessions == 2 ? [3, 5] : _sessions == 3 ? [1, 3, 5] : [0, 2, 3, 5])
        : (_sessions == 2 ? [1, 5] : _sessions == 3 ? [1, 3, 5] : [0, 2, 4, 5]);
    final longDay = _saturdayParkrun ? 3 : days.last;
    final easyDays = days.where((day) => day != longDay && !(_saturdayParkrun && day == 5)).toList();
    var start = _nextMonday();
    if (_eventDate != null) {
      final eventWeekMonday = DateTime(_eventDate!.year, _eventDate!.month, _eventDate!.day)
          .subtract(Duration(days: _eventDate!.weekday - DateTime.monday));
      start = eventWeekMonday.subtract(Duration(days: (_durationWeeks - 1) * 7));
      if (start.isBefore(_nextMonday())) {
        setState(() => _notice = 'That event is too soon for a $_durationWeeks-week plan starting next Monday. Choose a later event date or a shorter plan.');
        return;
      }
    }
    final generated = <_PlannedSession>[];
    const longRunSteps = [0.0, 0.5, 1.0, 0.5];

    for (var week = 0; week < _durationWeeks; week++) {
      final phaseWeek = week % 4;
      final factor = phaseWeek == 3 ? 0.88 : 1 + (phaseWeek * 0.05);
      final weeklyTarget = base * factor;
      final longDistance = (currentLong + longRunSteps[phaseWeek]).clamp(1.0, _longRunGoal.toDouble()).toDouble();
      final parkrunDistance = _saturdayParkrun ? 5.0 : 0.0;
      final minimumEasyVolume = easyDays.length * 1.5;
      if (weeklyTarget < longDistance + parkrunDistance + minimumEasyVolume) {
        setState(() => _notice =
            'The plan needs more weekly volume to fit your current long run, Saturday 5 km parkrun and easy sessions. Increase the confirmed weekly distance or turn off the fixed parkrun option.');
        return;
      }
      final remaining = weeklyTarget - longDistance - parkrunDistance;
      final easyDistance = easyDays.isEmpty ? 0.0 : remaining / easyDays.length;

      for (final weekday in days) {
        if (week == _durationWeeks - 1 &&
            _eventDate != null &&
            weekday > _eventDate!.weekday - DateTime.monday) {
          continue;
        }
        final date = start.add(Duration(days: week * 7 + weekday));
        final matchingEvents = _events.where((e) =>
          e['event_date']?.toString() == date.toIso8601String().substring(0, 10)).toList();
        final event = matchingEvents.isEmpty ? null : matchingEvents.first;
        final isLong = weekday == longDay;
        final isParkrun = _saturdayParkrun && weekday == 5;
        final distance = event != null && event['distance_m'] is num
            ? (event['distance_m'] as num).toDouble() / 1000
            : isLong ? longDistance : isParkrun ? 5.0 : easyDistance;
        final title = event != null
            ? 'Event: ${event['title']}'
            : isLong
                ? 'Easy long run'
                : isParkrun
                    ? 'Saturday parkrun 5 km'
                    : 'Easy run';
        final hrTarget = _useHrTargets ? _heartRateTarget(maxHr!, restingHr!, _hrZone) : null;
        final customNote = _customNotes.text.trim();
        final baseDescription = event != null
            ? 'Scheduled event (priority ${event['priority']}). Treat this as the session for the day; do not add another workout.'
            : isLong
                ? 'Comfortable conversational effort. No pace target.'
                : isParkrun
                    ? 'Keep this controlled and conversational; no hard racing target.'
                    : 'Relaxed easy effort. Finish feeling you could do more.';
        generated.add(_PlannedSession(
          date: date,
          title: title,
          distanceKm: distance,
          week: week + 1,
          description: [baseDescription, if (hrTarget != null) 'HR target: $hrTarget.', if (customNote.isNotEmpty) 'Notes: $customNote'].join(' '),
          hrTarget: hrTarget,
        ));
      }
      if (week == _durationWeeks - 1 && _eventDate != null) {
        generated.add(_PlannedSession(
          date: DateTime(_eventDate!.year, _eventDate!.month, _eventDate!.day),
          title: _eventName.text.trim().isEmpty ? 'Target event' : _eventName.text.trim(),
          distanceKm: 0,
          week: _durationWeeks,
          description: 'Target event day. Follow your event-specific pacing and effort plan; this is not an easy training session.',
        ));
      }
    }
    generated.sort((a, b) => a.date.compareTo(b.date));
    setState(() {
      _preview = generated;
      _notice = 'Preview generated. Review every session before saving.';
    });
    } catch (error) {
      setState(() {
        _preview = [];
        _notice = 'Could not generate the preview: $error';
      });
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _approveAndSave() async {
    if (_preview.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final db = await RunFuelDatabase.instance.database;
      final now = DateTime.now().toUtc().toIso8601String();
      final planId = 'plan_${DateTime.now().microsecondsSinceEpoch}';
      await db.transaction((txn) async {
        final previousPlans = await txn.query('training_plans',
          columns: ['id'], where: "status IN ('active', 'paused', 'needs_review')");
        for (final previous in previousPlans) {
          await txn.update('planned_workouts', {'status': 'superseded', 'updated_at': now},
            where: "plan_id = ? AND status IN ('planned', 'paused', 'needs_review', 'replan_required')",
            whereArgs: [previous['id']]);
        }
        await txn.update('planned_workouts', {'status': 'superseded', 'updated_at': now},
          where: "status = 'replan_required'");
        await txn.update('training_plans', {'status': 'superseded', 'updated_at': now},
          where: "status IN ('active', 'paused', 'needs_review')");
        await txn.insert('training_plans', {
          'id': planId,
          'name': '$_durationWeeks-week adaptive running block',
          'goal': 'Build towards a comfortable $_longRunGoal km long run.${_eventName.text.trim().isNotEmpty ? ' Target event: ${_eventName.text.trim()}.' : ''}${_eventDate != null ? ' Event date: ${_eventDate!.toIso8601String().substring(0, 10)}.' : ''} ${_customNotes.text.trim()} Active events: ${_events.map((e) => e['title']).join(', ')}',
          'start_date': _preview.first.date.toIso8601String(),
          'end_date': (_eventDate ?? _preview.last.date).toIso8601String(),
          'status': 'active',
          'created_at': now,
          'updated_at': now,
        });
        for (var i = 0; i < _preview.length; i++) {
          final session = _preview[i];
          await txn.insert('planned_workouts', {
            'id': '${planId}_$i',
            'plan_id': planId,
            'scheduled_at': session.date.toIso8601String(),
            'workout_type': 'running',
            'title': session.title,
            'description': session.description,
            'target_distance_m': session.distanceKm > 0 ? session.distanceKm * 1000 : null,
            'target_hr_zone': session.hrTarget,
            'intensity': 'easy',
            'status': 'planned',
            'created_at': now,
            'updated_at': now,
          });
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Training plan saved to your RunFuel schedule.')),
        );
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() => _notice = 'Could not save the plan: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _date(DateTime date) =>
      '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1]} ${date.day}/${date.month}';

  @override
  void dispose() {
    _weeklyKm.dispose();
    _currentLongRunKm.dispose();
    _maxHr.dispose();
    _restingHr.dispose();
    _customNotes.dispose();
    _eventName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Build a training plan')),
    body: ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.paddingOf(context).bottom + 40),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'Choose how many weeks you want to plan for, add an optional target event date, and set your preferences and heart-rate guidance. RunFuel shows the schedule first; nothing is saved until you approve it.',
              style: TextStyle(height: 1.4),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Plan duration', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: _durationWeeks,
          decoration: const InputDecoration(labelText: 'Number of weeks'),
          items: [2, 3, 4, 5, 6, 8, 10, 12, 16].map((weeks) =>
            DropdownMenuItem(value: weeks, child: Text('$weeks weeks'))).toList(),
          onChanged: (value) => setState(() {
            if (value != null) _durationWeeks = value;
            _preview = [];
          }),
        ),
        const SizedBox(height: 16),
        const Text('Target event (optional)', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: _eventName,
          decoration: const InputDecoration(
            labelText: 'Event name',
            hintText: 'e.g. Half marathon, 10 km race, parkrun',
          ),
          onChanged: (_) => setState(() => _preview = []),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _eventDate ?? DateTime.now().add(Duration(days: _durationWeeks * 7 + 7)),
              firstDate: DateTime.now(),
              lastDate: DateTime.now().add(const Duration(days: 730)),
            );
            if (picked != null && mounted) {
              setState(() { _eventDate = picked; _preview = []; });
            }
          },
          icon: const Icon(Icons.event),
          label: Text(_eventDate == null
              ? 'Choose event date'
              : 'Event date: ${_eventDate!.day}/${_eventDate!.month}/${_eventDate!.year}'),
        ),
        if (_eventDate != null)
          TextButton(
            onPressed: () => setState(() { _eventDate = null; _preview = []; }),
            child: const Text('Remove event date'),
          ),
        const SizedBox(height: 12),
        if (_trainingPaused)
          const Card(child: Padding(
            padding: EdgeInsets.all(12),
            child: Text('Training is paused. Use the return-to-training review before creating a new plan.', style: TextStyle(color: Colors.orangeAccent)),
          )),
        if (_returningAfterPause)
          const Card(child: Padding(
            padding: EdgeInsets.all(12),
            child: Text('Return-to-training block: pre-pause fitness figures are not being reused. Enter your current comfortable weekly distance and longest easy run as they are today. Start conservatively; do not use old pre-illness or pre-injury numbers.', style: TextStyle(height: 1.4)),
          )),
        if (_events.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Active Events & Goals', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                ..._events.map((event) => Text(
                  '${event['title']} · ${event['event_date'] ?? 'ongoing'} · priority ${event['priority']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                )),
                const SizedBox(height: 6),
                const Text('Events inside this four-week block replace the scheduled session on that date. Longer-term A-goal events remain coaching context; this starter block does not yet calculate a race-specific taper.', style: TextStyle(color: Colors.white54, fontSize: 11)),
              ]),
            ),
          ),
        TextField(
          controller: _weeklyKm,
          onChanged: (_) => setState(() => _preview = []),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Current average weekly running distance',
            suffixText: 'km',
            helperText: 'Prefilled from the last 28 days when local activity history is available. Check that it reflects your current fitness.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _currentLongRunKm,
          onChanged: (_) => setState(() => _preview = []),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Current comfortable long run',
            suffixText: 'km',
            helperText: 'Used to build the long run gradually; the selected 8 or 10 km goal may take several blocks.',
          ),
        ),
        const SizedBox(height: 16),
        const Text('Custom plan details', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: _customNotes,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Your preferences or constraints',
            hintText: 'e.g. avoid hills, keep weekdays short, protect recovery days, event preparation',
            helperText: 'These notes are attached to each planned session for review.',
          ),
          onChanged: (_) => setState(() => _preview = []),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use heart-rate targets'),
          subtitle: const Text('Optional. Uses your entered maximum and resting HR to calculate a heart-rate-reserve range. Match these zones to your Garmin settings; zone boundaries can differ.'),
          value: _useHrTargets,
          onChanged: (value) => setState(() { _useHrTargets = value; _preview = []; }),
        ),
        if (_useHrTargets) ...[
          TextField(
            controller: _maxHr,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Measured maximum heart rate', suffixText: 'bpm', helperText: 'Use a reliable measured value; do not use an age formula as a substitute.'),
            onChanged: (_) => setState(() => _preview = []),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _restingHr,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Resting heart rate', suffixText: 'bpm'),
            onChanged: (_) => setState(() => _preview = []),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _hrZone,
            decoration: const InputDecoration(labelText: 'Target heart-rate zone'),
            items: const [
              DropdownMenuItem(value: 'Zone 1', child: Text('Zone 1 · Recovery')),
              DropdownMenuItem(value: 'Zone 2', child: Text('Zone 2 · Easy aerobic')),
              DropdownMenuItem(value: 'Zone 3', child: Text('Zone 3 · Steady')),
            ],
            onChanged: (value) => setState(() {
              if (value != null) {
                _hrZone = value;
              }
              _preview = [];
            }),
          ),
        ],
        const SizedBox(height: 16),
        const Text('Runs per week', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 2, label: Text('2')),
            ButtonSegment(value: 3, label: Text('3')),
            ButtonSegment(value: 4, label: Text('4')),
          ],
          selected: {_sessions},
          onSelectionChanged: (value) => setState(() { _sessions = value.first; _preview = []; }),
        ),
        const SizedBox(height: 16),
        const Text('Comfortable long-run goal', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 5, label: Text('5 km')),
            ButtonSegment(value: 8, label: Text('8 km')),
            ButtonSegment(value: 10, label: Text('10 km')),
          ],
          selected: {_longRunGoal},
          onSelectionChanged: (value) => setState(() { _longRunGoal = value.first; _preview = []; }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep Saturday parkrun as 5 km'),
          subtitle: const Text('A separate Thursday long run builds gradually; Saturday stays controlled.'),
          value: _saturdayParkrun,
          onChanged: (value) => setState(() { _saturdayParkrun = value; _preview = []; }),
        ),
        FilledButton.icon(
          onPressed: _generating ? null : _generatePreview,
          icon: _generating
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(_generating ? 'Generating preview…' : 'Generate plan preview'),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 10),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_preview.isNotEmpty ? Icons.check_circle_outline : Icons.info_outline,
                    color: _preview.isNotEmpty ? Colors.green : Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(_notice!, style: TextStyle(color: Theme.of(context).colorScheme.onSurface))),
              ]),
            ),
          ),
        ],
        if (_preview.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Review your $_durationWeeks-week plan', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('You can go back and change the inputs, then regenerate. Approving adds these sessions to the local RunFuel schedule.', style: TextStyle(color: Colors.white70, height: 1.4)),
          const SizedBox(height: 10),
          if (_eventDate != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Target: ${_eventName.text.trim().isEmpty ? 'Event' : _eventName.text.trim()} · ${_date(_eventDate!)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          for (var week = 1; week <= _durationWeeks; week++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('WEEK $week', style: const TextStyle(color: Color(0xFF9BE15D), fontWeight: FontWeight.w800, letterSpacing: 1)),
            ),
            ..._preview.where((s) => s.week == week).map((session) => Card(
              child: ListTile(
                leading: const Icon(Icons.directions_run),
                title: Text(session.title),
                subtitle: Text('${_date(session.date)} · ${session.description}'),
                trailing: Text(session.distanceKm > 0 ? '${session.distanceKm.toStringAsFixed(1)} km' : 'Event', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            )),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _approveAndSave,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_circle_outline),
            label: Text(_saving ? 'Saving plan…' : 'Approve & Add to Schedule'),
          ),
        ],
      ],
    ),
  );
}

String _heartRateTarget(int maxHr, int restingHr, String zone) {
  final reserve = maxHr - restingHr;
  final (lower, upper) = switch (zone) {
    'Zone 1' => (0.50, 0.60),
    'Zone 3' => (0.70, 0.80),
    _ => (0.60, 0.70),
  };
  final low = (restingHr + reserve * lower).round();
  final high = (restingHr + reserve * upper).round();
  return '$zone · $low–$high bpm';
}

class _PlannedSession {
  const _PlannedSession({
    required this.date,
    required this.title,
    required this.distanceKm,
    required this.week,
    required this.description,
    this.hrTarget,
  });

  final DateTime date;
  final String title;
  final double distanceKm;
  final int week;
  final String description;
  final String? hrTarget;
}
