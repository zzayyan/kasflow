import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

// Small UI helpers shared by several screens.

/// Groups an amount field as it is typed: "3000000" shows "3.000.000". Keeps a leading "-" and
/// one "," with up to two decimals ("2,5"), drops anything else, and keeps the cursor beside the
/// same digit. Backspace right after a "." deletes the digit before it. parseAmount reads the result.
class AmountInputFormatter extends TextInputFormatter {
  const AmountInputFormatter();

  static final _junk = RegExp(r'[^0-9,]');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var text = newValue.text;
    var cursor = newValue.selection.end.clamp(0, text.length);
    final old = oldValue.text;
    if (text.length == old.length - 1 && newValue.selection.isCollapsed && cursor > 0 && cursor < old.length &&
        old[cursor] == '.' && text == old.replaceRange(cursor, cursor + 1, '')) {
      text = text.replaceRange(cursor - 1, cursor, '');
      cursor--;
    }
    final negative = text.startsWith('-');
    final kept = text.replaceAll(_junk, ''); // digits and commas
    final keptAfter = text.substring(cursor).replaceAll(_junk, '').length;
    final comma = kept.indexOf(',');
    final whole = (comma < 0 ? kept : kept.substring(0, comma)).replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final decimals = comma < 0 ? null : kept.substring(comma + 1).replaceAll(',', '');
    final grouped = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) grouped.write('.');
      grouped.write(whole[i]);
    }
    final formatted = '${negative ? '-' : ''}$grouped'
        '${decimals == null ? '' : ',${decimals.length > 2 ? decimals.substring(0, 2) : decimals}'}';
    // Same number of digits and commas to the right of the cursor as before formatting.
    var at = formatted.length;
    for (var n = 0; at > 0 && n < keptAfter; at--) {
      if (formatted[at - 1] != '.' && formatted[at - 1] != '-') n++;
    }
    while (at > 0 && formatted[at - 1] == '.') {
      at--; // "12|.000", not "12.|000"
    }
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: at));
  }
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// "Tersimpan" with what was saved and a way back (Geser + snackbar artboard).
void showDone(BuildContext context, String title, String detail, {required VoidCallback onUndo}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      // Flutter keeps a bar with an action up until it is dismissed; _UndoCountdown closes this one
      // when its ring runs out.
      persist: true,
      content: Row(
        children: [
          const _UndoCountdown(),
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

const undoTime = Duration(seconds: 4);

/// The check in a "Tersimpan" bar, ringed by the time left to undo; at zero it closes the bar.
/// With a screen reader on, the bar waits for the user instead and shows no ring.
class _UndoCountdown extends StatefulWidget {
  const _UndoCountdown();

  @override
  State<_UndoCountdown> createState() => _UndoCountdownState();
}

class _UndoCountdownState extends State<_UndoCountdown> with SingleTickerProviderStateMixin {
  late final _left = AnimationController(vsync: this, duration: undoTime, value: 1);
  bool _timed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timed || MediaQuery.accessibleNavigationOf(context)) return;
    _timed = true;
    // The ring starts when the bar appears, and the bar closes when the ring ends: one clock for both.
    _left.reverse().whenComplete(() {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
    });
  }

  @override
  void dispose() {
    _left.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox.square(
      dimension: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: c.heroChip, shape: BoxShape.circle),
            child: const SizedBox.expand(),
          ),
          if (_timed)
            ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _left,
                builder: (context, _) => CircularProgressIndicator(
                  value: _left.value,
                  strokeWidth: 2.5,
                  color: c.onHeroChip,
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          Icon(Icons.check, size: 18, color: c.onHeroChip),
        ],
      ),
    );
  }
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

/// A field without a box of its own, inside a [FormRow] or as a big amount: the row draws the frame.
InputDecoration bareField(String hint) => InputDecoration(
  hintText: hint,
  filled: false,
  isCollapsed: true,
  contentPadding: EdgeInsets.zero, // the theme pads fields; these sit inside rows
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
);

/// A list sheet to choose one option from: (value, name, trailing text). Null when dismissed.
Future<T?> chooseOne<T>(BuildContext context, String title, List<(T, String, String?)> options, T? current) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: AppText.heading),
            ),
            for (final (value, name, trailing) in options)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: Text(name, style: AppText.body),
                trailing: trailing == null ? null : Text(trailing, style: AppText.label),
                selected: value == current,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    ),
  );
}

/// A form sheet: title, the [children] 18px apart (scrolling when the keyboard is up), and the
/// [action] kept above the keyboard. Open it with isScrollControlled so it can grow.
class FormSheet extends StatelessWidget {
  const FormSheet({super.key, required this.title, required this.children, required this.action});

  final String title;
  final List<Widget> children;
  final Widget action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 16),
            child: Text(title, style: AppText.title.copyWith(fontSize: 20)),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 18), child],
                ],
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(AppSpace.page, 16, AppSpace.page, 12), child: action),
        ],
      ),
    ),
  );
}

/// The form card (Catat artboard): [FormRow]s on the surface, split by inset dividers.
class FormCard extends StatelessWidget {
  const FormCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.of(context).surface,
    borderRadius: BorderRadius.circular(AppRadius.card),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const Divider(indent: 16, endIndent: 16),
          child,
        ],
      ],
    ),
  );
}

/// One line of a [FormCard]: an icon, a small label, and either a value to tap or a [child] field.
/// With [focusNode] (the child field's), a tap anywhere on the row puts the cursor in the field.
class FormRow extends StatelessWidget {
  const FormRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.child,
    this.focusNode,
    this.trailing,
    this.badge,
    this.onTap,
    this.chevron,
    this.strong = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Widget? child;
  final FocusNode? focusNode;
  final Widget? trailing; // a muted amount, or a control such as a Switch
  final String? badge;
  final VoidCallback? onTap;
  final bool? chevron; // shown by default when the row opens something ([onTap])
  final bool strong; // the dark icon circle, for the row that decides the most (category, target)

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap ?? focusNode?.requestFocus,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: strong ? c.hero : c.surfaceMuted, shape: BoxShape.circle),
                child: Icon(icon, size: 18, color: strong ? c.onHero : c.ink),
              ),
              const SizedBox(width: AppSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The badge sits beside the small label, so a long value keeps the full width.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: AppText.caption.copyWith(color: c.inkMuted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (badge != null)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                            decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(10)),
                            child: Text(badge!, style: AppText.caption.copyWith(fontSize: 11, color: c.primary)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    child ??
                        Text(
                          value ?? '',
                          style: AppText.body.copyWith(fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                DefaultTextStyle.merge(style: AppText.label.copyWith(color: c.inkMuted), child: trailing!),
              ],
              if (chevron ?? onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: c.inkMuted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A rupiah amount typed inside a [FormRow]: "Rp" stays put beside the grouped digits.
class MoneyField extends StatelessWidget {
  const MoneyField({super.key, required this.controller, required this.focusNode, this.autofocus = false, this.signed = false});

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final bool signed; // allows a leading "-", e.g. a credit card's debt

  @override
  Widget build(BuildContext context) {
    final style = AppText.body.copyWith(fontWeight: FontWeight.w500);
    return Row(
      children: [
        Text('Rp ', style: style.copyWith(color: AppColors.of(context).inkMuted)),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            keyboardType: TextInputType.numberWithOptions(signed: signed, decimal: true),
            inputFormatters: const [AmountInputFormatter()],
            style: style,
            decoration: bareField('0'),
          ),
        ),
      ],
    );
  }
}

/// The small muted heading over a group of chips in a form ("Kategori lain", "Label").
class FormLabel extends StatelessWidget {
  const FormLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 10),
    child: Text(text, style: AppText.label.copyWith(color: AppColors.of(context).inkMuted)),
  );
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
    this.average,
    this.averageText,
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
  final int? average; // a dashed line across the columns, labelled [averageText]
  final String? averageText;
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
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.outline)),
                ),
                child: Stack(
                  children: [
                    Row(
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
                    if (average case final a? when a > 0 && scale > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: a * scale - 0.75, // centre the 1.5px line on the value
                        child: IgnorePointer(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (averageText case final t?)
                                ColoredBox(
                                  color: c.surface,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4, bottom: 2),
                                    child: Text(t, style: AppText.caption.copyWith(fontSize: 10, color: c.inkMuted)),
                                  ),
                                ),
                              CustomPaint(size: const Size.fromHeight(1.5), painter: _DashPainter(c.inkMuted)),
                            ],
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

/// A 1.5px dashed rule, 4px dashes with 3px gaps.
class _DashPainter extends CustomPainter {
  _DashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.height;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, y), Offset((x + 4).clamp(0, size.width), y), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
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
