import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'viewer on $platform shows join fields without capture controls',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          SharedPreferences.setMockInitialValues({});
          await tester.pumpWidget(const TavernApp(initialHostMode: false));
          await tester.pumpAndSettle();
          expect(find.text('🏴‍☠️ Пиратский трактир'), findsOneWidget);
          expect(find.text('Полная ссылка приглашения'), findsOneWidget);
          expect(find.text('Код от капитана'), findsOneWidget);
          // The Windows role-switch icon is not a capture request.
          expect(find.text('Найти экраны и окна'), findsNothing);
          expect(find.text('Поднять флаг и передавать'), findsNothing);
          expect(find.text('Капитан: передавать'), findsNothing);
          expect(
            find.text('Капитан'),
            platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        } finally {
          // The binding checks this invariant before addTearDown runs.
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
  testWidgets(
    'reset trust clears only the selected server CA and certificate pin',
    (tester) async {
      const first = 'https://one.example:8443',
          second = 'https://two.example:8443';
      final pin = List.filled(32, 'AA').join(':');
      SharedPreferences.setMockInitialValues({
        'trustedCaByOrigin': jsonEncode({first: 'QQ==', second: 'Qg=='}),
        'trustedCertificatePinsByOrigin': jsonEncode({first: pin, second: pin}),
      });
      await tester.pumpWidget(const TavernApp(initialHostMode: false));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Полная ссылка приглашения'),
        '$first/#room=${'a' * 24}&token=${'b' * 48}',
      );
      await tester.tap(find.text('Сбросить доверие'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('trustedCaByOrigin')!), {
        second: 'Qg==',
      });
      expect(jsonDecode(prefs.getString('trustedCertificatePinsByOrigin')!), {
        second: pin,
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
