import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/main.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('restores the chosen CPU 480 FPS 50 Mbps capture settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'captureSettings': jsonEncode({
        'height': 1080,
        'fps': 480,
        'mbps': 50,
        'codec': 'libx264',
      }),
    });
    await tester.pumpWidget(const TavernApp(initialHostMode: true));
    await tester.pumpAndSettle();
    final fpsKey = ValueKey('Частота, FPS:${captureFrameRates.join(',')}');
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(find.byKey(fpsKey))
          .initialValue,
      480,
    );
    const encoderKey = ValueKey(
      'Кодировщик:auto,h264_nvenc,h264_amf,h264_qsv,libx264',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(find.byKey(encoderKey))
          .initialValue,
      'libx264',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'viewer on $platform shows join fields without capture controls',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(
            platform == TargetPlatform.android
                ? const Size(390, 844)
                : const Size(1264, 860),
          );
          await tester.pumpWidget(const TavernApp(initialHostMode: false));
          await tester.pumpAndSettle();
          expect(find.text('🏴‍☠️ Пиратский трактир'), findsOneWidget);
          expect(find.text('Полная ссылка приглашения'), findsOneWidget);
          expect(find.text('Код от капитана'), findsOneWidget);
          expect(tester.takeException(), isNull);
          // The Windows role-switch icon is not a capture request.
          expect(find.text('Найти экраны и окна'), findsNothing);
          expect(find.text('Поднять флаг и отчалить'), findsNothing);
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
          await tester.binding.setSurfaceSize(null);
        }
      },
    );
  }
  testWidgets('GPU H264 remains available up to 1000 FPS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const TavernApp(initialHostMode: true));
      await tester.pumpAndSettle();
      const encoderKey = ValueKey(
        'Кодировщик:auto,h264_nvenc,h264_amf,h264_qsv,libx264',
      );
      final fpsKey = ValueKey('Частота, FPS:${captureFrameRates.join(',')}');
      await tester.ensureVisible(find.byKey(encoderKey));
      await tester.tap(find.byKey(encoderKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NVIDIA · H.264').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(fpsKey));
      await tester.tap(find.byKey(fpsKey));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('1000'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('1000').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(find.byKey(encoderKey))
            .initialValue,
        'h264_nvenc',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
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
      await tester.tap(find.text('Сертификат сервера'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сбросить доверие'));
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
