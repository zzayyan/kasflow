import 'package:flutter/material.dart';

import 'theme.dart';

// Small UI helpers shared by several screens.

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// "Tersimpan" with what was saved and a way back (Geser + snackbar artboard).
void showDone(BuildContext context, String title, String detail, {required VoidCallback onUndo}) {
  final c = AppColors.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: c.heroChip, shape: BoxShape.circle),
            child: Icon(Icons.check, size: 18, color: c.onHeroChip),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppText.bodyStrong.copyWith(fontSize: 14)),
                Text(detail, style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
      action: SnackBarAction(label: 'Batalkan', onPressed: onUndo),
    ),
  );
}

/// A pushed page's header, as drawn: round back button, centered title, optional [action].
PreferredSizeWidget pageAppBar(BuildContext context, String title, {Widget? action}) {
  final c = AppColors.of(context);
  return AppBar(
    leadingWidth: 66,
    leading: Padding(
      padding: const EdgeInsets.only(left: AppSpace.page),
      child: Center(
        child: IconButton(
          tooltip: 'Kembali',
          onPressed: () => Navigator.maybePop(context),
          style: IconButton.styleFrom(backgroundColor: c.surface, fixedSize: const Size.square(46)),
          icon: Icon(Icons.chevron_left, color: c.ink),
        ),
      ),
    ),
    centerTitle: true,
    title: Text(title, style: AppText.title.copyWith(fontSize: 20)),
    actions: [
      if (action != null) Padding(padding: const EdgeInsets.only(right: AppSpace.page), child: Center(child: action)),
    ],
  );
}

/// The dark round + that adds an item, in a page header.
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(backgroundColor: c.primary, fixedSize: const Size.square(46)),
      icon: Icon(Icons.add, color: c.onPrimary),
    );
  }
}

/// Icons a category can wear, in the picker's order; `categories.icon` holds the key.
const categoryIcons = <String, (IconData, String)>{
  'utensils': (Icons.restaurant_outlined, 'Makan'),
  'coffee': (Icons.local_cafe_outlined, 'Kopi'),
  'basket': (Icons.shopping_basket_outlined, 'Belanja harian'),
  'bike': (Icons.two_wheeler, 'Motor'),
  'car': (Icons.directions_car_outlined, 'Mobil'),
  'zap': (Icons.bolt_outlined, 'Listrik'),
  'home': (Icons.home_outlined, 'Rumah'),
  'heart': (Icons.monitor_heart_outlined, 'Kesehatan'),
  'film': (Icons.movie_outlined, 'Hiburan'),
  'bag': (Icons.shopping_bag_outlined, 'Belanja'),
  'book': (Icons.menu_book_outlined, 'Pendidikan'),
  'gift': (Icons.card_giftcard_outlined, 'Hadiah'),
  'wallet': (Icons.account_balance_wallet_outlined, 'Dompet'),
  'plane': (Icons.flight_outlined, 'Liburan'),
  'phone': (Icons.smartphone_outlined, 'Pulsa'),
  'shirt': (Icons.checkroom_outlined, 'Pakaian'),
  'dumbbell': (Icons.fitness_center_outlined, 'Olahraga'),
  'more': (Icons.more_horiz, 'Lainnya'),
};

// For categories without a chosen icon: the default ones (supabase/migrations/0001_init.sql)
// and renamed or new ones whose name has the word. First match wins.
const _iconByName = [
  ('makan', 'utensils'),
  ('kopi', 'coffee'),
  ('belanja online', 'bag'),
  ('belanja', 'basket'),
  ('transport', 'bike'),
  ('tagihan', 'zap'),
  ('tinggal', 'home'),
  ('kesehatan', 'heart'),
  ('hiburan', 'film'),
  ('pendidikan', 'book'),
  ('sedekah', 'gift'),
  ('hadiah', 'gift'),
  ('gaji', 'wallet'),
  ('liburan', 'plane'),
  ('pulsa', 'phone'),
  ('lainnya', 'more'),
];

/// The icon key a category shows: its own, else one guessed from its name.
String? categoryIconKey(String? name, [String? icon]) {
  if (categoryIcons.containsKey(icon)) return icon;
  final n = (name ?? '').toLowerCase();
  for (final (word, key) in _iconByName) {
    if (n.contains(word)) return key;
  }
  return null;
}

IconData categoryIcon(String? name, String type, [String? icon]) {
  if (type == 'transfer') return Icons.swap_horiz;
  final key = categoryIconKey(name, icon);
  if (key != null) return categoryIcons[key]!.$1;
  return type == 'income' ? Icons.south_west : Icons.receipt_outlined;
}

/// One choice out of a few, as one pill track (Keluar / Masuk / Transfer).
class PillSwitch<T> extends StatelessWidget {
  const PillSwitch({super.key, required this.options, required this.value, required this.onChanged, this.fontSize = 15});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: c.surfaceMuted, borderRadius: BorderRadius.circular(26)),
      child: Row(
        children: [
          for (final (option, label) in options)
            Expanded(
              child: Semantics(
                selected: value == option,
                child: TextButton(
                  onPressed: () => onChanged(option),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: const StadiumBorder(),
                    backgroundColor: value == option ? c.primary : Colors.transparent,
                    foregroundColor: value == option ? c.onPrimary : c.ink,
                    textStyle: AppText.button.copyWith(
                      fontSize: fontSize,
                      fontWeight: value == option ? FontWeight.w500 : FontWeight.w400,
                    ),
                  ),
                  child: Text(label),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Columns of one series on one baseline (Laporan's trend, Beranda's week). The selected column
/// is dark and carries its value; the others are muted; tapping one selects it. [ticks] adds an
/// axis on the right; without it the tallest column fills the height.
class SelectableBars extends StatelessWidget {
  const SelectableBars({
    super.key,
    required this.values,
    required this.labels,
    required this.readouts,
    required this.selected,
    required this.onSelect,
    required this.valueText,
    this.ticks,
    this.tickText,
    this.height = 150,
  });

  final List<int> values;
  final List<String> labels; // under each column
  final List<String> readouts; // what a screen reader says for each column
  final int selected;
  final ValueChanged<int> onSelect;
  final String Function(int value) valueText; // the chip above the selected column
  final List<int>? ticks;
  final String Function(int tick)? tickText;
  final double height;

  static const _axisWidth = 30.0;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final top = ticks?.last ?? values.fold<int>(0, (m, v) => v > m ? v : m);
    final scale = top == 0 ? 0.0 : height / top;
    final last = values.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The selected value sits in a band above the plot, over its column, so it never covers a
        // taller neighbour. Align keeps it inside the band at the edges.
        Padding(
          padding: EdgeInsets.only(right: ticks == null ? 0 : _axisWidth),
          child: SizedBox(
            height: 28,
            child: Align(
              alignment: Alignment(values.length < 2 ? 0 : -1 + 2 * selected / last, -1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  valueText(values[selected]),
                  maxLines: 1,
                  softWrap: false,
                  style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w600, color: c.onPrimary),
                ),
              ),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                height: height,
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.outline))),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < values.length; i++)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: i == selected,
                          label: readouts[i],
                          excludeSemantics: true,
                          onTap: () => onSelect(i), // excludeSemantics drops the InkWell's own action
                          child: InkWell(
                            onTap: () => onSelect(i),
                            child: _Column(
                              plot: height,
                              height: values[i] * scale,
                              color: i == selected ? c.primary : c.chartMuted,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (ticks case final ticks?) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: _axisWidth - 8,
                height: height,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final t in ticks.reversed)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          tickText?.call(t) ?? '$t',
                          style: AppText.caption.copyWith(fontSize: 10, color: c.inkMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: AppText.caption.copyWith(
                    color: i == selected ? c.ink : c.inkMuted,
                    fontWeight: i == selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
            if (ticks != null) const SizedBox(width: _axisWidth),
          ],
        ),
      ],
    );
  }
}

/// One column: at most 24px wide, 4px rounded at the top, square at the baseline.
class _Column extends StatelessWidget {
  const _Column({required this.plot, required this.height, required this.color});

  final double plot;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: plot,
    child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: 24,
        height: height < 2 ? 2 : height, // an empty day still shows where it sits
        decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
      ),
    ),
  );
}

/// Chart and status colors. Bars, need levels and the "good" delta come from the design
/// tokens in theme.dart (AppColors), so they follow light and dark mode. Need-level colors are
/// close in hue, so every colored part is listed with its name and amount beside it.
class VizColors {
  const VizColors._(this.bar, this.needLevels, this.good);

  final Color bar; // single-series bars and the "on track" meter
  final Map<String?, Color> needLevels; // must / need / want; tan is reserved for "want"
  final Color good; // delta text when the change is good

  static const warning = Color(0xFFFAB219); // status palette: fixed, never themed
  static const critical = Color(0xFFC2552F); // rust from the design: late bills, over budget
  static const success = Color(0xFF0CA30C); // status "good": a reached goal

  static VizColors of(BuildContext context) {
    final c = AppColors.of(context);
    return VizColors._(c.primary, c.needLevels, c.income);
  }
}

const needLevelLabels = {'must': 'Wajib', 'need': 'Butuh', 'want': 'Ingin', null: 'Belum diberi level'};

String utcIso(DateTime local) => local.toUtc().toIso8601String();

String percentOf(int part, int whole) => whole == 0 ? '0%' : '${(part * 100 / whole).round()}%';
