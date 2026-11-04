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
