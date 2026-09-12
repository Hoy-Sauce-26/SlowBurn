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
      onAdd: canAdd ? () => editAccount(context, ref, null) : null,
      children: [
        for (final account in household.accounts)
          EntityTile(
            icon: account.isRestrictedPurpose
                ? Icons.school_outlined
                : Icons.savings_outlined,
            title: account.label,
            subtitle: _describe(account, household),
            trailing: formatMoneyCompact(account.balance),
            onTap: () => editAccount(context, ref, account),
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

  Future<void> editAccount(
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
    var allocationId =
        existing?.assetAllocationId ?? defaultClassFor(kind, classes);
    // Suggested rather than left empty, because the plan that assumes you stay
    // in shares through a forty-year retirement is the optimistic one and
    // nobody notices it is being made.
    var retirementAllocationId = existing == null
        ? conservativeClassFor(kind, classes)
        : existing.retirementAllocationId;
    var buffer = existing?.targetBalanceMonths;
    var mode = existing?.contribution.mode ?? ContributionMode.percentOfGross;
    var contribution = existing?.contribution.value ?? 0.0;
    var employerId = existing?.employerId;
    var match = existing?.contribution.employerMatch;
    var contributionEnd = existing?.contribution.endYear;
    // A new account starts dormant, because the ones people forget are the old
    // plans from old jobs. Naming a current employer is what says otherwise.
    var paying = existing != null && existing.contribution.value > 0;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add an account' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) {
          final treatment = defaultTaxTreatment(kind);
          return Column(
            children: [
              FieldRow([
                EnumField<AccountKind>(
                  label: 'Kind',
                  helper: 'Sets the tax treatment and the limit that governs it',
                  values: AccountKind.values,
                  value: kind,
                  describe: accountKindName,
                  onChanged: (v) => setState(() {
                    kind = v;
                    // Only while the user has not chosen one themselves: a
                    // deliberate allocation should survive a change of mind
                    // about the wrapper around it.
                    if (existing?.assetAllocationId == null) {
                      allocationId = defaultClassFor(v, classes);
                      retirementAllocationId = conservativeClassFor(v, classes);
                    }
                  }),
                ),
                if (household.people.length > 1)
                  ChoiceField<Person>(
                    label: 'Whose',
                    values: household.people,
                    value: household.personById(personId),
                    describe: (p) => p.displayName,
                    onChanged: (p) => setState(() => personId = p.id),
                  ),
              ]),
              FieldRow([
                MoneyField(
                  label: 'Balance',
                  initial: balance,
                  onChanged: (v) => balance = v,
                ),
                if (treatment == TaxTreatment.taxable && !kind.isCash)
                  MoneyField(
                    label: 'What you paid for it',
                    helper: 'The total you put in, before any growth. Only the '
                        'growth is taxed when you sell.',
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
              if (household.employers.isNotEmpty && canBeSponsored(kind)) ...[
                SearchableField<Employer>(
                  label: 'Sponsored by',
                  helper: 'The job behind this account.',
                  values: household.employers,
                  value: household.employers
                      .where((e) => e.id == employerId)
                      .firstOrNull,
                  noneLabel: 'An old job, or none',
                  describe: (e) => e.label,
                  // Naming a current job is as good as saying money is still
                  // going in, and taking the job away says the opposite.
                  onChanged: (e) => setState(() {
                    employerId = e?.id;
                    paying = e != null;
                    if (e == null) {
                      match = null;
                      mode = ContributionMode.fixedAmount;
                      contribution = 0;
                      contributionEnd = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
              ],
              // An old employer's plan still grows, and nothing goes into it.
              // Asking how much of a salary goes in would be asking about a
              // salary that is not being paid.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Still paying into it'),
                subtitle: Text(paying
                    ? 'How much goes in each year, and until when.'
                    : 'It carries on growing either way.'),
                value: paying,
                onChanged: (v) => setState(() {
                  paying = v;
                  if (!v) {
                    contribution = 0;
                    contributionEnd = null;
                  }
                }),
              ),
              if (paying) ...[
                const SizedBox(height: 8),
                FieldRow([
                  // A share of pay only means something where there is pay to
                  // take a share of.
                  if (employerId != null)
                    EnumField<ContributionMode>(
                      label: 'Put in',
                      values: ContributionMode.values,
                      value: mode,
                      describe: (m) => m == ContributionMode.percentOfGross
                          ? 'A share of my pay'
                          : 'A fixed amount',
                      onChanged: (v) => setState(() => mode = v),
                    ),
                  if (employerId != null &&
                      mode == ContributionMode.percentOfGross)
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
                if (employerId != null &&
                    defaultLimitFamily(kind) == LimitFamily.electiveDeferral)
                  _MatchEditor(match: match, onChanged: (m) => match = m),
                NumberChoiceField(
                  label: 'Last year you pay in',
                  helper: 'Leave this until you retire unless you mean to stop '
                      'early and let it grow on its own.',
                  first: DateTime.now().year,
                  last: DateTime.now().year + 60,
                  value: contributionEnd,
                  noneLabel: 'Until I retire',
                  onChanged: (v) => contributionEnd = v,
                ),
              ],
              const SizedBox(height: 12),
              FieldRow([
                ChoiceField<AssetClass>(
                  label: 'Invested in',
                  values: classes,
                  value: classes
                      .where((c) => c.id == allocationId)
                      .firstOrNull,
                  describe: assetClassName,
                  onChanged: (c) => allocationId = c.id,
                ),
                if (!kind.isCash)
                  SearchableField<AssetClass>(
                    key: ValueKey(retirementAllocationId),
                    label: 'And once retired',
                    helper: kind.reachableBeforeFiftyNineHalf
                        ? 'This is money you can spend before 59½, so it is '
                            'what an early retirement lives on and what a bad '
                            'first decade would hurt. Most plans hold less in '
                            'shares here by then.'
                        : 'Locked until 59½, so an early retirement never '
                            'touches it and it has years to ride out a bad '
                            'decade. Usually left where it is.',
                    values: classes,
                    value: classes
                        .where((c) => c.id == retirementAllocationId)
                        .firstOrNull,
                    noneLabel: 'Leave it where it is',
                    describe: assetClassName,
                    onChanged: (c) =>
                        setState(() => retirementAllocationId = c?.id),
                  ),
                if (kind.isCash)
                  NumberChoiceField(
                    label: 'Emergency fund',
                    helper: 'Spare money tops this up first, until it holds '
                        'this many months of what you spend. Once it is there, '
                        'nothing more is added and the rest goes to investing.',
                    first: 1,
                    last: 24,
                    value: buffer?.round(),
                    noneLabel: 'Not the account I keep one in',
                    describe: (m) => m == 1 ? '1 month' : '$m months',
                    onChanged: (v) => setState(() => buffer = v?.toDouble()),
                  ),
              ]),
              // Each account's target is measured on its own balance, so two
              // of them asking for six months is a year of cash.
              if (buffer != null &&
                  household.accounts.any((a) =>
                      a.id != existing?.id && a.targetBalanceMonths != null))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Note('Another account is already holding an emergency '
                      'fund. Both will be filled to their own target.'),
                ),
              const SizedBox(height: 12),
              LabelledTextField(
                label: 'Name it (optional)',
                initial: label,
                onChanged: (v) => label = v,
              ),
              const SizedBox(height: 4),
              Note('Left blank, this will be called '
                  '"${defaultAccountLabel(household, personId: personId, employerId: employerId, kind: kind, excluding: existing?.id)}".'),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    final flags = defaultReducesFlags(kind);
                    notifier.saveAccount(Account(
                      id: existing?.id ?? newId('acct'),
                      personId: personId,
                      label: label.trim().isEmpty
                          ? defaultAccountLabel(household,
                              personId: personId,
                              employerId: employerId,
                              kind: kind,
                              excluding: existing?.id)
                          : label.trim(),
                      kind: kind,
                      taxTreatment: treatment,
                      limitFamily: defaultLimitFamily(kind),
                      balance: balance,
                      // Cash is money that has already been taxed, so it opens
                      // at full basis rather than at a zero nobody entered.
                      costBasis: switch (treatment) {
                        TaxTreatment.taxable when kind.isCash => balance,
                        TaxTreatment.taxable => basis,
                        _ => Money.zero,
                      },
                      rothContributionBasis:
                          treatment == TaxTreatment.roth ? rothBasis : Money.zero,
                      rothFirstContributionYear:
                          existing?.rothFirstContributionYear,
                      isRestrictedPurpose: isRestrictedPurpose(treatment),
                      assetAllocationId: allocationId,
                      retirementAllocationId: retirementAllocationId,
                      targetBalanceMonths: buffer,
                      employerId: employerId,
                      contribution: Contribution(
                        // Nothing going in is a fixed nothing, never a share
                        // of a salary that may not exist.
                        mode: paying ? mode : ContributionMode.fixedAmount,
                        value: paying ? contribution : 0,
                        contributionBaseStreamIds:
                            paying && mode == ContributionMode.percentOfGross
                                ? household
                                    .streamsFor(personId)
                                    .where((s) => s.kind.isEarned)
                                    .map((s) => s.id)
                                    .toList()
                                : const [],
                        employerMatch:
                            !paying || employerId == null ? null : match,
                        endYear: paying ? contributionEnd : null,
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

/// Whether a job can sponsor this kind of account, which is what decides
/// whether asking about an employer is a sensible question.
bool canBeSponsored(AccountKind kind) =>
    defaultLimitFamily(kind) == LimitFamily.electiveDeferral ||
    kind == AccountKind.hsa ||
    kind == AccountKind.simpleIra ||
    kind == AccountKind.sepIra;

/// "Acme 401(k)", or "Alex's Roth IRA" where no job is behind it.
String defaultAccountLabel(
  Household household, {
  required Id personId,
  required Id? employerId,
  required AccountKind kind,
  Id? excluding,
}) {
  final employer =
      household.employers.where((e) => e.id == employerId).firstOrNull?.label;
  final person = household.personById(personId)?.displayName;
  final what = accountKindName(kind);

  final base = employer != null
      ? '$employer $what'
      : person == null
          ? what
          : "$person's $what";

  return uniqueLabel(
      base,
      household.accounts.where((a) => a.id != excluding).map((a) => a.label));
}

/// What an account of this kind is usually held in, so nobody has to answer a
/// question about their current account that has one sensible answer.
Id defaultClassFor(AccountKind kind, List<AssetClass> classes) {
  // In order of preference, so a plan whose stored classes are missing one
  // still lands on something cash-like rather than on shares.
  final wanted = switch (kind) {
    AccountKind.cashSavings => [AssetClassLabel.savings, AssetClassLabel.cash],
    AccountKind.cashChecking => [AssetClassLabel.cash, AssetClassLabel.savings],
    _ => [AssetClassLabel.usStocks],
  };
  for (final label in wanted) {
    final match = classes.where((c) => c.label == label).firstOrNull;
    if (match != null) return match.id;
  }
  return classes.first.id;
}

/// What to hold once the drawing down starts: bonds where there were shares,
/// and cash left where it is.
///
/// A suggestion rather than a rule. Somebody who means to stay in shares can
/// say so, and will then be reading a number that knows they did.
Id? conservativeClassFor(AccountKind kind, List<AssetClass> classes) {
  // Only the money the first fifteen years are spent from. A 401(k) nobody
  // can touch until 59½ has fifteen more years to ride out a bad decade, and
  // derisking it at 45 costs real growth for no protection.
  if (kind.isCash || !kind.reachableBeforeFiftyNineHalf) return null;
  return classes.where((c) => c.label == AssetClassLabel.bonds).firstOrNull?.id;
}
