import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class MobileConnectionService {
  // Coalesce overlapping manual/automatic triggers into one backend sync.
  // A deliberate later tap still performs a fresh sync after this completes.
  static final Map<String, Future<Map<String, dynamic>>> _syncInFlight = {};

  static const callback = 'com.runfuel.app.runfuel://oauth2redirect';
  static const _secure = FlutterSecureStorage();
  final _links = AppLinks();
  StreamSubscription<Uri>? _subscription;
  Completer<Uri>? _pending;

  Future<void> init() async {
    _subscription ??= _links.uriLinkStream.listen((uri) {
      if (_pending != null && !_pending!.isCompleted) _pending!.complete(uri);
    });
  }

  Future<String> _base() async {
    final p = await SharedPreferences.getInstance();
    final value = (p.getString('backend_url') ?? '').replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw Exception('Save your HTTPS backend URL in Settings first.');
    }
    return value;
  }

  String _random(int n) => base64Url.encode(List.generate(n, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

  Future<bool> isAuthorized() async => (await _secure.read(key: 'refresh')) != null;

  Future<void> connect() async {
    await init();
    final base = await _base();
    final prefs = await SharedPreferences.getInstance();
    var client = prefs.getString('runfuel_client_id');
    if (client == null) {
      final reg = await http.post(Uri.parse('$base/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'client_name':'RunFuel Android','redirect_uris':[callback],'token_endpoint_auth_method':'none'}));
      if (reg.statusCode != 201) throw Exception('App registration failed: ${reg.statusCode}');
      client = (jsonDecode(reg.body) as Map<String,dynamic>)['client_id'] as String;
      await prefs.setString('runfuel_client_id', client);
    }
    final verifier = _random(48);
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final state = _random(24);
    final uri = Uri.parse('$base/authorize').replace(queryParameters: {
      'response_type':'code','client_id':client,'redirect_uri':callback,
      'code_challenge':challenge,'code_challenge_method':'S256','state':state,'scope':'runfuel:read','resource':'$base/mcp'
    });
    _pending = Completer<Uri>();
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) throw Exception('Could not open sign-in.');
    final redirect = await _pending!.future.timeout(const Duration(minutes:5));
    if (redirect.queryParameters['state'] != state) throw Exception('Sign-in state mismatch.');
    final code = redirect.queryParameters['code'];
    if (code == null) throw Exception('Sign-in did not return a code.');
    final token = await http.post(Uri.parse('$base/token'),
      headers: {'Content-Type':'application/x-www-form-urlencoded'},
      body: {'grant_type':'authorization_code','client_id':client,'redirect_uri':callback,'code':code,'code_verifier':verifier,'resource':'$base/mcp'});
    if (token.statusCode != 200) throw Exception('Token exchange failed: ${token.statusCode}');
    final data = jsonDecode(token.body) as Map<String,dynamic>;
    await _secure.write(key:'access', value:data['access_token'] as String);
    await _secure.write(key:'refresh', value:data['refresh_token'] as String);
    await _secure.write(key:'expires', value:DateTime.now().add(Duration(seconds:data['expires_in'] as int)).toIso8601String());
    _pending = null;
  }

  Future<String> _runFuelAccessToken() async {
    final base = await _base();
    var access = await _secure.read(key: 'access');
    final expiry = DateTime.tryParse((await _secure.read(key: 'expires')) ?? '');
    if (access == null || expiry == null || expiry.isBefore(DateTime.now().add(const Duration(seconds: 60)))) {
      final refresh = await _secure.read(key: 'refresh');
      final prefs = await SharedPreferences.getInstance();
      final client = prefs.getString('runfuel_client_id');
      if (refresh == null || client == null) throw Exception('Connect RunFuel in Settings first.');
      final response = await http.post(
        Uri.parse('$base/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'grant_type':'refresh_token','client_id':client,'refresh_token':refresh,'resource':'$base/mcp'},
      );
      if (response.statusCode != 200) throw Exception('RunFuel connection expired. Reconnect in Settings.');
      final data = jsonDecode(response.body) as Map<String,dynamic>;
      access = data['access_token'] as String;
      await _secure.write(key:'access',value:access);
      await _secure.write(key:'refresh',value:data['refresh_token'] as String);
      await _secure.write(key:'expires',value:DateTime.now().add(Duration(seconds:data['expires_in'] as int)).toIso8601String());
    }
    return access;
  }

  Future<Map<String,dynamic>> connectMfp(String username, String password) async {
    if (username.trim().isEmpty || password.isEmpty) throw Exception('Enter your MyFitnessPal email/username and password.');
    final base = await _base();
    final access = await _runFuelAccessToken();
    final response = await http.post(
      Uri.parse('$base/api/mobile/mfp/connect'),
      headers: {'Authorization':'Bearer $access','Content-Type':'application/json'},
      body: jsonEncode({'username':username.trim(),'password':password}),
    ).timeout(const Duration(seconds: 45));
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (!contentType.contains('application/json')) {
      throw Exception(
        'RunFuel backend returned a non-JSON response (HTTP ${response.statusCode}). '
        'The backend deployment is missing the native MyFitnessPal sign-in endpoint. '
        'Update the backend deployment, then try again.',
      );
    }
    Map<String, dynamic> data;
    try {
      data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
    } on FormatException {
      throw Exception('RunFuel backend returned an unreadable response (HTTP ${response.statusCode}).');
    }
    if (response.statusCode != 200 || data['connected'] != true) {
      throw Exception((data['error'] ?? 'MyFitnessPal sign-in failed (HTTP ${response.statusCode}).').toString());
    }
    return data;
  }

  Future<Map<String,dynamic>> mfpStatus() async {
    final base = await _base();
    final access = await _runFuelAccessToken();
    final response = await http.get(
      Uri.parse('$base/api/mobile/mfp/status'),
      headers: {'Authorization':'Bearer $access'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception('Could not check MyFitnessPal connection.');
    return jsonDecode(response.body) as Map<String,dynamic>;
  }

  Future<void> disconnectMfp() async {
    final base = await _base();
    final access = await _runFuelAccessToken();
    final response = await http.delete(
      Uri.parse('$base/api/mobile/mfp/disconnect'),
      headers: {'Authorization':'Bearer $access'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception('Could not disconnect MyFitnessPal.');
  }

  Future<Map<String, dynamic>> askCoach(
    String question,
    Map<String, dynamic> context, {
    List<Map<String, String>> conversation = const [],
  }) async {
    final base = await _base();
    final access = await _runFuelAccessToken();
    final response = await http.post(
      Uri.parse('$base/api/mobile/coach'),
      headers: {
        'Authorization': 'Bearer $access',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'question': question, 'context': context, 'conversation': conversation}),
    ).timeout(const Duration(seconds: 55));
    Map<String, dynamic> data;
    try {
      data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
    } on FormatException {
      throw Exception('RunFuel AI coach returned an unreadable response.');
    }
    if (response.statusCode != 200 || data['reply'] is! String) {
      throw Exception((data['error'] ?? 'AI coach is unavailable.').toString());
    }
    return data;
  }

  Future<Map<String, dynamic>> sync({DateTime? date}) {
    final day = (date ?? DateTime.now()).toIso8601String().substring(0, 10);
    final active = _syncInFlight[day];
    if (active != null) return active;
    final request = _performSync(day);
    _syncInFlight[day] = request;
    return request.whenComplete(() {
      if (identical(_syncInFlight[day], request)) _syncInFlight.remove(day);
    });
  }

  Future<Map<String,dynamic>> _performSync(String day) async {
    final base = await _base();
    var access = await _secure.read(key:'access');
    final expiry = DateTime.tryParse((await _secure.read(key:'expires')) ?? '');
    if (access == null || expiry == null || expiry.isBefore(DateTime.now().add(const Duration(seconds:60)))) {
      final refresh = await _secure.read(key:'refresh');
      final prefs = await SharedPreferences.getInstance();
      final client = prefs.getString('runfuel_client_id');
      if (refresh == null || client == null) throw Exception('Connect RunFuel in Settings first.');
      final response = await http.post(Uri.parse('$base/token'),
        headers: {'Content-Type':'application/x-www-form-urlencoded'},
        body: {'grant_type':'refresh_token','client_id':client,'refresh_token':refresh,'resource':'$base/mcp'});
      if (response.statusCode != 200) throw Exception('Connection expired. Reconnect in Settings.');
      final data = jsonDecode(response.body) as Map<String,dynamic>;
      access = data['access_token'] as String;
      await _secure.write(key:'access',value:access);
      await _secure.write(key:'refresh',value:data['refresh_token'] as String);
      await _secure.write(key:'expires',value:DateTime.now().add(Duration(seconds:data['expires_in'] as int)).toIso8601String());
    }
    final uri = Uri.parse('$base/api/mobile/sync').replace(queryParameters: {'date': day});
    final response = await http.get(uri,headers:{'Authorization':'Bearer $access'});
    if (response.statusCode != 200) throw Exception('Sync failed: ${response.statusCode}');
    return jsonDecode(response.body) as Map<String,dynamic>;
  }
  /// Clears this device's RunFuel OAuth credentials without deleting account data,
  /// backend configuration, or the independent MyFitnessPal connection.
  Future<void> disconnect() async {
    await _secure.delete(key: 'access');
    await _secure.delete(key: 'refresh');
    await _secure.delete(key: 'expires');
  }
}
