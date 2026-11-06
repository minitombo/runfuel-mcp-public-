import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// On-device cache for non-secret RunFuel data.
///
/// Provider credentials are never stored here. Health document contents are
/// kept outside SQLite; this database stores metadata and app-private paths only.
class RunFuelDatabase {
  RunFuelDatabase._();

  static final RunFuelDatabase instance = RunFuelDatabase._();
  Database? _database;

  Future<void> initialize() async {
    if (_database != null) return;

    final root = await getDatabasesPath();
    _database = await openDatabase(
      p.join(root, 'runfuel_v1.db'),
      version: 4,
      onCreate: (db, version) async {
        await _createCoreTables(db);
        await _createTrainingAndHealthTables(db);
        await _createSleepTables(db);
        await _createCoachingLifecycleTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createTrainingAndHealthTables(db);
        }
        if (oldVersion < 3) {
          await _createSleepTables(db);
        }
        if (oldVersion < 4) {
          await _createCoachingLifecycleTables(db);
        }
      },
    );
  }

  Future<void> _createCoreTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE activities (
        id TEXT PRIMARY KEY,
        started_at TEXT NOT NULL,
        sport TEXT,
        distance_m REAL,
        duration_s REAL,
        avg_hr REAL,
        avg_pace_s_per_km REAL,
        source_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE nutrition_days (
        day TEXT PRIMARY KEY,
        calories REAL,
        protein_g REAL,
        carbs_g REAL,
        fat_g REAL,
        fibre_g REAL,
        source_updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE coaching_reviews (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        prompt TEXT,
        response TEXT NOT NULL,
        model TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_state (
        source TEXT PRIMARY KEY,
        last_attempt TEXT,
        last_success TEXT,
        status TEXT NOT NULL,
        message TEXT
      )
    ''');
  }

  Future<void> _createTrainingAndHealthTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE training_plans (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        goal TEXT,
        start_date TEXT NOT NULL,
        end_date TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE planned_workouts (
        id TEXT PRIMARY KEY,
        plan_id TEXT,
        scheduled_at TEXT NOT NULL,
        workout_type TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT,
        target_distance_m REAL,
        target_duration_s REAL,
        target_pace_min_km REAL,
        target_hr_zone TEXT,
        intensity TEXT,
        status TEXT NOT NULL DEFAULT 'planned',
        completed_activity_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE workout_matches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        planned_workout_id TEXT NOT NULL,
        activity_id TEXT NOT NULL,
        confidence REAL NOT NULL,
        match_method TEXT NOT NULL,
        reviewed INTEGER NOT NULL DEFAULT 0,
        matched_at TEXT NOT NULL,
        UNIQUE(planned_workout_id, activity_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE health_measurements (
        id TEXT PRIMARY KEY,
        measured_at TEXT NOT NULL,
        category TEXT NOT NULL,
        metric TEXT NOT NULL,
        value REAL,
        unit TEXT,
        source TEXT,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE health_records (
        id TEXT PRIMARY KEY,
        record_type TEXT NOT NULL,
        display_name TEXT NOT NULL,
        local_path TEXT NOT NULL,
        recorded_at TEXT,
        added_at TEXT NOT NULL,
        mime_type TEXT,
        notes TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE coach_recommendations (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        category TEXT NOT NULL,
        recommendation TEXT NOT NULL,
        rationale TEXT,
        related_workout_id TEXT,
        related_activity_id TEXT,
        status TEXT NOT NULL DEFAULT 'active'
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_activities_started_at ON activities(started_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_planned_workouts_scheduled_at ON planned_workouts(scheduled_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_planned_workouts_status ON planned_workouts(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_workout_matches_activity ON workout_matches(activity_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_health_measurements_metric_date ON health_measurements(metric, measured_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_coach_recommendations_created_at ON coach_recommendations(created_at)',
    );
  }

  Future<void> _createSleepTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE sleep_records (
        sleep_date TEXT PRIMARY KEY,
        sleep_start TEXT,
        sleep_end TEXT,
        total_sleep_s REAL,
        deep_sleep_s REAL,
        light_sleep_s REAL,
        rem_sleep_s REAL,
        awake_s REAL,
        sleep_score REAL,
        source_updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sleep_records_date ON sleep_records(sleep_date)',
    );
  }

  Future<void> _createCoachingLifecycleTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE training_events (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        event_date TEXT,
        distance_m REAL,
        goal_type TEXT NOT NULL DEFAULT 'finish',
        priority TEXT NOT NULL DEFAULT 'B',
        event_kind TEXT NOT NULL DEFAULT 'race',
        recurrence TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        notes TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_training_events_date ON training_events(event_date)');
    await db.execute('''
      CREATE TABLE training_pauses (
        id TEXT PRIMARY KEY,
        start_date TEXT NOT NULL,
        end_date TEXT,
        reason TEXT NOT NULL,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        return_notes TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_training_pauses_status ON training_pauses(status)');
    await db.execute('''
      CREATE TABLE daily_reviews (
        id TEXT PRIMARY KEY,
        review_date TEXT NOT NULL UNIQUE,
        energy INTEGER,
        soreness INTEGER,
        mood INTEGER,
        sleep_quality INTEGER,
        notes TEXT,
        coach_summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<Database> get database async {
    final db = _database;
    if (db == null) {
      throw StateError('RunFuelDatabase.initialize() must be called first.');
    }
    return db;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
