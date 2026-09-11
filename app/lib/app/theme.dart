import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Pillar colors follow the IWF bumper-plate code (docs/PLAN.md): 25 kg red,
/// 20 kg blue, 15 kg yellow, 10 kg green.
@immutable
class PillarColors extends ThemeExtension<PillarColors> {
  const PillarColors({
    required this.train,
    required this.fuel,
    required this.move,
    required this.body,
    required this.coach,
  });

  final Color train;
  final Color fuel;
  final Color move;
  final Color body;
  final Color coach;

  static const light = PillarColors(
    train: Color(0xFFC62F28),
    fuel: Color(0xFF2A8A4B),
    move: Color(0xFFD8A300),
    body: Color(0xFF2455B8),
    coach: Color(0xFF15191C),
  );

  static const dark = PillarColors(
    train: Color(0xFFFF5A4E),
    fuel: Color(0xFF4CC27A),
    move: Color(0xFFF2C230),
    body: Color(0xFF6B95FF),
    coach: Color(0xFFE5E8E9),
  );

  static PillarColors of(BuildContext context) =>
      Theme.of(context).extension<PillarColors>()!;

  @override
  PillarColors copyWith({
    Color? train,
    Color? fuel,
    Color? move,
    Color? body,
    Color? coach,
  }) =>
      PillarColors(
        train: train ?? this.train,
        fuel: fuel ?? this.fuel,
        move: move ?? this.move,
        body: body ?? this.body,
        coach: coach ?? this.coach,
      );

  @override
  PillarColors lerp(PillarColors? other, double t) {
    if (other == null) return this;
    return PillarColors(
      train: Color.lerp(train, other.train, t)!,
      fuel: Color.lerp(fuel, other.fuel, t)!,
      move: Color.lerp(move, other.move, t)!,
      body: Color.lerp(body, other.body, t)!,
      coach: Color.lerp(coach, other.coach, t)!,
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final ground = dark ? const Color(0xFF101315) : const Color(0xFFF3F5F4);
  final surface = dark ? const Color(0xFF171B1E) : const Color(0xFFFFFFFF);
  final sunk = dark ? const Color(0xFF1D2226) : const Color(0xFFE8ECEA);
  final ink = dark ? const Color(0xFFE5E8E9) : const Color(0xFF15191C);
  final ink2 = dark ? const Color(0xFFAAB2B8) : const Color(0xFF48525A);
  final rule = dark ? const Color(0xFF283035) : const Color(0xFFD7DDDC);
  final accent = dark ? const Color(0xFFFF5A4E) : const Color(0xFFC62F28);

  final scheme =
      ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
    primary: ink,
    onPrimary: ground,
    tertiary: accent,
    onTertiary: dark ? ground : Colors.white,
    error: accent,
    surface: ground,
    onSurface: ink,
    onSurfaceVariant: ink2,
    surfaceContainerLowest: surface,
    surfaceContainerLow: surface,
    surfaceContainer: surface,
    surfaceContainerHigh: sunk,
    surfaceContainerHighest: sunk,
    outline: ink2,
    outlineVariant: rule,
  );

  final base = ThemeData(brightness: brightness).textTheme;
  final body = GoogleFonts.ibmPlexSansTextTheme(base);
  TextStyle display(TextStyle? style, double size) => GoogleFonts.archivoNarrow(
        textStyle: style,
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: 1.05,
      );
  final textTheme = body
      .copyWith(
        displayLarge: display(base.displayLarge, 64),
        displayMedium: display(base.displayMedium, 48),
        displaySmall: display(base.displaySmall, 38),
        headlineLarge: display(base.headlineLarge, 34),
        headlineMedium: display(base.headlineMedium, 30),
        headlineSmall: display(base.headlineSmall, 26),
        titleLarge: display(base.titleLarge, 24),
      )
      .apply(bodyColor: ink, displayColor: ink);

  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  const buttonSize = Size.fromHeight(52);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: ground,
    textTheme: textTheme,
    extensions: [dark ? PillarColors.dark : PillarColors.light],
    appBarTheme: AppBarTheme(
      backgroundColor: ground,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: rule),
      ),
    ),
    dividerTheme: DividerThemeData(color: rule, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: sunk,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: buttonSize, shape: shape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        shape: shape,
        foregroundColor: ink,
        side: BorderSide(color: ink2),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: rule),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: rule),
      ),
    ),
  );
}
