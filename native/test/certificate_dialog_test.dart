import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/certificate_dialog.dart';
import 'package:pirate_tavern/certificate_trust.dart';

void main() {
  for (final choice in {
    'Отмена': CertificateAcceptance.reject,
    'Только сейчас': CertificateAcceptance.once,
    'Доверять и подключиться': CertificateAcceptance.remember,
  }.entries) {
    testWidgets('certificate dialog returns ${choice.value}', (tester) async {
      CertificateAcceptance? result;
      final cert = ServerCertificate(
        origin: Uri.parse('https://tavern.example:8443'),
        fingerprint: 'AA:BB:CC',
        subject: 'CN=Пиратский трактир',
        issuer: 'Local CA',
        startValidity: DateTime.utc(2026),
        endValidity: DateTime.utc(2030),
        previousFingerprint: 'OLD:PIN',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await confirmServerCertificate(context, cert);
                },
                child: const Text('Подключиться'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Подключиться'));
      await tester.pumpAndSettle();
      expect(find.text('Сертификат сервера изменился'), findsOneWidget);
      expect(find.text('https://tavern.example:8443'), findsOneWidget);
      expect(find.text('AA:BB:CC'), findsOneWidget);
      expect(find.text('OLD:PIN'), findsOneWidget);
      await tester.tap(find.text(choice.key));
      await tester.pumpAndSettle();
      expect(result, choice.value);
    });
  }
}
