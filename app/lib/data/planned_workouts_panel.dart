import 'package:flutter/material.dart';

import 'runfuel_database.dart';
import 'training_plan_builder_page.dart';

const _plannedGreen = Color(0xFF9BE15D);

/// Local schedule for planned sessions. Garmin activities remain read-only;
/// matching is performed by TrainingDataService after a successful sync.
class PlannedWorkoutsPanel extends StatefulWidget {
  const PlannedWorkoutsPanel({super.key});

  @override
  State<PlannedWorkoutsPanel> createState() => _PlannedWorkoutsPanelState();
}

class _PlannedWorkoutsPanelState extends State<PlannedWorkoutsPanel> {
  late Future<List<Map<String, Object?>>> _workouts = _load();

  Future<List<Map<String, Object?>>> _load() async {
    final db = await RunFuelDatabase.instance.database;
    return db.query(
      'planned_workouts',
      orderBy: 'scheduled_at ASC',
      limit: 40,
    );
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _workouts = _load());
  }

  Widget _infoPanel({required IconData icon, required String title, required String body}) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: _plannedGreen),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(body, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .76), height: 1.35)),
          ])),
        ]),
      );

  Future<void> _buildPlan() async {
    final approved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TrainingPlanBuilderPage()),
    );
    if (approved == true) await _refresh();
  }

  Future<void> _addWorkout() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !mounted) return;

    final distanceController = TextEditingController();
    final titleController = TextEditingController(text: 'Easy run');
    final formKey = GlobalKey<FormState>();
    final details = await showDialog<({String title, double? distance})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add planned session'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Session name'),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: distanceController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Target distance (km)',
                  hintText: 'Optional, e.g. 5',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final parsed = double.tryParse(value);
                  return parsed == null || parsed <= 0
                      ? 'Enter a distance greater than zero'
                      : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final raw = distanceController.text.trim();
              Navigator.pop(
                dialogContext,
                (
                  title: titleController.text.trim(),
                  distance: raw.isEmpty ? null : double.parse(raw),
                ),
              );
            },
            child: const Text('Save session'),
          ),
        ],
      ),
    );
    distanceController.dispose();
    titleController.dispose();
    if (details == null || !mounted) return;

    final scheduled = DateTime(
      date.year, date.month, date.day, time.hour, time.minute,
    );
    final stamp = DateTime.now().toUtc().toIso8601String();
    final id = 'manual_${scheduled.microsecondsSinceEpoch}';
    final db = await RunFuelDatabase.instance.database;
    await db.insert('planned_workouts', {
      'id': id,
      'scheduled_at': scheduled.toIso8601String(),
      'workout_type': 'running',
      'title': details.title,
      'target_distance_m':
          details.distance == null ? null : details.distance! * 1000,
      'status': 'planned',
      'created_at': stamp,
      'updated_at': stamp,
    });
    await _refresh();
  }

  String _dateLabel(String raw) {
    final date = DateTime.tryParse(raw)?.toLocal();
    if (date == null) return raw;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour < 12 ? 'am' : 'pm';
    return '${weekdays[date.weekday - 1]} ${date.day} ${months[date.month - 1]} · $hour:$minute$period';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Planned Sessions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Wrap(spacing: 4, children: [
              TextButton.icon(
                onPressed: _buildPlan,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Build plan'),
              ),
              TextButton.icon(
                onPressed: _addWorkout,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ]),
          ]),
        ),
        FutureBuilder<List<Map<String, Object?>>>(
          future: _workouts,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Padding(
                padding: EdgeInsets.all(18),
                child: Center(child: Text('Loading Planned Sessions…', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6)))),
              );
            }
            if (snapshot.hasError) {
              return _infoPanel(
                icon: Icons.error_outline,
                title: 'Schedule unavailable',
                body: 'Could not load your locally saved planned sessions.',
              );
            }
            final workouts = snapshot.data ?? [];
            if (workouts.isEmpty) {
              return _infoPanel(
                icon: Icons.event_note,
                title: 'No Planned Sessions Yet',
                body: 'Add a planned run here. When a Garmin activity is synced, RunFuel can compare its date, distance and duration with the session. Close matches are held for your review.',
              );
            }
            return Column(
              children: workouts.map((workout) {
                final status = workout['status']?.toString() ?? 'planned';
                final distance = workout['target_distance_m'];
                final distanceText = distance is num
                    ? ' · ${(distance / 1000).toStringAsFixed(1)} km target'
                    : '';
                final statusText = status == 'completed'
                    ? 'Matched to a Garmin activity'
                    : status == 'needs_review'
                        ? 'Possible activity match · review needed'
                        : status == 'paused'
                            ? 'Training paused · retained, not scheduled'
                            : status == 'replan_required'
                                ? 'Return plan required · do not catch up'
                                : status == 'superseded'
                                    ? 'Replaced by a newer training plan'
                                    : 'Planned';
                final icon = status == 'completed'
                    ? Icons.check_circle_outline
                    : status == 'needs_review' || status == 'replan_required'
                        ? Icons.help_outline
                        : status == 'paused'
                            ? Icons.pause_circle_outline
                            : status == 'superseded'
                                ? Icons.archive_outlined
                                : Icons.event_available;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(icon, color: _plannedGreen),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(workout['title']?.toString() ?? 'Run',
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              '${_dateLabel(workout['scheduled_at'].toString())}$distanceText',
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6), fontSize: 12),
                            ),
                            Text(statusText,
                                style: const TextStyle(color: _plannedGreen, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}
