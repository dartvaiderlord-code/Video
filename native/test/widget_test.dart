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
    'high FPS excludes H264 and switches back to VP8 when FPS increases',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(const TavernApp(initialHostMode: true));
        await tester.pumpAndSettle();
        const fpsKey = ValueKey('Частота, FPS:30,60,120,144,165,240');
        const fastKey = ValueKey('Предпочтение кодека:VP8,VP9');
        const slowKey = ValueKey('Предпочтение кодека:VP8,VP9,H264');
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(find.byKey(fastKey))
              .initialValue,
          'VP8',
        );
        await tester.ensureVisible(find.byKey(fpsKey));
        await tester.tap(find.byKey(fpsKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('60').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(slowKey));
        await tester.tap(find.byKey(slowKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('H264').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(fpsKey));
        await tester.tap(find.byKey(fpsKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('120').last);
        await tester.pumpAndSettle();
        expect(find.byKey(slowKey), findsNothing);
        final codecs = tester.widget<DropdownButtonFormField<String>>(
          find.byKey(fastKey),
        );
        expect(codecs.initialValue, 'VP8');
        await tester.ensureVisible(find.byKey(fastKey));
        await tester.tap(find.byKey(fastKey));
        await tester.pumpAndSettle();
        expect(find.text('H264'), findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
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
