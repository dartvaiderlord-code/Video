import 'dart:io';

import 'protocol.dart';

enum CertificateAcceptance { reject, once, remember }

typedef CertificateApprover =
    Future<CertificateAcceptance> Function(ServerCertificate certificate);
typedef CertificateRememberer =
    Future<void> Function(ServerCertificate certificate);

/// An exception is scoped to one HTTPS origin and one exact leaf certificate.
/// A renewed self-signed leaf must be confirmed again, even with the same issuer.
class ServerCertificate {
  ServerCertificate({
    required this.origin,
    required this.fingerprint,
    required this.subject,
    required this.issuer,
    required this.startValidity,
    required this.endValidity,
    this.previousFingerprint,
  });

  factory ServerCertificate.fromX509(
    Uri origin,
    X509Certificate certificate, {
    String? previousFingerprint,
  }) => ServerCertificate(
    origin: origin,
    fingerprint: derFingerprint(certificate.der),
    subject: certificate.subject,
    issuer: certificate.issuer,
    startValidity: certificate.startValidity,
    endValidity: certificate.endValidity,
    previousFingerprint: previousFingerprint,
  );

  final Uri origin;
  final String fingerprint, subject, issuer;
  final DateTime startValidity, endValidity;
  final String? previousFingerprint;
  bool get changed =>
      previousFingerprint != null && previousFingerprint != fingerprint;
}

class CertificateDeclinedException implements Exception {
  @override
  String toString() => 'Подключение отменено: сертификат не подтверждён.';
}
