import 'package:flutter/material.dart';
import 'certificate_trust.dart';

Future<CertificateAcceptance> confirmServerCertificate(
  BuildContext context,
  ServerCertificate certificate,
) async =>
    await showDialog<CertificateAcceptance>(
      context: context,
      builder: (_) => CertificateConfirmationDialog(certificate: certificate),
    ) ??
    CertificateAcceptance.reject;

class CertificateConfirmationDialog extends StatelessWidget {
  const CertificateConfirmationDialog({super.key, required this.certificate});
  final ServerCertificate certificate;
  @override
  Widget build(BuildContext context) {
    final dates = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(
        certificate.changed
            ? 'Сертификат сервера изменился'
            : 'Недоверенный сертификат',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              certificate.origin.origin,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Подлинность сертификата не подтверждена. Продолжайте, если доверяете этому серверу. Можно сверить SHA-256 с владельцем.',
            ),
            const SizedBox(height: 12),
            const Text('SHA-256 сертификата'),
            SelectableText(
              certificate.fingerprint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            if (certificate.changed) ...[
              const SizedBox(height: 12),
              const Text('Ранее сохранённый SHA-256'),
              SelectableText(
                certificate.previousFingerprint!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Text('Выдан: ${certificate.subject}'),
            Text('Издатель: ${certificate.issuer}'),
            Text(
              'Действует: ${dates.formatMediumDate(certificate.startValidity.toLocal())} — ${dates.formatMediumDate(certificate.endValidity.toLocal())}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Доверие сохраняется только для этого адреса и этого сертификата. При замене недоверенного сертификата спросим снова.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, CertificateAcceptance.reject),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, CertificateAcceptance.once),
          child: const Text('Только сейчас'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, CertificateAcceptance.remember),
          child: const Text('Доверять и подключиться'),
        ),
      ],
    );
  }
}
