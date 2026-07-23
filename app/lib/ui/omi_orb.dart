import 'package:flutter/material.dart';

class OmiActivityOrb extends StatelessWidget {
  const OmiActivityOrb({this.size = 46, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Omi idle',
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: const Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xfffffcec), Color(0xffe9e4cf)],
                ),
                boxShadow: [
                  BoxShadow(color: Color(0x40fffcec), blurRadius: 30),
                ],
              ),
            ),
            Icon(Icons.blur_on_rounded, color: Color(0xff171716)),
          ],
        ),
      ),
    ),
  );
}
