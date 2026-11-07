import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'number_formatting.dart';
import 'runfuel_database.dart';

class RunFuelDashboardPage extends StatefulWidget {
  const RunFuelDashboardPage({super.key, required this.selectedDate, required this.onDateChanged, required this.reportingDays});
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateChanged;
  final int reportingDays;
  @override
  State<RunFuelDashboardPage> createState() => _RunFuelDashboardPageState();
}

class _RunFuelDashboardPageState extends State<RunFuelDashboardPage> {
  final _captureKey = GlobalKey();
  late Future<_DashData> _future;
  bool _exporting = false;
  String _view = 'Overview';
  String _x = 'sleepHours', _y = 'hrv';
  bool _lag = false;

  static const metrics = <String, _Metric>{
    'sleepHours': _Metric('Sleep duration', 'hours'),
    'sleepScore': _Metric('Sleep score', 'score'),
    'hrv': _Metric('HRV', 'ms'),
    'restingHr': _Metric('Resting heart rate', 'bpm'),
    'bodyBattery': _Metric('Body Battery', 'score'),
    'stress': _Metric('Stress', 'score'),
    'caloriesIn': _Metric('Food intake', 'kcal'),
    'carbs': _Metric('Carbohydrates', 'g'),
    'protein': _Metric('Protein', 'g'),
    'fibre': _Metric('Fibre', 'g'),
    'activeCalories': _Metric('Active calories', 'kcal'),
    'restingCalories': _Metric('Resting calories', 'kcal'),
    'bmrCalories': _Metric('Basal metabolic calories', 'kcal'),
    'totalBurn': _Metric('Total calories burned', 'kcal'),
    'runKm': _Metric('Running distance', 'km'),
    'trainingMinutes': _Metric('Training duration', 'min'),
    'runPace': _Metric('Average running pace', 'sec/km'),
    'runHr': _Metric('Running heart rate', 'bpm'),
    'weight': _Metric('Weight', 'kg'),
  };

  @override
  void initState() { super.initState(); _future = _load(); }
  @override
  void didUpdateWidget(covariant RunFuelDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reportingDays != widget.reportingDays || oldWidget.selectedDate != widget.selectedDate) _future = _load();
  }

  String _key(DateTime d) => d.toIso8601String().substring(0, 10);
  double? _n(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  Future<_DashData> _load() async {
    final db = await RunFuelDatabase.instance.database;
    final end = DateTime(widget.selectedDate.year, widget.selectedDate.month, widget.selectedDate.day);
    final start = end.subtract(Duration(days: widget.reportingDays - 1));
    final from = _key(start), to = _key(end);
    final results = await Future.wait([
      db.query('activities', where: 'started_at >= ? AND started_at < ?', whereArgs: [from, _key(end.add(const Duration(days: 1)))], orderBy: 'started_at ASC'),
      db.query('nutrition_days', where: 'day >= ? AND day <= ?', whereArgs: [from, to]),
      db.query('sleep_records', where: 'sleep_date >= ? AND sleep_date <= ?', whereArgs: [from, to]),
      db.query('health_measurements', where: 'measured_at >= ? AND measured_at <= ?', whereArgs: [from, to], orderBy: 'measured_at ASC'),
    ]);
    final map = <String, _DashDay>{};
    for (var i = 0; i < widget.reportingDays; i++) {
      final d = start.add(Duration(days: i)); map[_key(d)] = _DashDay(d);
    }
    for (final row in results[0]) {
      final raw = row['started_at']?.toString() ?? '';
      if (raw.length < 10 || !map.containsKey(raw.substring(0, 10))) continue;
      final d = map[raw.substring(0, 10)]!;
      final sport = (row['sport'] ?? '').toString().toLowerCase();
      final distance = _n(row['distance_m']), duration = _n(row['duration_s']);
      if (sport == 'running') {
        d.runKm += (distance ?? 0) / 1000;
        final hr = _n(row['avg_hr']); if (hr != null) { d.hrSum += hr; d.hrCount++; }
        final pace = _n(row['avg_pace_s_per_km']);
        if (pace != null && distance != null && distance > 0) { d.paceSum += pace * distance; d.paceDistance += distance; }
      }
      if (duration != null) d.trainingMinutes += duration / 60;
      d.activityCount++;
    }
    for (final row in results[1]) {
      final d = map[row['day']?.toString()]; if (d == null) continue;
      d.caloriesIn = _n(row['calories']); d.carbs = _n(row['carbs_g']); d.protein = _n(row['protein_g']); d.fibre = _n(row['fibre_g']); d.fat = _n(row['fat_g']);
    }
    for (final row in results[2]) {
      final d = map[row['sleep_date']?.toString()]; if (d == null) continue;
      final seconds = _n(row['total_sleep_s']); d.sleepHours = seconds == null ? null : seconds / 3600; d.sleepScore = _n(row['sleep_score']);
    }
    for (final row in results[3]) {
      final raw = row['measured_at']?.toString() ?? '';
      final d = raw.length >= 10 ? map[raw.substring(0, 10)] : null;
      if (d == null) continue;
      final v = _n(row['value']); if (v == null) continue;
      switch (row['metric']) {
        case 'hrv_ms': d.hrv = v; break;
        case 'resting_hr_bpm': d.restingHr = v; break;
        case 'body_battery': d.bodyBattery = v; break;
        case 'stress_level': d.stress = v; break;
        case 'active_calories': d.activeCalories = v; break;
        case 'resting_calories': d.restingCalories = v; break;
        case 'bmr_calories': d.bmrCalories = v; break;
        case 'total_calories_burned': d.totalBurn = v; break;
        case 'weight_kg': case 'weight': d.weight = v; break;
      }
    }
    return _DashData(map.values.toList());
  }

  double? _v(_DashDay d, String key) {
    switch (key) {
      case 'sleepHours': return d.sleepHours;
      case 'sleepScore': return d.sleepScore;
      case 'hrv': return d.hrv;
      case 'restingHr': return d.restingHr;
      case 'bodyBattery': return d.bodyBattery;
      case 'stress': return d.stress;
      case 'caloriesIn': return d.caloriesIn;
      case 'carbs': return d.carbs;
      case 'protein': return d.protein;
      case 'fibre': return d.fibre;
      case 'activeCalories': return d.activeCalories;
      case 'restingCalories': return d.restingCalories;
      case 'bmrCalories': return d.bmrCalories;
      case 'totalBurn': return d.totalBurn ?? (d.activeCalories != null && d.restingCalories != null ? d.activeCalories! + d.restingCalories! : null);
      case 'runKm': return d.runKm > 0 ? d.runKm : null;
      case 'trainingMinutes': return d.trainingMinutes > 0 ? d.trainingMinutes : null;
      case 'runPace': return d.paceDistance > 0 ? d.paceSum / d.paceDistance : null;
      case 'runHr': return d.hrCount > 0 ? d.hrSum / d.hrCount : null;
      case 'weight': return d.weight;
    }
    return null;
  }

  List<({double x, double y})> _pairs(_DashData data) {
    final out = <({double x, double y})>[];
    for (var i = 0; i < data.days.length; i++) {
      final xi = _lag ? i - 1 : i; if (xi < 0) continue;
      final x = _v(data.days[xi], _x), y = _v(data.days[i], _y);
      if (x != null && y != null && x.isFinite && y.isFinite) out.add((x: x, y: y));
    }
    return out;
  }

  double? _r(List<({double x, double y})> points) {
    if (points.length < 5) return null;
    final mx = points.map((p) => p.x).reduce((a,b)=>a+b) / points.length;
    final my = points.map((p) => p.y).reduce((a,b)=>a+b) / points.length;
    var n=0.0, xx=0.0, yy=0.0;
    for (final p in points) { final dx=p.x-mx, dy=p.y-my; n+=dx*dy; xx+=dx*dx; yy+=dy*dy; }
    final den=math.sqrt(xx*yy); return den == 0 ? null : n/den;
  }

  double? _avg(Iterable<double?> input) {
    final v=input.whereType<double>().toList(); return v.isEmpty ? null : v.reduce((a,b)=>a+b)/v.length;
  }
  String _fmt(double? v, {int decimals=0}) => v == null ? '—' : formatRunFuelNumber(v, decimals: decimals);
  String _correlationDescription(double? value) {
    if (value == null) return 'Not enough matched data or variation to calculate a reliable correlation.';
    if (value.abs() < .2) return 'No clear linear relationship in this period.';
    final strength = value.abs() >= .7 ? 'strong' : value.abs() >= .4 ? 'moderate' : 'weak';
    return '${value > 0 ? 'Positive' : 'Negative'} $strength association in this period.';
  }

  String _period() => '${_key(widget.selectedDate.subtract(Duration(days: widget.reportingDays-1)))} – ${_key(widget.selectedDate)}';

  Future<Uint8List> _png() async {
    await WidgetsBinding.instance.endOfFrame;
    final obj=_captureKey.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary) throw StateError('Dashboard is not ready to export.');
    final img=await obj.toImage(pixelRatio: 2);
    try { final data=await img.toByteData(format: ui.ImageByteFormat.png); if(data==null) throw StateError('Image encoding failed.'); return data.buffer.asUint8List(); }
    finally { img.dispose(); }
  }

  Future<void> _imageExport(bool share) async {
    if (_exporting) return; setState(()=>_exporting=true);
    try {
      final bytes=await _png();
      if (share) {
        final dir=await getTemporaryDirectory();
        final file=File('${dir.path}/runfuel-dashboard.png'); await file.writeAsBytes(bytes,flush:true);
        await Share.shareXFiles([XFile(file.path,mimeType:'image/png')],subject:'RunFuel Dashboard · $_period()');
      } else {
        final result=await ImageGallerySaverPlus.saveImage(bytes,quality:100,name:'runfuel-dashboard-${DateTime.now().millisecondsSinceEpoch}');
        if (result is! Map || result['isSuccess'] != true) throw StateError('Android did not confirm the image was saved.');
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Dashboard image saved to Gallery.')));
      }
    } catch(e) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Image export failed: $e'))); }
    finally { if(mounted) setState(()=>_exporting=false); }
  }

  Future<void> _pdfExport(bool share) async {
    if (_exporting) return; setState(()=>_exporting=true);
    try {
      final data=await _future;
      final image=await _png();
      final doc=pw.Document();
      doc.addPage(pw.MultiPage(build:(ctx)=>[
        pw.Header(level:0,child:pw.Text('RunFuel Dashboard')),
        pw.Text('Period: ${_period()}'),
        pw.SizedBox(height:12),
        pw.Image(pw.MemoryImage(image),width:500,height:540,fit:pw.BoxFit.contain),
        pw.SizedBox(height:12),
        pw.Text('Nutrition days logged: ${data.days.where((d)=>d.caloriesIn!=null).length}'),
        pw.Text('Nights with sleep: ${data.days.where((d)=>d.sleepHours!=null).length}'),
        pw.Text('Days with HRV: ${data.days.where((d)=>d.hrv!=null).length}'),
        pw.Text('Training days: ${data.days.where((d)=>d.activityCount>0).length}'),
        pw.Text('Correlation is an association, not proof of cause. Missing values are excluded.'),
      ]));
      final bytes=await doc.save();
      final name='runfuel-dashboard-${DateTime.now().millisecondsSinceEpoch}.pdf';
      if(share) {
        final dir=await getTemporaryDirectory();
        final file=File('${dir.path}/$name'); await file.writeAsBytes(bytes,flush:true);
        await Share.shareXFiles([XFile(file.path,mimeType:'application/pdf')],subject:'RunFuel Dashboard · ${_period()}');
      } else {
        final path=await FilePicker.platform.saveFile(dialogTitle:'Save RunFuel Dashboard PDF',fileName:name,type:FileType.custom,allowedExtensions:['pdf'],bytes:bytes);
        if(path!=null && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Dashboard PDF saved.')));
      }
    } catch(e) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('PDF export failed: $e'))); }
    finally { if(mounted) setState(()=>_exporting=false); }
  }

  Widget _card(String label, String value, String unit, IconData icon, {Color? accent}) {
    final scheme = Theme.of(context).colorScheme;
    final tone = accent ?? scheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: tone.withValues(alpha: .32), width: 1.2)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [Icon(icon, color: tone, size: 21), const SizedBox(width: 7), Expanded(child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)))]),
          Text(value, maxLines: 1, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
          Text(unit, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _heading(String title,String subtitle)=>Padding(padding:const EdgeInsets.only(top:24,bottom:12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text(title,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w800)),
    const SizedBox(height:3),
    Text(subtitle,style:TextStyle(fontSize:12,color:Theme.of(context).colorScheme.onSurfaceVariant)),
  ]));

  Widget _trend(String title,String subtitle,List<double?> values,String unit) {
    final valid = values.whereType<double>().where((v)=>v.isFinite).toList();
    final average = _avg(valid);
    final minimum = valid.isEmpty ? null : valid.reduce(math.min);
    final maximum = valid.isEmpty ? null : valid.reduce(math.max);
    final tone = Theme.of(context).colorScheme.tertiary;
    return Card(margin:EdgeInsets.zero,child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(title,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:15)),
      const SizedBox(height:3),
      Text(subtitle,style:TextStyle(fontSize:12,color:Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height:14),
      SizedBox(height:112,width:double.infinity,child:CustomPaint(painter:_LinePainter(values,tone))),
      const SizedBox(height:8),
      Row(children:[
        Expanded(child:Text('Avg  ${_fmt(average,decimals:1)}',style:const TextStyle(fontSize:11,fontWeight:FontWeight.w700))),
        Expanded(child:Text('Low  ${_fmt(minimum,decimals:1)}',style:TextStyle(fontSize:11,color:Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(child:Text('High  ${_fmt(maximum,decimals:1)}',textAlign:TextAlign.end,style:TextStyle(fontSize:11,color:Theme.of(context).colorScheme.onSurfaceVariant))),
      ]),
      Align(alignment:Alignment.centerRight,child:Text('$unit · ${valid.length} logged',style:TextStyle(fontSize:10,color:Theme.of(context).colorScheme.onSurfaceVariant))),
    ])));
  }

  Widget _report(_DashData data) {
    final days=data.days;
    final points=_pairs(data);
    final corr=_r(points);
    final calories=_avg(days.map((d)=>d.caloriesIn)), burn=_avg(days.map((d)=>_v(d,'totalBurn')));
    final hrv=_avg(days.map((d)=>d.hrv)), sleep=_avg(days.map((d)=>d.sleepHours));
    final km=days.fold<double>(0,(s,d)=>s+d.runKm);
    final exercise=days.where((d)=>d.activityCount>0).length;
    final matched=days.where((d)=>d.caloriesIn!=null && _v(d,'totalBurn')!=null).toList();
    final balance=matched.isEmpty?null:_avg(matched.map((d)=>_v(d,'totalBurn')!-d.caloriesIn!));
    final xdef=metrics[_x]!, ydef=metrics[_y]!;
    return RepaintBoundary(key:_captureKey,child:Container(color:Theme.of(context).colorScheme.surface,padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Row(children:[const Expanded(child:Text('RunFuel Dashboard',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900))),Icon(Icons.bolt,color:Theme.of(context).colorScheme.primary)]),
      Text(_period(),style:TextStyle(fontSize:11,color:Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height:10),
      GridView.count(crossAxisCount:2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisExtent:132,crossAxisSpacing:12,mainAxisSpacing:12,children:[
        _card('Avg food intake',_fmt(calories),'kcal / logged day',Icons.restaurant,accent:const Color(0xFFB7791F)),
        _card('Avg energy burn',_fmt(burn),'kcal / day',Icons.local_fire_department,accent:const Color(0xFFD66A32)),
        _card('Average HRV',_fmt(hrv),'ms',Icons.monitor_heart_outlined,accent:const Color(0xFF368B78)),
        _card('Average sleep',_fmt(sleep,decimals:1),'hours / night',Icons.bedtime_outlined,accent:const Color(0xFF6478B8)),
        _card('Running distance',_fmt(km,decimals:1),'km',Icons.directions_run,accent:const Color(0xFF368B78)),
        _card('Training days',exercise.toString(),'days with activity',Icons.fitness_center,accent:const Color(0xFF8B68B5)),
      ]),
      if(_view=='Overview'||_view=='Energy') ...[
        _heading('Energy balance','Matched diary and burn days only.'),
        Card(margin:EdgeInsets.zero,child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(balance==null?'Not enough matched energy data':'Average estimated ${balance>=0?'deficit':'surplus'}: ${_fmt(balance.abs())} kcal/day',style:const TextStyle(fontWeight:FontWeight.w700)),
          const SizedBox(height:8),
          GridView.count(crossAxisCount:2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisExtent:124,crossAxisSpacing:12,mainAxisSpacing:12,children:[
            _card('BMR',_fmt(_avg(days.map((d)=>d.bmrCalories))),'kcal / day · only if Garmin supplies it',Icons.bedtime_outlined),
            _card('Resting burn',_fmt(_avg(days.map((d)=>d.restingCalories))),'kcal / day',Icons.hotel_outlined),
            _card('Active burn',_fmt(_avg(days.map((d)=>d.activeCalories))),'kcal / day',Icons.directions_run),
          ]),
          _EnergyBars(days:days,valueOf:_v),
          const Text('Resting and active calories are separate. If total burn is missing, resting + active is an estimate. BMR is never added twice.',style:TextStyle(fontSize:10)),
        ]))),
      ],
      if(_view=='Overview'||_view=='Nutrition') ...[
        _heading('Nutrition','Averages use logged diary days; missing days are not zero.'),
        GridView.count(crossAxisCount:2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisExtent:112,crossAxisSpacing:12,mainAxisSpacing:12,children:[
          _card('Carbohydrates',_fmt(_avg(days.map((d)=>d.carbs))),'g / logged day',Icons.bakery_dining,accent:const Color(0xFFD69A35)),
          _card('Protein',_fmt(_avg(days.map((d)=>d.protein))),'g / logged day',Icons.egg_alt,accent:const Color(0xFFB86B82)),
          _card('Fibre',_fmt(_avg(days.map((d)=>d.fibre))),'g / logged day',Icons.grass,accent:const Color(0xFF368B78)),
          _card('Fat',_fmt(_avg(days.map((d)=>d.fat))),'g / logged day',Icons.opacity,accent:const Color(0xFF6478B8)),
        ]),
        _trend('Food intake','Daily MyFitnessPal calories',days.map((d)=>d.caloriesIn).toList(),'kcal'),
      ],
      if(_view=='Overview'||_view=='Training') ...[
        _heading('Training','Saved activities across the selected period.'),
        _trend('Running distance','Daily kilometres',days.map((d)=>d.runKm>0?d.runKm:null).toList(),'km'),
        _trend('Training duration','All saved sports',days.map((d)=>d.trainingMinutes>0?d.trainingMinutes:null).toList(),'minutes'),
        _trend('Running heart rate','Average saved activity HR',days.map((d)=>d.hrCount>0?d.hrSum/d.hrCount:null).toList(),'bpm'),
        _trend('Running pace','Distance-weighted average pace',days.map((d)=>d.paceDistance>0?d.paceSum/d.paceDistance:null).toList(),'seconds per km'),
      ],
      if(_view=='Overview'||_view=='Recovery') ...[
        _heading('Recovery','Sleep and recovery data retained from Garmin.'),
        _trend('Sleep duration','Nightly sleep',days.map((d)=>d.sleepHours).toList(),'hours'),
        _trend('HRV','Nightly average HRV',days.map((d)=>d.hrv).toList(),'ms'),
        _trend('Resting heart rate','Daily resting HR',days.map((d)=>d.restingHr).toList(),'bpm'),
        _trend('Sleep score','Garmin score when supplied',days.map((d)=>d.sleepScore).toList(),'score'),
      ],
      if(_view=='Overview'||_view=='Weight') ...[
        _heading('Weight','Only recorded measurements are shown.'),
        _trend('Weight trend','Saved weight measurements',days.map((d)=>d.weight).toList(),'kg'),
      ],
      if(_view=='Overview'||_view=='Relationships') ...[
        _heading('Relationship Explorer','Compare same-day measures or yesterday’s input with the following day.'),
        Card(margin:EdgeInsets.zero,child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          DropdownButtonFormField<String>(initialValue:_x,isExpanded:true,decoration:const InputDecoration(labelText:'First measure'),items:metrics.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text(e.value.label))).toList(),onChanged:(v){if(v!=null)setState(()=>_x=v);}),
          const SizedBox(height:6),
          DropdownButtonFormField<String>(initialValue:_y,isExpanded:true,decoration:const InputDecoration(labelText:'Compare against'),items:metrics.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text(e.value.label))).toList(),onChanged:(v){if(v!=null)setState(()=>_y=v);}),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Previous day → following day'),subtitle:const Text('For example, yesterday’s training vs today’s HRV'),value:_lag,onChanged:(v)=>setState(()=>_lag=v)),
          SizedBox(height:180,child:CustomPaint(painter:_ScatterPainter(points))),
          Text('${xdef.label} (${xdef.unit}) vs ${ydef.label} (${ydef.unit})',style:const TextStyle(fontWeight:FontWeight.w700,fontSize:12)),
          Text(_correlationDescription(corr),style:const TextStyle(fontWeight:FontWeight.w700)),
          Text('Pearson r: ${corr==null?'—':corr.toStringAsFixed(2)} · matched days: ${points.length}',style:TextStyle(fontSize:11,color:Theme.of(context).colorScheme.onSurfaceVariant)),
          const Text('Correlation shows association, not cause. Consider illness, stress, training intensity and missing data. At least 5 matched observations are required. Results with fewer than 10 points should be treated as exploratory.',style:TextStyle(fontSize:10,height:1.35)),
        ]))),
      ],
      const SizedBox(height:10),
      Text('Coverage: ${days.where((d)=>d.caloriesIn!=null).length} nutrition days · ${days.where((d)=>d.sleepHours!=null).length} sleep nights · ${days.where((d)=>d.hrv!=null).length} HRV days · $exercise activity days.',style:TextStyle(fontSize:10,color:Theme.of(context).colorScheme.onSurfaceVariant)),
      const Text('Observations are descriptive, not diagnostic. Missing values are excluded, not treated as zero.',style:TextStyle(fontSize:10)),
    ])));
  }

  @override
  Widget build(BuildContext context)=>FutureBuilder<_DashData>(future:_future,builder:(context,snapshot){
    if(snapshot.connectionState==ConnectionState.waiting)return const Center(child:CircularProgressIndicator());
    if(snapshot.hasError||!snapshot.hasData)return Center(child:Text('Dashboard could not load: ${snapshot.error?.toString()??'No data'}'));
    return ListView(padding:const EdgeInsets.fromLTRB(16,12,16,36),children:[
      Row(children:[
        Expanded(child:DropdownButtonFormField<String>(initialValue:_view,decoration:const InputDecoration(labelText:'Dashboard view'),items:const ['Overview','Energy','Nutrition','Training','Recovery','Weight','Relationships'].map((s)=>DropdownMenuItem(value:s,child:Text(s))).toList(),onChanged:(v){if(v!=null)setState(()=>_view=v);})),
        IconButton(tooltip:'Choose end date',icon:const Icon(Icons.calendar_month_outlined),onPressed:()async{final d=await showDatePicker(context:context,initialDate:widget.selectedDate,firstDate:DateTime(2018),lastDate:DateTime.now());if(d!=null)widget.onDateChanged(d);}),
      ]),
      const SizedBox(height:12),
      Wrap(spacing:8,runSpacing:10,children:[
        OutlinedButton.icon(onPressed:_exporting?null:()=>_imageExport(true),icon:const Icon(Icons.share_outlined),label:const Text('Share image')),
        OutlinedButton.icon(onPressed:_exporting?null:()=>_imageExport(false),icon:const Icon(Icons.image_outlined),label:const Text('Save image')),
        OutlinedButton.icon(onPressed:_exporting?null:()=>_pdfExport(true),icon:const Icon(Icons.ios_share_outlined),label:const Text('Share PDF')),
        OutlinedButton.icon(onPressed:_exporting?null:()=>_pdfExport(false),icon:const Icon(Icons.picture_as_pdf_outlined),label:const Text('Save PDF')),
        if(_exporting)const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)),
      ]),
      const SizedBox(height:18),_report(snapshot.data!),
    ]);
  });
}

class _Metric { const _Metric(this.label,this.unit); final String label,unit; }
class _DashData { const _DashData(this.days); final List<_DashDay> days; }
class _DashDay {
  _DashDay(this.date);
  final DateTime date;
  double runKm=0,trainingMinutes=0,hrSum=0,paceSum=0,paceDistance=0;
  int activityCount=0,hrCount=0;
  double? caloriesIn,carbs,protein,fibre,fat,sleepHours,sleepScore,hrv,restingHr,bodyBattery,stress,activeCalories,restingCalories,bmrCalories,totalBurn,weight;
}

class _LinePainter extends CustomPainter {
  const _LinePainter(this.values,this.color); final List<double?> values; final Color color;
  @override void paint(Canvas canvas,Size size){
    final valid=values.whereType<double>().where((v)=>v.isFinite).toList();
    if(valid.length<2){canvas.drawLine(Offset(0,size.height/2),Offset(size.width,size.height/2),Paint()..color=color.withValues(alpha:.3));return;}
    final lo=valid.reduce((a,b)=>a<b?a:b),hi=valid.reduce((a,b)=>a>b?a:b),range=(hi-lo).abs()<.001?1.0:hi-lo;
    final path=Path();var active=false;
    for(var i=0;i<values.length;i++){final v=values[i];if(v==null){active=false;continue;}final x=size.width*i/(values.length-1),y=size.height-8-(v-lo)/range*(size.height-16);if(!active){path.moveTo(x,y);active=true;}else{path.lineTo(x,y);}}
    canvas.drawPath(path,Paint()..color=color..strokeWidth=2.5..style=PaintingStyle.stroke..strokeCap=StrokeCap.round);
  }
  @override bool shouldRepaint(covariant _LinePainter old)=>old.values!=values||old.color!=color;
}
class _ScatterPainter extends CustomPainter {
  const _ScatterPainter(this.points); final List<({double x,double y})> points;
  @override void paint(Canvas canvas,Size size){
    final axis=Paint()..color=Colors.grey.withValues(alpha:.6);
    canvas.drawLine(Offset(22,size.height-18),Offset(size.width-6,size.height-18),axis);canvas.drawLine(const Offset(22,6),Offset(22,size.height-18),axis);
    if(points.isEmpty)return;
    final xs=points.map((p)=>p.x),ys=points.map((p)=>p.y); final loX=xs.reduce((a,b)=>a<b?a:b),hiX=xs.reduce((a,b)=>a>b?a:b),loY=ys.reduce((a,b)=>a<b?a:b),hiY=ys.reduce((a,b)=>a>b?a:b);
    final rx=(hiX-loX).abs()<.001?1.0:hiX-loX,ry=(hiY-loY).abs()<.001?1.0:hiY-loY;
    for(final p in points){final x=22+(p.x-loX)/rx*(size.width-32),y=size.height-18-(p.y-loY)/ry*(size.height-30);canvas.drawCircle(Offset(x,y),4,Paint()..color=const Color(0xFF4D9A70));}
  }
  @override bool shouldRepaint(covariant _ScatterPainter old)=>old.points!=points;
}
class _EnergyBars extends StatelessWidget {
  const _EnergyBars({required this.days,required this.valueOf}); final List<_DashDay> days; final double? Function(_DashDay,String) valueOf;
  @override Widget build(BuildContext context){
    final rows=days.where((d)=>d.caloriesIn!=null||valueOf(d,'totalBurn')!=null).toList();
    if(rows.isEmpty)return const Text('No energy data saved for this period.');
    return Column(children:rows.map((d){final intake=d.caloriesIn,burn=valueOf(d,'totalBurn'); final max=math.max(intake??0,burn??0).toDouble();if(max<=0)return const SizedBox.shrink();return Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Row(children:[
      SizedBox(width:34,child:Text('${d.date.day}/${d.date.month}',style:const TextStyle(fontSize:9))),
      Expanded(child:Column(children:[if(intake!=null)_bar(context,intake,max,Theme.of(context).colorScheme.primary,'Food'),if(burn!=null)_bar(context,burn,max,Colors.orange.shade700,'Burn')])),
    ]));}).toList());
  }
  Widget _bar(BuildContext c,double v,double max,Color color,String label)=>Padding(padding:const EdgeInsets.symmetric(vertical:1),child:Row(children:[
    SizedBox(width:32,child:Text(label,style:const TextStyle(fontSize:8))),
    Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(4),child:LinearProgressIndicator(value:(v/max).clamp(0,1).toDouble(),minHeight:7,backgroundColor:Theme.of(c).colorScheme.surfaceContainerHighest,color:color))),
    const SizedBox(width:4),SizedBox(width:43,child:Text(formatRunFuelNumber(v),textAlign:TextAlign.end,style:const TextStyle(fontSize:9))),
  ]));
}
