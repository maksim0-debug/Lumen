import 'dart:io';
import 'dart:ui';

void main() {
  const cOn = Color(0xFF0A1F0A);
  const cOff = Color(0xFF1A0000);

  stdout.writeln('cOn: $cOn');
  stdout.writeln('cOff: $cOff');

  // Verify logic using booleans
  List<Color> resolveColors(bool isSemiOn) =>
      isSemiOn ? [cOff, cOn] : [cOn, cOff];

  List<Color> colors = resolveColors(true);
  stdout.writeln('SemiOn colors: $colors (Left is Red, Right is Green?)');

  colors = resolveColors(false);
  stdout.writeln('SemiOff colors: $colors (Left is Green, Right is Red?)');
}

