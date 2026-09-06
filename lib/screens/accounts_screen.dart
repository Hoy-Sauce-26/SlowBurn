import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/entity_list.dart';
import '../widgets/fields.dart';

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
                      employerId: existing?.employerId,
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
                        employerMatch: existing?.contribution.employerMatch,
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
