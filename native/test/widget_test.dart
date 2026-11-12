import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'native viewer opens without requesting capture or microphone permission',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const TavernApp(initialHostMode: false));
      await tester.pumpAndSettle();
      expect(find.text('🏴‍☠️ Пиратский трактир'), findsOneWidget);
      expect(find.text('Полная ссылка приглашения'), findsOneWidget);
      expect(find.text('Код от капитана'), findsOneWidget);
      expect(find.byIcon(Icons.screen_share), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
