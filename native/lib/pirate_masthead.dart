import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Static vector artwork, with no animation competing with the video stream.
class PirateMasthead extends StatelessWidget {
  const PirateMasthead({super.key, required this.captain});
  final bool captain;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xff38281b), Color(0xff211b16)],
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xff6b4d2d)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                captain ? 'КАЮТА КАПИТАНА' : 'ГОСТЕВАЯ ПАЛУБА',
                style: const TextStyle(
                  color: Color(0xffd4a35a),
                  fontSize: 11,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Под одним флагом',
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  color: Color(0xfff6dfb8),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          label: 'Пиратский флаг и бутылка рома',
          image: true,
          child: const RepaintBoundary(
            child: CustomPaint(size: Size(112, 94), painter: _PirateEmblem()),
          ),
        ),
      ],
    ),
  );
}

class _PirateEmblem extends CustomPainter {
  const _PirateEmblem();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 200, size.height / 150);
    final rope = Paint()
      ..color = const Color(0xffa67b43)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final ink = Paint()..color = const Color(0xff101010);
    final bone = Paint()..color = const Color(0xfff4dfbc);
    canvas.drawLine(
      const Offset(24, 19),
      const Offset(24, 129),
      rope..strokeWidth = 4,
    );
    canvas.drawCircle(
      const Offset(24, 16),
      5,
      Paint()..color = const Color(0xffe5b866),
    );
    final flag = Path()
      ..moveTo(27, 24)
      ..cubicTo(52, 8, 82, 42, 113, 22)
      ..lineTo(108, 91)
      ..cubicTo(77, 105, 55, 75, 27, 89)
      ..close();
    canvas.drawPath(flag, ink);
    canvas.drawPath(flag, rope..strokeWidth = 1);
    final cross = Paint()
      ..color = const Color(0xfff4dfbc)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5;
    canvas.drawLine(const Offset(52, 70), const Offset(88, 86), cross);
    canvas.drawLine(const Offset(53, 86), const Offset(87, 70), cross);
    canvas.drawOval(const Rect.fromLTWH(53, 39, 35, 30), bone);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(62, 61, 19, 12),
        const Radius.circular(3),
      ),
      bone,
    );
    canvas.drawCircle(const Offset(63, 52), 5, ink);
    canvas.drawCircle(const Offset(79, 52), 5, ink);
    canvas.drawPath(
      Path()
        ..moveTo(70, 58)
        ..lineTo(67, 63)
        ..lineTo(73, 63)
        ..close(),
      ink,
    );
    // Amber rum bottle, its cork, paper label and a small glass highlight.
    canvas.save();
    canvas.translate(145, 85);
    canvas.rotate(.14);
    canvas.translate(-145, -85);
    final bottle = Path()
      ..moveTo(135, 40)
      ..lineTo(155, 40)
      ..lineTo(155, 61)
      ..quadraticBezierTo(174, 67, 174, 83)
      ..lineTo(174, 128)
      ..quadraticBezierTo(174, 137, 165, 137)
      ..lineTo(124, 137)
      ..quadraticBezierTo(116, 137, 116, 128)
      ..lineTo(116, 83)
      ..quadraticBezierTo(116, 67, 135, 61)
      ..close();
    canvas.drawPath(
      bottle,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff49331c), Color(0xffb77528), Color(0xff5b391e)],
        ).createShader(const Rect.fromLTWH(116, 40, 60, 100)),
    );
    canvas.drawPath(bottle, rope..strokeWidth = 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(132, 31, 26, 15),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xffb99059),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(122, 88, 46, 31),
        const Radius.circular(3),
      ),
      bone,
    );
    final label = TextPainter(
      text: const TextSpan(
        text: 'РОМ',
        style: TextStyle(
          color: Color(0xff38281b),
          fontSize: 16,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(145 - label.width / 2, 95));
    canvas.drawLine(
      const Offset(124, 74),
      const Offset(124, 83),
      Paint()
        ..color = const Color(0xfff3d9a4)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
    canvas.drawCircle(const Offset(74, 119), 17, rope..strokeWidth = 1.5);
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      canvas.drawLine(
        const Offset(74, 119),
        Offset(74 + math.sin(angle) * 14, 119 - math.cos(angle) * 14),
        rope,
      );
    }
    canvas.drawCircle(const Offset(74, 119), 3, bone);
    canvas.drawPath(
      Path()
        ..moveTo(12, 140)
        ..quadraticBezierTo(62, 147, 103, 137)
        ..quadraticBezierTo(144, 149, 190, 139),
      rope..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PirateEmblem oldDelegate) => false;
}
