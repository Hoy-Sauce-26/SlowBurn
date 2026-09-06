import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// The inputs every editor is built from.
///
/// Money is entered in dollars and stored in cents (invariant 10), and rates
/// are entered as percentages and stored as decimals (invariant 9). Both
/// conversions live here so no screen has to remember which side it is on.

final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
final _compact = NumberFormat.compactCurrency(symbol: r'$', decimalDigits: 1);

String formatMoney(Money m) => _money.format(m.dollars);
String formatMoneyCompact(Money m) => _compact.format(m.dollars);
String formatPercent(Rate r) =>
    '${(r * 100).toStringAsFixed(r * 100 % 1 == 0 ? 0 : 2)}%';

class MoneyField extends StatelessWidget {
  final String label;
  final String? helper;
  final Money? initial;
  final ValueChanged<Money> onChanged;
  final bool allowNegative;

  const MoneyField({
    super.key,
    required this.label,
    required this.onChanged,
    this.initial,
    this.helper,
    this.allowNegative = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: initial == null || initial!.isZero
          ? ''
          : initial!.dollars.toStringAsFixed(2),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        prefixText: r'$ ',
        border: const OutlineInputBorder(),
      ),
      keyboardType:
          TextInputType.numberWithOptions(decimal: true, signed: allowNegative),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
            RegExp(allowNegative ? r'^-?\d*\.?\d{0,2}' : r'^\d*\.?\d{0,2}')),
      ],
      onChanged: (text) {
        final value = double.tryParse(text);
        // An empty field means zero rather than "unchanged": a user clearing a
        // number is saying it is not there.
        onChanged(value == null ? Money.zero : Money.dollars(value));
      },
    );
  }
}

class PercentField extends StatelessWidget {
  final String label;
  final String? helper;
  final Rate? initial;
  final ValueChanged<Rate> onChanged;

  const PercentField({
    super.key,
    required this.label,
    required this.onChanged,
    this.initial,
    this.helper,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      // Two things go wrong with the obvious `(rate * 100).toString()`. A
      // round rate renders a trailing zero, 0.04 becoming "4.0", and an
      // unrepresentable one renders its error: 0.0145 becomes
      // "1.4500000000000002". Neither is a field anyone wants to edit.
      initialValue:
          initial == null || initial == 0 ? '' : _percentText(initial! * 100),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        suffixText: '%',
        border: const OutlineInputBorder(),
      ),
      keyboardType: const TextInputType.numberWithOptions(
          decimal: true, signed: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d{0,3}')),
      ],
      onChanged: (text) => onChanged((double.tryParse(text) ?? 0) / 100),
    );
  }
}

String _percentText(double value) {
  final fixed = value.toStringAsFixed(3);
  return fixed.contains('.')
      ? fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : fixed;
}

class LabelledTextField extends StatelessWidget {
  final String label;
  final String? initial;
  final ValueChanged<String> onChanged;

  const LabelledTextField({
    super.key,
    required this.label,
    required this.onChanged,
    this.initial,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: initial,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      );
}

/// A whole year, nullable. Null carries meaning throughout the domain: a null
/// `startYear` means already running, a null `endYear` means indefinitely.
class YearField extends StatelessWidget {
  final String label;
  final String? helper;
  final int? initial;
  final ValueChanged<int?> onChanged;

  const YearField({
    super.key,
    required this.label,
    required this.onChanged,
    this.initial,
    this.helper,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: initial?.toString(),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (text) => onChanged(int.tryParse(text)),
      );
}

/// A dropdown you can type into on a desktop and only tap on a phone.
///
/// `DropdownMenu` filters as you type, so "199" jumps to 1990 and "New" to
/// New York. [requestFocusOnTap] is what keeps that from being a nuisance on a
/// touch device: false there means tapping opens the list without raising the
/// keyboard, while a hardware keyboard still filters.
class SearchableField<T> extends StatefulWidget {
  final String label;
  final String? helper;
  final List<T> values;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String Function(T) describe;

  /// The entry meaning "no answer", where one is allowed.
  final String? noneLabel;

  const SearchableField({
    super.key,
    required this.label,
    required this.values,
    required this.value,
    required this.onChanged,
    required this.describe,
    this.helper,
    this.noneLabel,
  });

  @override
  State<SearchableField<T>> createState() => _SearchableFieldState<T>();
}

class _SearchableFieldState<T> extends State<SearchableField<T>> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = _shownFor(widget.value);
    _focus.addListener(_settle);
  }

  @override
  void didUpdateWidget(SearchableField<T> old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && !_focus.hasFocus) {
      _controller.text = _shownFor(widget.value);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_settle);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Typing narrows the list, so a half-typed word is left in the box when
  /// attention moves on. Put back whatever is actually chosen.
  void _settle() {
    if (_focus.hasFocus) {
      // Arriving with an answer already in the box, the next letter typed
      // should start a new search rather than land after "Colorado".
      _controller.selection = TextSelection(
          baseOffset: 0, extentOffset: _controller.text.length);
      return;
    }
    final settled = _shownFor(widget.value);
    if (_controller.text != settled) _controller.text = settled;
  }

  String _shownFor(T? value) =>
      value == null ? widget.noneLabel ?? '' : widget.describe(value);

  List<String> get _entryLabels => [
        if (widget.noneLabel != null) widget.noneLabel!,
        for (final v in widget.values) widget.describe(v),
      ];

  @override
  Widget build(BuildContext context) {
    final entries = <DropdownMenuEntry<T?>>[
      if (widget.noneLabel != null)
        DropdownMenuEntry<T?>(value: null, label: widget.noneLabel!),
      for (final v in widget.values)
        DropdownMenuEntry<T?>(value: v, label: widget.describe(v)),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => DropdownMenu<T?>(
        controller: _controller,
        focusNode: _focus,
        initialSelection: widget.value,
        width: constraints.maxWidth,
        label: Text(widget.label),
        helperText: widget.helper,
        enableFilter: true,
        enableSearch: true,
        requestFocusOnTap: _typingIsWelcome(context),
        menuHeight: 360,
        inputFormatters: [_KeepsToTheList(() => _entryLabels)],
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          helperMaxLines: 3,
        ),
        dropdownMenuEntries: entries,
        onSelected: (v) {
          if (v == null && widget.noneLabel == null) return;
          widget.onChanged(v);
        },
      ),
    );
  }

  /// A physical keyboard is worth focusing for; a soft one covers the list you
  /// are trying to read.
  static bool _typingIsWelcome(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
        return false;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return true;
    }
  }
}

/// Refuses any keystroke that would leave the box reading something no entry
/// matches. Typing "New" in a list of states narrows it to four; typing "Newq"
/// does nothing at all, so the box can never end up holding an answer that is
/// not on the list.
class _KeepsToTheList extends TextInputFormatter {
  _KeepsToTheList(this.labels);
  final List<String> Function() labels;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue before, TextEditingValue after) {
    if (after.text.isEmpty) return after;
    final typed = after.text.toLowerCase();
    final matches = labels().any((l) => l.toLowerCase().contains(typed));
    return matches ? after : before;
  }
}

/// A dropdown over a range of numbers. A birth year is picked, not typed:
/// there is a right answer, the range is known, and a typo in a year moves
/// every age gate in the plan.
class NumberChoiceField extends StatelessWidget {
  final String label;
  final String? helper;
  final int first;
  final int last;
  final int? value;
  final ValueChanged<int?> onChanged;
  final String Function(int)? describe;
  final bool descending;

  /// The entry that means "no answer". Without one, a dropdown is a trap: a
  /// value picked by accident can never be taken back.
  final String? noneLabel;

  const NumberChoiceField({
    super.key,
    required this.label,
    required this.first,
    required this.last,
    required this.value,
    required this.onChanged,
    this.helper,
    this.describe,
    this.descending = false,
    this.noneLabel,
  });

  @override
  Widget build(BuildContext context) {
    final values = [for (var v = first; v <= last; v++) v];
    if (descending) values.sort((a, b) => b.compareTo(a));
    return SearchableField<int>(
      label: label,
      helper: helper,
      values: values,
      value: value,
      noneLabel: noneLabel,
      describe: (v) => describe?.call(v) ?? '$v',
      onChanged: onChanged,
    );
  }
}

/// The fifty states and the District of Columbia, which §7.6 says ship at
/// launch. Territories are excluded: Puerto Rico in particular runs a code that
/// is a separate system rather than a state-style layer on the federal one.
const usStateCodes = <String, String>{
  'AL': 'Alabama', 'AK': 'Alaska', 'AZ': 'Arizona', 'AR': 'Arkansas',
  'CA': 'California', 'CO': 'Colorado', 'CT': 'Connecticut', 'DE': 'Delaware',
  'DC': 'District of Columbia', 'FL': 'Florida', 'GA': 'Georgia',
  'HI': 'Hawaii', 'ID': 'Idaho', 'IL': 'Illinois', 'IN': 'Indiana',
  'IA': 'Iowa', 'KS': 'Kansas', 'KY': 'Kentucky', 'LA': 'Louisiana',
  'ME': 'Maine', 'MD': 'Maryland', 'MA': 'Massachusetts', 'MI': 'Michigan',
  'MN': 'Minnesota', 'MS': 'Mississippi', 'MO': 'Missouri', 'MT': 'Montana',
  'NE': 'Nebraska', 'NV': 'Nevada', 'NH': 'New Hampshire',
  'NJ': 'New Jersey', 'NM': 'New Mexico', 'NY': 'New York',
  'NC': 'North Carolina', 'ND': 'North Dakota', 'OH': 'Ohio',
  'OK': 'Oklahoma', 'OR': 'Oregon', 'PA': 'Pennsylvania',
  'RI': 'Rhode Island', 'SC': 'South Carolina', 'SD': 'South Dakota',
  'TN': 'Tennessee', 'TX': 'Texas', 'UT': 'Utah', 'VT': 'Vermont',
  'VA': 'Virginia', 'WA': 'Washington', 'WV': 'West Virginia',
  'WI': 'Wisconsin', 'WY': 'Wyoming',
};

const monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

class EnumField<T extends Enum> extends StatelessWidget {
  final String label;
  final String? helper;
  final List<T> values;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T)? describe;

  const EnumField({
    super.key,
    required this.label,
    required this.values,
    required this.value,
    required this.onChanged,
    this.helper,
    this.describe,
  });

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: value,
        // Without this the selected label sizes the field, and
        // "Qualifying surviving spouse" overflows a column that fits
        // "Single" comfortably.
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final v in values)
            DropdownMenuItem(
              value: v,
              child: Text(
                describe?.call(v) ?? humanise(v.name),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => v == null ? null : onChanged(v),
      );
}

/// A dropdown over anything, for the cases that are not an enum: which person
/// owns a stream, which account proceeds land in, which category an expense
/// belongs to.
class ChoiceField<T> extends StatelessWidget {
  final String label;
  final String? helper;
  final List<T> values;
  final T? value;
  final ValueChanged<T> onChanged;
  final String Function(T) describe;

  const ChoiceField({
    super.key,
    required this.label,
    required this.values,
    required this.value,
    required this.onChanged,
    required this.describe,
    this.helper,
  });

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: value,
        // Without this the selected label sizes the field, and
        // "Qualifying surviving spouse" overflows a column that fits
        // "Single" comfortably.
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final v in values)
            DropdownMenuItem(
              value: v,
              child: Text(describe(v), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => v == null ? null : onChanged(v),
      );
}

/// `marriedFilingJointly` reads as "Married filing jointly". Engine vocabulary
/// is precise and camelCase; a form label should be neither.
String humanise(String camel) {
  final spaced = camel.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}');
  return spaced[0].toUpperCase() + spaced.substring(1).toLowerCase();
}

/// A row of fields that wraps rather than overflows, so the same editor works
/// in a phone column and a desktop pane.
class FieldRow extends StatelessWidget {
  final List<Widget> children;
  const FieldRow(this.children, {super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 420;
          if (narrow) {
            return Column(
              children: [
                for (final child in children)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: child,
                  ),
              ],
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: children[i]),
                ],
              ],
            ),
          );
        },
      );
}
