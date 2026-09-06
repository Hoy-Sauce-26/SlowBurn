import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/entity_list.dart';
import '../widgets/fields.dart';

/// §3.5 and §3.6. Debts and the things they are secured against.
///
/// The two share a screen because a mortgage and the house behind it are one
/// decision, and invariant 5 requires them to agree about each other.
class DebtsScreen extends ConsumerWidget {
  const DebtsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    return EntityList(
      title: 'Debts and assets',
      blurb: 'Mortgages, loans, the house and the car.',
      addLabel: 'Add a debt',
      emptyMessage:
          'Add what the household owes and owns.\nDebt service reaches the plan '
          'on its own, so it needs no spending line, and escrow keeps being '
          'paid after a mortgage is gone.',
      onAdd: () => _editLiability(context, ref, null),
      children: [
        for (final debt in household.liabilities)
          EntityTile(
            icon: Icons.credit_card_outlined,
            title: debt.label,
            subtitle: '${humanise(debt.kind.name)} · '
                '${formatPercent(debt.interestRate)} · '
                '${formatMoney(debt.monthlyPayment)} a month',
            trailing: formatMoneyCompact(debt.currentBalance),
            onTap: () => _editLiability(context, ref, debt),
            onDelete: () => notifier.removeLiability(debt.id),
          ),
        for (final asset in household.assets)
          EntityTile(
            icon: Icons.home_outlined,
            title: asset.label,
            subtitle: '${humanise(asset.category.name)} · '
                '${asset.plannedSaleYear == null ? 'not for sale' : 'sold ${asset.plannedSaleYear}'}',
            trailing: formatMoneyCompact(asset.currentValue),
            onTap: () => _editAsset(context, ref, asset),
            onDelete: () => notifier.removeAsset(asset.id),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            onPressed: () => _editAsset(context, ref, null),
            icon: const Icon(Icons.add_home_outlined),
            label: const Text('Add an asset'),
          ),
        ),
      ],
    );
  }

  Future<void> _editLiability(
      BuildContext context, WidgetRef ref, Liability? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var kind = existing?.kind ?? LiabilityKind.mortgage;
    var balance = existing?.currentBalance ?? Money.zero;
    var rate = existing?.interestRate ?? 0.05;
    var payment = existing?.monthlyPayment ?? Money.zero;
    var escrow = existing?.monthlyEscrowAmount;
    var originationYear = existing?.originationDate.year ?? DateTime.now().year;
    var term = existing?.termMonths ?? 360;
    var deductible = existing?.isTaxDeductibleInterest ?? false;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add a debt' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            LabelledTextField(
              label: 'Label',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 12),
            FieldRow([
              EnumField<LiabilityKind>(
                label: 'Kind',
                values: LiabilityKind.values,
                value: kind,
                onChanged: (v) => setState(() {
                  kind = v;
                  deductible = v == LiabilityKind.studentLoan;
                }),
              ),
              MoneyField(
                label: 'Balance',
                initial: balance,
                onChanged: (v) => balance = v,
              ),
            ]),
            FieldRow([
              PercentField(
                label: 'Interest rate',
                helper: 'Nominal, as the lender quotes it',
                initial: rate,
                onChanged: (v) => rate = v,
              ),
              MoneyField(
                label: 'Monthly payment',
                helper: 'What actually leaves the account',
                initial: payment,
                onChanged: (v) => payment = v,
              ),
            ]),
            FieldRow([
              MoneyField(
                label: 'Monthly escrow',
                helper: 'Blank infers it from the payment',
                initial: escrow,
                onChanged: (v) => escrow = v.isZero ? null : v,
              ),
              YearField(
                label: 'Term, months',
                initial: term,
                onChanged: (v) => term = v ?? term,
              ),
            ]),
            YearField(
              label: 'Origination year',
              initial: originationYear,
              onChanged: (v) => originationYear = v ?? originationYear,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  notifier.saveLiability(Liability(
                    id: existing?.id ?? newId('debt'),
                    householdId: household.id,
                    personId: existing?.personId ??
                        (household.taxUnits.length > 1
                            ? household.people.firstOrNull?.id
                            : null),
                    label: label.isEmpty ? humanise(kind.name) : label,
                    kind: kind,
                    currentBalance: balance,
                    interestRate: rate,
                    monthlyPayment: payment,
                    monthlyEscrowAmount: escrow,
                    monthlyPmiAmount: existing?.monthlyPmiAmount,
                    escrowContinuesAfterPayoff:
                        existing?.escrowContinuesAfterPayoff ?? 1.0,
                    extraPrincipalPayment:
                        existing?.extraPrincipalPayment ?? Money.zero,
                    originationDate: DateTime(originationYear, 1, 1),
                    termMonths: term,
                    securedAssetId: existing?.securedAssetId,
                    isTaxDeductibleInterest: deductible,
                  ));
                  Navigator.of(context).pop();
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAsset(
      BuildContext context, WidgetRef ref, Asset? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    var label = existing?.label ?? '';
    var category = existing?.category ?? AssetCategory.primaryResidence;
    var value = existing?.currentValue ?? Money.zero;
    var basis = existing?.costBasis ?? Money.zero;
    var appreciation = existing?.realAppreciationRate ?? 0.0;
    var saleYear = existing?.plannedSaleYear;
    var proceedsAccount = existing?.saleProceedsAccountId;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add an asset' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            LabelledTextField(
              label: 'Label',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 12),
            FieldRow([
              EnumField<AssetCategory>(
                label: 'Category',
                helper: category.carriesSaleCost
                    ? 'Selling costs about 6% on real property'
                    : 'Sells at no modelled cost',
                values: AssetCategory.values,
                value: category,
                onChanged: (v) => setState(() => category = v),
              ),
              MoneyField(
                label: 'Value today',
                helper: 'Re-enter after an appraisal',
                initial: value,
                onChanged: (v) => value = v,
              ),
            ]),
            FieldRow([
              MoneyField(
                label: 'Cost basis',
                helper: 'Purchase price plus improvements',
                initial: basis,
                onChanged: (v) => basis = v,
              ),
              PercentField(
                label: 'Real appreciation',
                helper: 'Vehicles are negative',
                initial: appreciation,
                onChanged: (v) => appreciation = v,
              ),
            ]),
            FieldRow([
              YearField(
                label: 'Planned sale year',
                helper: 'Blank means it is not sold',
                initial: saleYear,
                onChanged: (v) => setState(() => saleYear = v),
              ),
              if (saleYear != null)
                ChoiceField<Account>(
                  label: 'Proceeds land in',
                  helper: 'Required: proceeds that go nowhere vanish',
                  values: household.accounts,
                  value: household.accounts
                      .where((a) => a.id == proceedsAccount)
                      .firstOrNull,
                  describe: (a) => a.label,
                  onChanged: (a) => proceedsAccount = a.id,
                ),
            ]),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  notifier.saveAsset(Asset(
                    id: existing?.id ?? newId('asset'),
                    householdId: household.id,
                    personId: existing?.personId ??
                        (household.taxUnits.length > 1
                            ? household.people.firstOrNull?.id
                            : null),
                    label: label.isEmpty ? humanise(category.name) : label,
                    category: category,
                    currentValue: value,
                    costBasis: basis,
                    realAppreciationRate: appreciation,
                    accumulatedDepreciation:
                        existing?.accumulatedDepreciation ?? Money.zero,
                    landFraction: existing?.landFraction ?? 0.20,
                    securedByLiabilityId: existing?.securedByLiabilityId,
                    acquisitionYear: existing?.acquisitionYear,
                    purchaseFundingAccountId:
                        existing?.purchaseFundingAccountId,
                    plannedSaleYear: saleYear,
                    saleProceedsAccountId:
                        saleYear == null ? null : proceedsAccount,
                  ));
                  Navigator.of(context).pop();
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
