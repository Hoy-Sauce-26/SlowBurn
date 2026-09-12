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

/// For an estimate, where cents would claim a precision it does not have.
String formatMoneyWhole(Money m) => _whole.format(m.dollars);
final _whole = NumberFormat.currency(symbol: r'$', decimalDigits: 0);

String formatPercent(Rate r) =>
    '${(r * 100).toStringAsFixed(r * 100 % 1 == 0 ? 0 : 2)}%';

/// A text field that selects what is in it when you click into it, so typing
/// replaces the value rather than landing somewhere inside it.
///
/// Every typed field in the app goes through this. They are all the same
/// shape, and the alternative is four widgets that each forget the behaviour
/// separately. `initialValue` is not enough on its own: selecting text needs a
/// controller, and a controller needs somebody to keep it in step with a value
/// the screen changes underneath it.
class _TypedField extends StatefulWidget {
  final String label;
  final String? helper;
  final String text;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> formatters;
  final String? prefix;
  final String? suffix;

  const _TypedField({
    required this.label,
    required this.text,
    required this.onChanged,
    this.helper,
    this.keyboardType,
    this.formatters = const [],
    this.prefix,
    this.suffix,
  });

  @override
  State<_TypedField> createState() => _TypedFieldState();
}

class _TypedFieldState extends State<_TypedField> {
  late final _controller = TextEditingController(text: widget.text);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_selectAll);
  }

  @override
  void didUpdateWidget(_TypedField old) {
    super.didUpdateWidget(old);
    // A value the screen changed while somebody was typing into it would fight
    // them, so this only follows along when the field is not in use.
    if (widget.text != old.text &&
        !_focus.hasFocus &&
        _controller.text != widget.text) {
      _controller.text = widget.text;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_selectAll);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _selectAll() {
    if (!_focus.hasFocus) return;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: _controller,
    focusNode: _focus,
    decoration: InputDecoration(
      labelText: widget.label,
      helperText: widget.helper,
      helperMaxLines: 6,
      prefixText: widget.prefix,
      suffixText: widget.suffix,
      border: const OutlineInputBorder(),
    ),
    keyboardType: widget.keyboardType,
    inputFormatters: widget.formatters,
    onChanged: widget.onChanged,
  );
}

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
  Widget build(BuildContext context) => _TypedField(
    label: label,
    helper: helper,
    prefix: r'$ ',
    text: initial == null || initial!.isZero
        ? ''
        : initial!.dollars.toStringAsFixed(2),
    keyboardType: TextInputType.numberWithOptions(
      decimal: true,
      signed: allowNegative,
    ),
    formatters: [
      FilteringTextInputFormatter.allow(
        RegExp(allowNegative ? r'^-?\d*\.?\d{0,2}' : r'^\d*\.?\d{0,2}'),
      ),
    ],
    onChanged: (text) {
      final value = double.tryParse(text);
      // An empty field means zero rather than "unchanged": a user clearing
      // a number is saying it is not there.
      onChanged(value == null ? Money.zero : Money.dollars(value));
    },
  );
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
  Widget build(BuildContext context) => _TypedField(
    label: label,
    helper: helper,
    suffix: '%',
    // Two things go wrong with the obvious `(rate * 100).toString()`. A
    // round rate renders a trailing zero, 0.04 becoming "4.0", and an
    // unrepresentable one renders its error: 0.0145 becomes
    // "1.4500000000000002". Neither is a field anyone wants to edit.
    // Zero is an answer, and a rate that says "keeps pace with inflation
    // and no more" must not read as a field nobody filled in. Only null
    // renders empty.
    text: initial == null ? '' : _percentText(initial! * 100),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    formatters: [
      FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d{0,3}')),
    ],
    onChanged: (text) => onChanged((double.tryParse(text) ?? 0) / 100),
  );
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
  Widget build(BuildContext context) =>
      _TypedField(label: label, text: initial ?? '', onChanged: onChanged);
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
  Widget build(BuildContext context) => _TypedField(
    label: label,
    helper: helper,
    text: initial?.toString() ?? '',
    keyboardType: TextInputType.number,
    formatters: [FilteringTextInputFormatter.digitsOnly],
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
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
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
          helperMaxLines: 6,
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
    TextEditingValue before,
    TextEditingValue after,
  ) {
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
  'AL': 'Alabama',
  'AK': 'Alaska',
  'AZ': 'Arizona',
  'AR': 'Arkansas',
  'CA': 'California',
  'CO': 'Colorado',
  'CT': 'Connecticut',
  'DE': 'Delaware',
  'DC': 'District of Columbia',
  'FL': 'Florida',
  'GA': 'Georgia',
  'HI': 'Hawaii',
  'ID': 'Idaho',
  'IL': 'Illinois',
  'IN': 'Indiana',
  'IA': 'Iowa',
  'KS': 'Kansas',
  'KY': 'Kentucky',
  'LA': 'Louisiana',
  'ME': 'Maine',
  'MD': 'Maryland',
  'MA': 'Massachusetts',
  'MI': 'Michigan',
  'MN': 'Minnesota',
  'MS': 'Mississippi',
  'MO': 'Missouri',
  'MT': 'Montana',
  'NE': 'Nebraska',
  'NV': 'Nevada',
  'NH': 'New Hampshire',
  'NJ': 'New Jersey',
  'NM': 'New Mexico',
  'NY': 'New York',
  'NC': 'North Carolina',
  'ND': 'North Dakota',
  'OH': 'Ohio',
  'OK': 'Oklahoma',
  'OR': 'Oregon',
  'PA': 'Pennsylvania',
  'RI': 'Rhode Island',
  'SC': 'South Carolina',
  'SD': 'South Dakota',
  'TN': 'Tennessee',
  'TX': 'Texas',
  'UT': 'Utah',
  'VT': 'Vermont',
  'VA': 'Virginia',
  'WA': 'Washington',
  'WV': 'West Virginia',
  'WI': 'Wisconsin',
  'WY': 'Wyoming',
};

const monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// A dropdown over an enum. Filtering is the reason this goes through
/// [SearchableField] rather than a plain `DropdownButtonFormField`: fifteen
/// account kinds is a list worth typing at.
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
  Widget build(BuildContext context) => SearchableField<T>(
    label: label,
    helper: helper,
    values: values,
    value: value,
    describe: (v) => describe?.call(v) ?? humanise(v.name),
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
  Widget build(BuildContext context) => SearchableField<T>(
    label: label,
    helper: helper,
    values: values,
    value: value,
    describe: describe,
    onChanged: (v) => v == null ? null : onChanged(v),
  );
}

/// `marriedFilingJointly` reads as "Married filing jointly". Engine vocabulary
/// is precise and camelCase; a form label should be neither.
/// What people call these, which `humanise` cannot get to from an enum name:
/// it would turn `traditional401k` into "Traditional401k" and `traditionalTsp`
/// into "Traditional tsp".
String accountKindName(AccountKind kind) => switch (kind) {
  AccountKind.traditional401k => '401(k)',
  AccountKind.roth401k => 'Roth 401(k)',
  AccountKind.traditional403b => '403(b)',
  AccountKind.roth403b => 'Roth 403(b)',
  AccountKind.traditionalTsp => 'TSP',
  AccountKind.rothTsp => 'Roth TSP',
  AccountKind.traditionalIra => 'Traditional IRA',
  AccountKind.rothIra => 'Roth IRA',
  AccountKind.hsa => 'HSA',
  AccountKind.sepIra => 'SEP IRA',
  AccountKind.simpleIra => 'SIMPLE IRA',
  AccountKind.education529 => '529',
  AccountKind.taxableBrokerage => 'Brokerage',
  AccountKind.cashSavings => 'Savings',
  AccountKind.cashChecking => 'Checking',
};

/// A name nobody typed, kept distinct from the ones already in use. Two old
/// 401(k)s and two credit cards are both ordinary, and "Credit card" twice
/// helps nobody.
String uniqueLabel(String base, Iterable<String> taken) {
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var n = 2; ; n++) {
    if (!used.contains('$base $n')) return '$base $n';
  }
}

/// What a class is called on screen. `humanise` gets "Us stocks" from
/// `usStocks`, which nobody would write.
String assetClassName(AssetClass c) => switch (c.label) {
  AssetClassLabel.usStocks => 'US stocks',
  AssetClassLabel.intlStocks => 'International stocks',
  AssetClassLabel.bonds => 'Bonds',
  AssetClassLabel.reit => 'Property funds',
  AssetClassLabel.savings => 'Savings interest',
  AssetClassLabel.cash => 'Cash, earning nothing',
  AssetClassLabel.crypto => 'Crypto',
};

/// What a spending category is called on screen. Two of them need saying
/// carefully, since the difference between a roof and the bills that come with
/// one is the difference between a plan that houses somebody and one that only
/// thinks it does.
String metaCategoryName(MetaCategory c) => switch (c) {
  MetaCategory.housing => 'Rent or lodging',
  MetaCategory.housingSupport => 'Housing costs',
  MetaCategory.transportation => 'Transport',
  MetaCategory.food => 'Food',
  MetaCategory.health => 'Health',
  MetaCategory.childcare => 'Childcare',
  MetaCategory.discretionary => 'Discretionary',
  MetaCategory.insurance => 'Insurance',
  MetaCategory.education => 'Education',
  MetaCategory.misc => 'Everything else',
};

/// The line under it, where one is needed to tell two apart.
String? metaCategoryBlurb(MetaCategory c) => switch (c) {
  MetaCategory.housing =>
    'What you pay to have somewhere to live. This is the one that answers '
        'whether you are housed.',
  MetaCategory.housingSupport =>
    'utilities, internet, property tax outside escrow, HOA dues, contents '
        'insurance, upkeep, etc.',
  MetaCategory.health =>
    'Health spending is what an HSA can be spent on '
        'without tax, so it is worth its own line.',
  MetaCategory.education =>
    'Education spending is what a 529 pays for, and draws one down as it '
        'goes.',
  _ => null,
};

String humanise(String camel) {
  final spaced = camel.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (m) => '${m[1]} ${m[2]}',
  );
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
              Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
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

/// A short aside, for the things a form label has no room to say.
class Note extends StatelessWidget {
  final String text;

  const Note(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
