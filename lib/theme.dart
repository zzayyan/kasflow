import 'package:flutter/material.dart';

// Design tokens from the "Cashflow UI/UX" canvas (direction E, forest green).
// Colors come from AppColors, a ThemeExtension, so light and dark switch together:
// `final c = AppColors.of(context);`. Type is Outfit (assets/fonts, OFL).

/// Every color the screens use. Field names match the "Token desain" artboard.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceMuted,
    required this.divider,
    required this.outline,
    required this.ink,
    required this.inkMuted,
    required this.primary,
    required this.onPrimary,
    required this.hero,
    required this.onHero,
    required this.onHeroMuted,
    required this.heroChip,
    required this.onHeroChip,
    required this.onHeroAlert,
    required this.primarySoft,
    required this.onPrimarySoft,
    required this.income,
    required this.alert,
    required this.onAlert,
    required this.alertSoft,
    required this.needLevels,
    required this.chart,
    required this.chartOther,
    required this.chartMuted,
  });

  final Color bg; // screen background
  final Color surface; // cards, lists, bottom navigation
  final Color surfaceMuted; // quick-action tiles, chips, segmented track
  final Color divider; // lines between rows
  final Color outline; // outlined buttons and inputs
  final Color ink; // main text and icons
  final Color inkMuted; // secondary text
  final Color primary; // main buttons, selected states
  final Color onPrimary;
  final Color hero; // balance and summary cards (dark green in both modes)
  final Color onHero;
  final Color onHeroMuted;
  final Color heroChip; // small chip on a hero card, e.g. "5,41 jt"
  final Color onHeroChip;
  final Color onHeroAlert; // over budget on a hero card: 4.4:1 against heroChip
  final Color primarySoft; // info and suggestion cards
  final Color onPrimarySoft;
  final Color income; // incoming amounts
  final Color alert; // late bills, over budget, badges. Never used for "Ingin".
  final Color onAlert;
  final Color alertSoft; // background behind an alert
  /// must / need / want / no level. Tan is reserved for "want" (Ingin).
  final Map<String?, Color> needLevels;

  /// Categorical chart colors, largest slice first, then [chartOther] for the folded rest.
  /// Validated with the dataviz validator against [surface] (light and dark): the design's green
  /// steps could not be told apart. Light slots 3-5 sit below 3:1, so values are always labelled.
  final List<Color> chart;
  final Color chartOther; // "Lainnya"
  final Color chartMuted; // bars that are not the one in focus (trend chart)

  static const light = AppColors(
    bg: Color(0xFFF1F0EB),
    surface: Color(0xFFFAF9F5),
    surfaceMuted: Color(0xFFE6E5DE),
    divider: Color(0xFFECEBE5),
    outline: Color(0xFFC9CCC4),
    ink: Color(0xFF18201B),
    inkMuted: Color(0xFF646A64),
    primary: Color(0xFF1E4A35),
    onPrimary: Color(0xFFFFFFFF),
    hero: Color(0xFF1E4A35),
    onHero: Color(0xFFFFFFFF),
    onHeroMuted: Color(0xFFE3EEE5),
    heroChip: Color(0xFF2E5E45),
    onHeroChip: Color(0xFFCDE8D2),
    onHeroAlert: Color(0xFFF6B8A2),
    primarySoft: Color(0xFFDDE9DE),
    onPrimarySoft: Color(0xFF3F5546),
    income: Color(0xFF1E6B43),
    alert: Color(0xFFA4431F),
    onAlert: Color(0xFFFFFFFF),
    alertSoft: Color(0xFFF6E1D8),
    needLevels: {
      'must': Color(0xFF1E4A35),
      'need': Color(0xFF4F8A66), // the design's #7FAF8C was too close to want's tan (dataviz validator)
      'want': Color(0xFFD9A273),
      null: Color(0xFFD6D8D1),
    },
    chart: [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100), Color(0xFFE87BA4)],
    chartOther: Color(0xFFC9CCC4),
    chartMuted: Color(0xFF6F9A7B), // 3:1 against surface, and against the selected bar
  );

  static const dark = AppColors(
    bg: Color(0xFF0F1612),
    surface: Color(0xFF18211C),
    surfaceMuted: Color(0xFF242E28),
    divider: Color(0xFF26302A),
    outline: Color(0xFF3A443D),
    ink: Color(0xFFECEFEA),
    inkMuted: Color(0xFF9BA59D),
    primary: Color(0xFF8CC5A0),
    onPrimary: Color(0xFF0F1612),
    hero: Color(0xFF1E4A35),
    onHero: Color(0xFFFFFFFF),
    onHeroMuted: Color(0xFFE3EEE5),
    heroChip: Color(0xFF2E5E45),
    onHeroChip: Color(0xFFCDE8D2),
    onHeroAlert: Color(0xFFF6B8A2),
    primarySoft: Color(0xFF1C3326),
    onPrimarySoft: Color(0xFFB9D6C0),
    income: Color(0xFF7FD19E),
    alert: Color(0xFFE8876A),
    onAlert: Color(0xFF0F1612),
    alertSoft: Color(0xFF3A2119),
    needLevels: {
      'must': Color(0xFFA9D2B2),
      'need': Color(0xFF4F8A66),
      'want': Color(0xFFD9A273),
      null: Color(0xFF4A524C),
    },
    chart: [Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFC98500), Color(0xFFD55181)],
    chartOther: Color(0xFF4A524C),
    chartMuted: Color(0xFF48745B), // 3:1 against surface; the selected bar also carries its value
  );

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>() ?? light;

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceMuted,
    Color? divider,
    Color? outline,
    Color? ink,
    Color? inkMuted,
    Color? primary,
    Color? onPrimary,
    Color? hero,
    Color? onHero,
    Color? onHeroMuted,
    Color? heroChip,
    Color? onHeroChip,
    Color? onHeroAlert,
    Color? primarySoft,
    Color? onPrimarySoft,
    Color? income,
    Color? alert,
    Color? onAlert,
    Color? alertSoft,
    Map<String?, Color>? needLevels,
    List<Color>? chart,
    Color? chartOther,
    Color? chartMuted,
  }) => AppColors(
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    surfaceMuted: surfaceMuted ?? this.surfaceMuted,
    divider: divider ?? this.divider,
    outline: outline ?? this.outline,
    ink: ink ?? this.ink,
    inkMuted: inkMuted ?? this.inkMuted,
    primary: primary ?? this.primary,
    onPrimary: onPrimary ?? this.onPrimary,
    hero: hero ?? this.hero,
    onHero: onHero ?? this.onHero,
    onHeroMuted: onHeroMuted ?? this.onHeroMuted,
    heroChip: heroChip ?? this.heroChip,
    onHeroChip: onHeroChip ?? this.onHeroChip,
    onHeroAlert: onHeroAlert ?? this.onHeroAlert,
    primarySoft: primarySoft ?? this.primarySoft,
    onPrimarySoft: onPrimarySoft ?? this.onPrimarySoft,
    income: income ?? this.income,
    alert: alert ?? this.alert,
    onAlert: onAlert ?? this.onAlert,
    alertSoft: alertSoft ?? this.alertSoft,
    needLevels: needLevels ?? this.needLevels,
    chart: chart ?? this.chart,
    chartOther: chartOther ?? this.chartOther,
    chartMuted: chartMuted ?? this.chartMuted,
  );

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceMuted: l(surfaceMuted, other.surfaceMuted),
      divider: l(divider, other.divider),
      outline: l(outline, other.outline),
      ink: l(ink, other.ink),
      inkMuted: l(inkMuted, other.inkMuted),
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      hero: l(hero, other.hero),
      onHero: l(onHero, other.onHero),
      onHeroMuted: l(onHeroMuted, other.onHeroMuted),
      heroChip: l(heroChip, other.heroChip),
      onHeroChip: l(onHeroChip, other.onHeroChip),
      onHeroAlert: l(onHeroAlert, other.onHeroAlert),
      primarySoft: l(primarySoft, other.primarySoft),
      onPrimarySoft: l(onPrimarySoft, other.onPrimarySoft),
      income: l(income, other.income),
      alert: l(alert, other.alert),
      onAlert: l(onAlert, other.onAlert),
      alertSoft: l(alertSoft, other.alertSoft),
      // Category colors don't blend meaningfully; switch halfway.
      needLevels: t < 0.5 ? needLevels : other.needLevels,
      chart: t < 0.5 ? chart : other.chart,
      chartOther: l(chartOther, other.chartOther),
      chartMuted: l(chartMuted, other.chartMuted),
    );
  }
}

/// Corner radii from the canvas. Pills (buttons, chips, segmented) use StadiumBorder.
abstract final class AppRadius {
  static const hero = 24.0; // balance card, summary cards
  static const card = 22.0; // lists, cards
  static const tile = 20.0; // quick-action tiles
  static const input = 16.0; // text fields, small boxes
  static const sheet = 28.0; // bottom sheet top corners
}

/// Spacing from the canvas.
abstract final class AppSpace {
  static const page = 20.0; // left and right screen padding
  static const section = 20.0; // between sections
  static const card = 16.0; // inside cards
  static const gap = 12.0; // between items in a row or grid
  static const tight = 8.0;
  static const touchMin = 44.0; // anything tappable
  static const rowMin = 56.0; // list rows (56 to 64)
}

/// Type scale (Outfit). Amounts use tabular figures so digits line up in lists.
abstract final class AppText {
  static const family = 'Outfit';
  static const _tabular = [FontFeature.tabularFigures()];

  static const amountXl = TextStyle(
    fontFamily: family,
    fontSize: 46,
    fontWeight: FontWeight.w600,
    letterSpacing: -1,
    height: 1.1,
    fontFeatures: _tabular,
  ); // amount field in the record form
  static const amountLg = TextStyle(
    fontFamily: family,
    fontSize: 38,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.1,
    fontFeatures: _tabular,
  ); // total balance
  static const amount = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    fontFeatures: _tabular,
  ); // amounts in list rows
  static const title = TextStyle(fontFamily: family, fontSize: 24, fontWeight: FontWeight.w600, height: 1.25);
  static const heading = TextStyle(fontFamily: family, fontSize: 17, fontWeight: FontWeight.w600, height: 1.3);
  static const bodyStrong = TextStyle(fontFamily: family, fontSize: 15, fontWeight: FontWeight.w600, height: 1.35);
  static const body = TextStyle(fontFamily: family, fontSize: 15, fontWeight: FontWeight.w400, height: 1.4);
  static const label = TextStyle(fontFamily: family, fontSize: 13, fontWeight: FontWeight.w400, height: 1.35);
  static const caption = TextStyle(fontFamily: family, fontSize: 12, fontWeight: FontWeight.w400, height: 1.35);
  static const button = TextStyle(fontFamily: family, fontSize: 16, fontWeight: FontWeight.w600);
}

/// Light unless the user picks Gelap or Ikuti sistem in Pengaturan (this phone's pref 'theme').
final themeMode = ValueNotifier(ThemeMode.light);

ThemeMode themeModeFromPref(String? value) => ThemeMode.values.asNameMap()[value] ?? ThemeMode.light;

ThemeData buildAppTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final lightMode = brightness == Brightness.light;

  final scheme = ColorScheme.fromSeed(seedColor: AppColors.light.primary, brightness: brightness).copyWith(
    primary: c.primary,
    onPrimary: c.onPrimary,
    primaryContainer: c.primarySoft,
    onPrimaryContainer: c.onPrimarySoft,
    secondaryContainer: c.primarySoft,
    onSecondaryContainer: c.ink,
    // App bars sit on the screen background, so surface = bg; cards set their own color.
    surface: c.bg,
    onSurface: c.ink,
    onSurfaceVariant: c.inkMuted,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.bg,
    surfaceContainerHigh: c.surfaceMuted,
    surfaceContainerHighest: c.surfaceMuted,
    surfaceTint: Colors.transparent,
    outline: c.outline,
    outlineVariant: c.divider,
    error: c.alert,
    onError: c.onAlert,
  );

  final textTheme = TextTheme(
    headlineSmall: AppText.title,
    titleLarge: AppText.title.copyWith(fontSize: 20),
    titleMedium: AppText.heading,
    titleSmall: AppText.bodyStrong,
    bodyLarge: AppText.body,
    bodyMedium: AppText.body,
    bodySmall: AppText.caption,
    labelLarge: AppText.bodyStrong,
    labelMedium: AppText.label,
    labelSmall: AppText.caption.copyWith(fontWeight: FontWeight.w600),
  ).apply(bodyColor: c.ink, displayColor: c.ink);

  final pillText = AppText.button.copyWith(fontSize: 15);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: AppText.family,
    textTheme: textTheme,
    scaffoldBackgroundColor: c.bg,
    extensions: [c],
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        minimumSize: const Size(64, 52),
        shape: const StadiumBorder(),
        textStyle: AppText.button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
        side: BorderSide(color: c.outline),
        textStyle: pillText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.primary, minimumSize: const Size(48, 44), textStyle: pillText),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.primary,
      foregroundColor: c.onPrimary,
      shape: const CircleBorder(),
      elevation: 2,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 76,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(color: states.contains(WidgetState.selected) ? c.ink : c.inkMuted, size: 24),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppText.caption.copyWith(color: c.ink, fontWeight: FontWeight.w600)
            : AppText.caption.copyWith(color: c.inkMuted),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: c.surfaceMuted,
        foregroundColor: c.ink,
        selectedBackgroundColor: c.primary,
        selectedForegroundColor: c.onPrimary,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        textStyle: pillText.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceMuted,
      selectedColor: c.primary,
      checkmarkColor: c.onPrimary,
      labelStyle: AppText.label.copyWith(fontSize: 14, color: c.ink),
      secondaryLabelStyle: AppText.label.copyWith(fontSize: 14, color: c.onPrimary),
      shape: const StadiumBorder(),
      side: BorderSide.none,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: AppText.label.copyWith(color: c.inkMuted),
      hintStyle: AppText.body.copyWith(color: c.inkMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: c.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: c.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: c.primary, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
      backgroundColor: lightMode ? c.ink : c.surfaceMuted,
      contentTextStyle: AppText.label.copyWith(fontSize: 14, color: lightMode ? c.bg : c.ink),
      actionTextColor: lightMode ? const Color(0xFFCDE8D2) : c.primary,
    ),
    dividerTheme: DividerThemeData(color: c.divider, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: c.ink,
      minTileHeight: AppSpace.rowMin, // textColor would override the muted subtitle below
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      // Menu sheets: a medium title over a quieter line that explains it.
      titleTextStyle: AppText.body.copyWith(fontWeight: FontWeight.w500, color: c.ink),
      subtitleTextStyle: AppText.label.copyWith(color: c.inkMuted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.outline,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.hero)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.onPrimary : c.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.primary : c.outline,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.primary, linearTrackColor: c.primarySoft),
  );
}
