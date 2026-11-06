import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'coaching_calculation_engine.dart';

class GeminiCoachService {
  GeminiCoachService();

  static const defaultModelId = 'gemini-3.5-flash-lite';
  static const supportedModels = <String, String>{
    'gemini-3.5-flash-lite': 'Gemini 3.5 Flash-Lite · Standard (default)',
    'gemini-3.6-flash': 'Gemini 3.6 Flash · Higher capability',
    'gemini-3.8-flash': 'Gemini 3.8 Flash · Most advanced',
  };

  static const _secureStorage = FlutterSecureStorage();
  static const _apiKeyStorageKey = 'runfuel_gemini_api_key_v1';
  static const _apiRoot = 'https://generativelanguage.googleapis.com/v1beta';

  static Future<String?> readApiKey() =>
      _secureStorage.read(key: _apiKeyStorageKey);

  static Future<bool> hasApiKey() async =>
      (await readApiKey())?.trim().isNotEmpty ?? false;

  static Future<void> saveApiKey(String value) async {
    final key = value.trim();
    if (key.length < 20) {
      throw ArgumentError('That does not look like a valid Google AI API key.');
    }
    await _secureStorage.write(key: _apiKeyStorageKey, value: key);
  }

  static Future<void> deleteApiKey() =>
      _secureStorage.delete(key: _apiKeyStorageKey);

  /// Verifies the saved key against Google's model-list endpoint. This sends
  /// no coaching prompt, conversation, or athlete data.
  Future<void> verifyConnection({required String apiKey}) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw StateError('No Gemini API key is configured.');
    }
    final response = await http
        .get(
          Uri.parse('$_apiRoot/models?pageSize=1'),
          headers: {'x-goog-api-key': key},
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 200) return;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('Google rejected the API key or its permissions.');
    }
    if (response.statusCode == 429) {
      throw StateError('Google rate-limited the connection check. Try again shortly.');
    }
    throw StateError('Gemini connection check failed (HTTP ${response.statusCode}).');
  }

  Future<String> reply({
    required String apiKey,
    required String model,
    required String question,
    required Map<String, dynamic> context,
    List<Map<String, String>> conversation = const [],
  }) async {
    if (!supportedModels.containsKey(model)) {
      throw ArgumentError('Unsupported Gemini model: $model');
    }
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw StateError('Add your own Google AI Studio API key in RunFuel settings.');
    }

    final verifiedContext =
        const CoachingCalculationEngine().encodeForCoach(context);
    if (verifiedContext.length > 220000) {
      throw StateError(
        'The coaching history is too large for one request. Reduce the selected history range and try again.',
      );
    }

    final recentConversation = conversation.length > 8
        ? conversation.sublist(conversation.length - 8)
        : conversation;
    final conversationText = recentConversation.map((message) {
      final role = message['role'] == 'assistant' ? 'Coach' : 'Athlete';
      final text = (message['text'] ?? '').trim();
      return text.isEmpty ? '' : '$role: $text';
    }).where((line) => line.isNotEmpty).join('\n');

    final prompt = '''
ATHLETE QUESTION
$question

RECENT CONVERSATION
${conversationText.isEmpty ? 'No previous conversation.' : conversationText}

RUNFUEL DATA (JSON)
$verifiedContext

COACHING INSTRUCTIONS
- Answer the athlete's actual question using only the supplied data and conversation.
- Treat verified_calculations as authoritative. Do not redo or alter those calculations.
- Garmin pace fields are seconds per kilometre. Use the supplied pace display fields; never interpret seconds/km as metres/second.
- Distinguish recorded facts, interpretations and recommendations.
- Adapt the analysis to primary_training_focus and the latest completed activity. Discuss the actual sport and available metrics; do not assume every activity is a run.
- For a full Review my day, format the response with Markdown headings: Today's Snapshot, Training & Performance, Recovery, Nutrition & Macro Targets, Coaching Insights, Your Next Steps. Keep sections concise and easy to scan.
- Compare logged calories, protein, carbohydrate, fat and fibre with corresponding MyFitnessPal daily goals whenever both values are supplied. Use the pre-rounded remaining_to_target_display and over_target_by_display strings in verified_calculations.nutrition_goal_comparisons; do not redo the subtraction or round from memory. Display differences to one decimal place (for example, 75.5 g against 69.3 g is 6.2 g over). Show a compact Markdown table. Never invent missing goals or use generic macro targets as if they were personal. Mark diary totals as logged so far when completeness is unknown. Relate fuelling advice to the actual latest workout and selected sport.
- Treat diary_completeness='unknown' or any explicitly partial/in-progress diary as incomplete. Describe numbers only as intake logged so far. Do not label calories or carbohydrates as a confirmed daily shortfall, infer under-fuelling, or recommend making up the difference from a partial diary. State that the final daily intake cannot be assessed until logging is complete; only discuss practical fuelling in relation to an upcoming/recent session without treating the partial total as a deficit. If the diary is explicitly complete, normal goal comparisons may be discussed as estimates, not hard requirements.
- Coaching Insights should interpret the data for readiness, performance, consistency, recovery and fuelling rather than merely restating metrics.
- Use a flexible weekly decision framework: PROGRESS, CONSOLIDATE or STEP BACK. Explain which evidence supports the choice and what would change it.
- PROGRESS only when the current workload appears comfortably absorbed: sessions completed as intended, easy effort remains appropriate, no meaningful worsening pain or illness symptoms, and subjective recovery is generally good. Suggest a modest next step, not an automatic percentage increase.
- CONSOLIDATE when the athlete is coping but the evidence is mixed, incomplete, or a recent increase in frequency, longest session or total load has not yet been absorbed. When describing a percentage increase, always include the absolute distances/session counts and consider the starting volume; do not call a percentage jump inherently dangerous or infer tissue stress from the percentage alone.
- STEP BACK when multiple independent warning signs align, or when pain alters gait/worsens, normal walking is affected, or illness symptoms make exercise inappropriate. Do not diagnose; advise stopping/modifying exercise and seeking appropriate clinical assessment for persistent, severe or concerning symptoms.
- Never require exact RHR, HRV, Body Battery, calorie or carbohydrate values as gates for progression. Interpret wearable metrics against the individual's available baseline and multi-day trend; if the baseline is inadequate, say so.
- Describe small wearable differences from a personal median as small/contextual, not as evidence of impaired recovery. A Body Battery value near its personal median is not, by itself, a meaningful warning sign. Do not claim the body is 'processing' a training increase as a fact; describe this only as one possible interpretation when multiple signals support it.
- Do not use a universal 5-10% weekly progression rule or a fixed 24-hour symptom-free rule. Consider recent training history, frequency, longest session, effort, subjective recovery, goals and data completeness.
- A single imperfect wearable reading or incomplete food diary must not automatically veto progression. Multiple converging warning signs matter more than one isolated metric.
- Treat MyFitnessPal goals as estimates, not mandatory physiological requirements. Evaluate recorded intake over comparable completed days; missing or partial logs are unknown, not deficits.
- Never attribute RHR, HRV, Body Battery or performance changes to under-fuelling or training load as a proven cause without evidence. Describe plausible contributors as possibilities.
- When giving a weekly decision, include: decision, evidence for it, what to monitor, and what would justify changing the decision.
- Use coach_memory, active events/goals, training pauses/returns and dated daily reviews when relevant. Distinguish current facts from historical context; never assume an old injury or illness is still active. Respect the athlete's stated goals and prior decisions unless newer information changes them.
- Do not invent dates, heart-rate zones, maximum heart rate, energy expenditure, training load, recovery scores, nutrition totals or missing measurements.
- BMR is not a mandatory minimum calorie intake. Do not infer TDEE from BMR without activity evidence.
- Do not diagnose illness or make unsupported claims about immune, hormonal or metabolic effects.
- Be conservative when discussing return to training after illness. Ask about symptom recurrence or unusual exercise intolerance rather than diagnosing.
- Do not claim to have changed the app, Garmin, MyFitnessPal, a training plan or external records.
- Do not generate code, build an app, create a dashboard or perform external actions.
- Keep the report readable and practical. Give up to three useful next steps.
- If the evidence is insufficient, state exactly what is missing.
''';

    final uri = Uri.parse('$_apiRoot/models/$model:generateContent');
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': key,
          },
          body: jsonEncode({
            'systemInstruction': {
              'parts': [
                {
                  'text':
                      'You are RunFuel, a careful running and nutrition coach. You provide text-only coaching analysis, not software development or external actions.',
                }
              ]
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'maxOutputTokens': 8192,
              'thinkingConfig': {'thinkingLevel': 'medium'},
            },
          }),
        )
        .timeout(const Duration(seconds: 75));

    Map<String, dynamic> payload;
    try {
      payload = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
    } on FormatException {
      throw StateError(
        'Google Gemini returned an unreadable response (HTTP ${response.statusCode}).',
      );
    }

    if (response.statusCode != 200) {
      final error = payload['error'];
      final message = error is Map
          ? (error['message'] ?? 'Request failed').toString()
          : 'Request failed';
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError('Google rejected the API key or its permissions. Check your key in RunFuel settings.');
      }
      if (response.statusCode == 429) {
        throw StateError('Google Gemini rate limit reached. Wait a little and try again.');
      }
      throw StateError('Google Gemini request failed (HTTP ${response.statusCode}): $message');
    }

    final candidates = payload['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      final blockReason =
          (payload['promptFeedback'] as Map?)?['blockReason']?.toString();
      throw StateError(
        blockReason == null
            ? 'Google Gemini did not return a coaching response.'
            : 'Google Gemini could not answer this request (reason: $blockReason).',
      );
    }

    final candidate = candidates.first;
    final parts = (candidate is Map ? candidate['content'] as Map? : null)?['parts'];
    final answer = parts is List
        ? parts
            .whereType<Map>()
            .map((part) => part['text']?.toString() ?? '')
            .where((text) => text.isNotEmpty)
            .join()
            .trim()
        : '';
    if (answer.isEmpty) {
      throw StateError('Google Gemini returned an empty coaching response.');
    }
    return answer;
  }
}
