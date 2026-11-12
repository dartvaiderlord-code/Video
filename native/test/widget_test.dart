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
          expect(
            find.text('Капитан: передавать'),
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
}
