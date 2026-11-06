import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:runfuel/main.dart';

Future<void> _pumpUi(WidgetTester tester) async {
  // Advance page/dialog transitions over several frames without waiting for
  // indeterminate progress indicators to stop animating.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
}

Future<void> _navigateTo(WidgetTester tester, int index) async {
  final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
  navigation.onDestinationSelected!(index);
  await _pumpUi(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RunFuelAppearance.choice.value = 'system';
  });

  testWidgets('RunFuel home and navigation render', (tester) async {
    await tester.pumpWidget(const RunFuelApp());
    await _pumpUi(tester);

    expect(find.text('Build consistency.'), findsOneWidget);
    expect(find.text('Training'), findsOneWidget);

    await _navigateTo(tester, 2);
    expect(find.text('Your RunFuel coach'), findsOneWidget);
    expect(find.text('What would you like help with?'), findsOneWidget);
  });

  testWidgets('Coach accepts and saves a question locally', (tester) async {
    await tester.pumpWidget(const RunFuelApp());
    await _pumpUi(tester);

    await _navigateTo(tester, 2);
    expect(find.text('Your RunFuel coach'), findsOneWidget);

    final composer = find.byKey(const Key('coach-question-input'));
    await tester.scrollUntilVisible(
      composer,
      300,
      scrollable: find.descendant(
        of: find.byType(CoachPage),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.tap(composer);
    await tester.pump();
    expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
    await tester.enterText(composer, 'How should I build back to 5 km?');
    final saveQuestion = find.ancestor(
      of: find.byTooltip('Save question'),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(saveQuestion).onPressed, isNotNull,
        reason: 'Coach must finish loading before the question is saved');
    await tester.tap(saveQuestion);
    await _pumpUi(tester);

    final savedQuestion = find.text('How should I build back to 5 km?');
    await tester.scrollUntilVisible(
      savedQuestion,
      -240,
      scrollable: find.descendant(
        of: find.byType(CoachPage),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(savedQuestion, findsOneWidget);
    expect(find.text('Saved on this device · not sent to AI yet'), findsOneWidget);
  });

  testWidgets('ChatGPT handoff previews the exact data and asks before sharing', (tester) async {
    await tester.pumpWidget(const RunFuelApp());
    await _pumpUi(tester);

    await _navigateTo(tester, 2);
    expect(find.text('Your RunFuel coach'), findsOneWidget);

    final composer = find.byKey(const Key('coach-question-input'));
    await tester.scrollUntilVisible(
      composer,
      300,
      scrollable: find.descendant(
        of: find.byType(CoachPage),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.tap(composer);
    await tester.enterText(composer, 'Review my running progress');
    final openChatGpt = find.text('Open ChatGPT');
    await tester.scrollUntilVisible(
      openChatGpt,
      -300,
      scrollable: find.descendant(
        of: find.byType(CoachPage),
        matching: find.byType(Scrollable),
      ).first,
    );
    await _pumpUi(tester);
    await tester.tap(openChatGpt);
    await _pumpUi(tester);

    expect(find.text('Share a summary with ChatGPT?'), findsOneWidget);
    expect(find.textContaining('My question:'), findsOneWidget);
    expect(find.textContaining('GPS tracks'), findsOneWidget);
    expect(find.text('Choose app'), findsOneWidget);

    // Cancelling must not invoke the Android share sheet.
    await tester.tap(find.text('Cancel'));
    await _pumpUi(tester);
    expect(find.text('Share a summary with ChatGPT?'), findsNothing);
  });

  testWidgets('ChatGPT reply can be pasted back into the RunFuel conversation', (tester) async {
    await tester.pumpWidget(const RunFuelApp());
    await _pumpUi(tester);

    await _navigateTo(tester, 2);
    expect(find.text('Your RunFuel coach'), findsOneWidget);
    final pasteReply = find.text('Paste Reply');
    await tester.ensureVisible(pasteReply);
    await _pumpUi(tester);
    await tester.tap(pasteReply);
    await _pumpUi(tester);

    expect(find.text('Add ChatGPT response'), findsOneWidget);
    final replyField = find.byType(TextField).last;
    await tester.enterText(replyField, 'Your recovery trend looks positive. Keep the next run easy.');
    await tester.tap(find.text('Add to conversation'));
    await _pumpUi(tester);

    expect(find.text('Your recovery trend looks positive. Keep the next run easy.'), findsOneWidget);
    expect(find.text('CHATGPT RESPONSE'), findsOneWidget);
    expect(find.text('Added from your ChatGPT app'), findsOneWidget);
  });

  testWidgets('MyFitnessPal native connection form is reachable from Settings', (tester) async {
    await tester.pumpWidget(const RunFuelApp());
    await _pumpUi(tester);

    await _navigateTo(tester, 5);
    expect(find.text('Training Preferences'), findsOneWidget);

    // The label changes while native status is checked; target the stable
    // Settings action key rather than assuming one particular status string.
    final mfpButton = find.byKey(const Key('settings-mfp-connection-button'));
    await tester.scrollUntilVisible(
      mfpButton,
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('settings-page-body')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await _pumpUi(tester);
    expect(mfpButton, findsOneWidget);
    expect(tester.widget<OutlinedButton>(mfpButton).onPressed, isNotNull,
        reason: 'MyFitnessPal Settings action must be enabled after Settings loads');

    await tester.tap(mfpButton);
    await tester.pump();
    await _pumpUi(tester);

    expect(find.byType(MfpConnectionPage), findsOneWidget);
    expect(find.text('MyFitnessPal connection'), findsOneWidget);
    expect(find.text('MyFitnessPal email or username'), findsOneWidget);
    expect(find.text('MyFitnessPal password'), findsOneWidget);
    expect(find.text('Connect MyFitnessPal'), findsOneWidget);

    final passwordField = tester.widget<TextField>(
      find.ancestor(
        of: find.text('MyFitnessPal password'),
        matching: find.byType(TextField),
      ),
    );
    expect(passwordField.obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await _pumpUi(tester);
    final visiblePasswordField = tester.widget<TextField>(
      find.ancestor(
        of: find.text('MyFitnessPal password'),
        matching: find.byType(TextField),
      ),
    );
    expect(visiblePasswordField.obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
  });

}
