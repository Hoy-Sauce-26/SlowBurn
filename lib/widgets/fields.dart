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
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (text) => onChanged(int.tryParse(text)),
      );
}

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
