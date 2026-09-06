import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/flag_placement.dart';
import '../widgets/entity_list.dart';
import '../widgets/flag_banner.dart';
import '../widgets/fields.dart';

/// §3.4.4. The employer's own contribution formula.
///
/// A match needs an employer with pay behind it: compensation of zero yields
/// no match, which is the right answer for an account no employer sponsors.
class _MatchEditor extends StatefulWidget {
  final EmployerMatch? match;
  final ValueChanged<EmployerMatch?> onChanged;

  const _MatchEditor({required this.match, required this.onChanged});

  @override
  State<_MatchEditor> createState() => _MatchEditorState();
}

class _MatchEditorState extends State<_MatchEditor> {
  late bool _has = widget.match != null;
  late MatchFormula _formula =
      widget.match?.formula ?? MatchFormula.percentOfContribution;
  late double _rate = widget.match?.matchRate ?? 0.5;
  late double _limit = widget.match?.matchLimitPercentOfSalary ?? 0.06;
  late VestingSchedule? _vesting = widget.match?.vestingSchedule;

  void _emit() => widget.onChanged(_has
      ? EmployerMatch(
          formula: _formula,
          matchRate: _rate,
          matchLimitPercentOfSalary: _limit,
          vestingSchedule: _vesting,
        )
      : null);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Employer matches contributions'),
            value: _has,
            onChanged: (v) => setState(() {
              _has = v;
              _emit();
            }),
          ),
          if (_has) ...[
            FieldRow([
              EnumField<MatchFormula>(
                label: 'Formula',
                values: const [
                  MatchFormula.percentOfContribution,
                  MatchFormula.percentOfSalary,
                ],
                value: _formula == MatchFormula.tiered
                    ? MatchFormula.percentOfContribution
                    : _formula,
                describe: (f) => switch (f) {
                  MatchFormula.percentOfContribution =>
                    'A share of what you put in',
                  MatchFormula.percentOfSalary => 'A share of your salary',
                  MatchFormula.tiered => 'Tiered',
                },
                onChanged: (v) => setState(() {
                  _formula = v;
                  _emit();
                }),
              ),
              PercentField(
                label: 'Match rate',
                helper: '50% for a half match',
                initial: _rate,
                onChanged: (v) {
                  _rate = v;
                  _emit();
                },
              ),
            ]),
            FieldRow([
              PercentField(
                label: 'Up to, of salary',
                helper: '"50% of the first 6%"',
                initial: _limit,
                onChanged: (v) {
                  _limit = v;
                  _emit();
                },
              ),
              YearField(
                label: 'Vests after, years',
                helper: 'Blank vests immediately. Warning only: the engine '
                    'counts the match in full.',
                initial: switch (_vesting) {
                  CliffVesting(:final years) => years,
                  _ => null,
                },
                onChanged: (v) {
                  _vesting = v == null ? null : CliffVesting(v);
                  _emit();
                },
              ),
            ]),
          ],
        ],
      );
}

/// §3.4. Balances and the contributions that feed them.
///
/// `taxTreatment` and `limitFamily` are derived from `kind` on creation rather
/// than asked for. They are stored so a custom account can set them, but no
/// ordinary user should have to know that a 403(b) shares a limit with a
/// 401(k).
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    final canAdd = household.people.isNotEmpty;

    return EntityList(
      title: 'Accounts',
      blurb: 'Balances, contributions and the employer match behind them.',
      addLabel: 'Add an account',
      emptyMessage: canAdd
          ? 'Add what the household has saved.\nA 529 counts toward net worth '
              'and is spent only on education; everything else is reachable.'
          : 'Add a person first: every contribution limit is per individual.',
      banner: const FlagBanner(home: FlagHome.accounts),
      onAdd: canAdd ? () => _edit(context, ref, null) : null,
      children: [
        for (final account in household.accounts)
          EntityTile(
            icon: account.isRestrictedPurpose
                ? Icons.school_outlined
                : Icons.savings_outlined,
            title: account.label,
            subtitle: _describe(account, household),
            trailing: formatMoneyCompact(account.balance),
            onTap: () => _edit(context, ref, account),
            onDelete: () => notifier.removeAccount(account.id),
          ),
      ],
    );
  }

  static String _describe(Account a, Household h) {
    final owner = h.personById(a.personId)?.displayName ?? 'Unassigned';
    final c = a.contribution;
    final contributing = switch (c.mode) {
      ContributionMode.percentOfGross when c.value > 0 =>
        '${(c.value * 100).toStringAsFixed(1)}% of pay',
      ContributionMode.fixedAmount when c.value > 0 =>
        '${formatMoney(Money(c.value.round()))} a year',
      _ => 'no contribution',
    };
    return '$owner · ${humanise(a.kind.wireName)} · $contributing';
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, Account? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    final classes = ref.read(assetClassesProvider);

    var label = existing?.label ?? '';
    var personId = existing?.personId ?? household.people.first.id;
    var kind = existing?.kind ?? AccountKind.traditional401k;
    var balance = existing?.balance ?? Money.zero;
    var basis = existing?.costBasis ?? Money.zero;
    var rothBasis = existing?.rothContributionBasis ?? Money.zero;
    var allocationId = existing?.assetAllocationId ?? classes.first.id;
    var buffer = existing?.targetBalanceMonths;
    var mode = existing?.contribution.mode ?? ContributionMode.percentOfGross;
    var contribution = existing?.contribution.value ?? 0.0;
    var employerId = existing?.employerId;
    var match = existing?.contribution.employerMatch;
    var contributionEnd = existing?.contribution.endYear;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add an account' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) {
          final treatment = defaultTaxTreatment(kind);
          return Column(
            children: [
              LabelledTextField(
                label: 'Label',
                initial: label,
                onChanged: (v) => label = v,
              ),
              const SizedBox(height: 12),
              FieldRow([
                EnumField<AccountKind>(
                  label: 'Kind',
                  helper: 'Sets the tax treatment and the limit that governs it',
                  values: AccountKind.values,
                  value: kind,
                  describe: (k) => humanise(k.wireName),
                  onChanged: (v) => setState(() => kind = v),
                ),
                if (household.people.length > 1)
                  ChoiceField<Person>(
                    label: 'Whose',
                    values: household.people,
                    value: household.personById(personId),
                    describe: (p) => p.displayName,
                    onChanged: (p) => personId = p.id,
                  ),
              ]),
              FieldRow([
                MoneyField(
                  label: 'Balance',
                  initial: balance,
                  onChanged: (v) => balance = v,
                ),
                if (treatment == TaxTreatment.taxable)
                  MoneyField(
                    label: 'Cost basis',
                    helper: 'What has already been taxed',
                    initial: basis,
                    onChanged: (v) => basis = v,
                  )
                else if (treatment == TaxTreatment.roth)
                  MoneyField(
                    label: 'Contributions to date',
                    helper: 'Withdrawable at any age, tax and penalty free',
                    initial: rothBasis,
                    onChanged: (v) => rothBasis = v,
                  ),
              ]),
              FieldRow([
                EnumField<ContributionMode>(
                  label: 'Contribute as',
                  values: ContributionMode.values,
                  value: mode,
                  onChanged: (v) => setState(() => mode = v),
                ),
                if (mode == ContributionMode.percentOfGross)
                  PercentField(
                    label: 'Of pay',
                    initial: contribution,
                    onChanged: (v) => contribution = v,
                  )
                else
                  MoneyField(
                    label: 'Each year',
                    initial: Money(contribution.round()),
                    onChanged: (v) => contribution = v.cents.toDouble(),
                  ),
              ]),
              if (household.employers.isNotEmpty &&
                  defaultLimitFamily(kind) == LimitFamily.electiveDeferral) ...[
                ChoiceField<Employer?>(
                  label: 'Sponsored by',
                  helper: 'Links the plan to the pay behind it, which is what '
                      'bounds the match and the §415(c) ceiling',
                  values: [null, ...household.employers],
                  value: household.employers
                      .where((e) => e.id == employerId)
                      .firstOrNull,
                  describe: (e) => e?.label ?? 'No employer',
                  onChanged: (e) => setState(() => employerId = e?.id),
                ),
                const SizedBox(height: 12),
                if (employerId != null)
                  _MatchEditor(
                    match: match,
                    onChanged: (m) => match = m,
                  ),
              ],
              YearField(
                label: 'Stop contributing after',
                helper: 'Blank stops it at retirement. Coast FIRE sets this '
                    'and trims the waterfall.',
                initial: contributionEnd,
                onChanged: (v) => contributionEnd = v,
              ),
              const SizedBox(height: 12),
              FieldRow([
                ChoiceField<AssetClass>(
                  label: 'Invested in',
                  values: classes,
                  value: classes
                      .where((c) => c.id == allocationId)
                      .firstOrNull,
                  describe: (c) => humanise(c.label.name),
                  onChanged: (c) => allocationId = c.id,
                ),
                if (kind == AccountKind.cashSavings ||
                    kind == AccountKind.cashChecking)
                  YearField(
                    label: 'Emergency fund, months',
                    helper: 'Months of total cost of living to hold',
                    initial: buffer?.round(),
                    onChanged: (v) => buffer = v?.toDouble(),
                  ),
              ]),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    final flags = defaultReducesFlags(kind);
                    notifier.saveAccount(Account(
                      id: existing?.id ?? newId('acct'),
                      personId: personId,
                      label: label.isEmpty ? humanise(kind.wireName) : label,
                      kind: kind,
                      taxTreatment: treatment,
                      limitFamily: defaultLimitFamily(kind),
                      balance: balance,
                      costBasis: treatment == TaxTreatment.taxable
                          ? basis
                          : Money.zero,
                      rothContributionBasis:
                          treatment == TaxTreatment.roth ? rothBasis : Money.zero,
                      rothFirstContributionYear:
                          existing?.rothFirstContributionYear,
                      isRestrictedPurpose: isRestrictedPurpose(treatment),
                      assetAllocationId: allocationId,
                      targetBalanceMonths: buffer,
                      employerId: employerId,
                      contribution: Contribution(
                        mode: mode,
                        value: contribution,
                        contributionBaseStreamIds:
                            mode == ContributionMode.percentOfGross
                                ? household
                                    .streamsFor(personId)
                                    .where((s) => s.kind.isEarned)
                                    .map((s) => s.id)
                                    .toList()
                                : const [],
                        employerMatch: employerId == null ? null : match,
                        endYear: contributionEnd,
                        reducesFederalTaxableIncome: flags.federal,
                        reducesStateTaxableIncome: flags.state,
                        reducesFicaWages: flags.fica,
                      ),
                    ));
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
