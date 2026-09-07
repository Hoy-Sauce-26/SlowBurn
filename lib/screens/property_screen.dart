import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/flag_placement.dart';
import '../widgets/entity_list.dart';
import '../widgets/flag_banner.dart';
import '../widgets/fields.dart';

/// §3.5 and §3.6. Debts and the things they are secured against.
///
/// The two share a screen because a mortgage and the house behind it are one
/// decision, and invariant 5 requires them to agree about each other.
class PropertyScreen extends ConsumerWidget {
  const PropertyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    return EntityList(
      title: 'Property and debts',
      blurb: 'What the household owns and what it owes. Property first, since '
          'a mortgage points at the house it is secured against.',
      addLabel: 'Add something you own',
      emptyMessage: '',
      banner: const FlagBanner(home: FlagHome.debts),
      onAdd: () => editAsset(context, ref, null),
      children: [
        EntitySection(
          title: 'What you own',
          blurb: 'A house, a car, anything else worth selling. Something you '
              'plan to buy later belongs here too, with the year you get it.',
          addLabel: 'Add something you own',
          emptyMessage: 'Renting and cycling is a perfectly good answer.',
          onAdd: () => editAsset(context, ref, null),
          children: [
            for (final asset in household.assets)
              EntityTile(
                icon: Icons.home_outlined,
                title: asset.label,
                subtitle: _describeAsset(asset),
                trailing: formatMoneyCompact(asset.currentValue),
                onTap: () => editAsset(context, ref, asset),
                onDelete: () => notifier.removeAsset(asset.id),
              ),
            if (!housedIn(household, DateTime.now().year)) ...[
              const SizedBox(height: 8),
              const Note('Renting is an answer too, and the plan needs to '
                  'know: without it you are projected as living for free.'),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => askAboutRent(context, ref,
                      from: DateTime.now().year),
                  icon: const Icon(Icons.vpn_key_outlined),
                  label: const Text('I rent'),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        EntitySection(
          title: 'What you owe',
          blurb: 'Debt service reaches the plan on its own, so none of this '
              'needs a spending line, and escrow keeps being paid after a '
              'mortgage is gone.',
          addLabel: 'Add a debt',
          emptyMessage: 'Nothing owed.',
          onAdd: () => editLiability(context, ref, null),
          children: [
            for (final debt in household.liabilities)
              EntityTile(
                icon: Icons.credit_card_outlined,
                title: debt.label,
                subtitle: '${humanise(debt.kind.name)} · '
                    '${formatPercent(debt.interestRate)} · '
                    '${formatMoney(debt.monthlyPayment)} a month',
                trailing: formatMoneyCompact(debt.currentBalance),
                onTap: () => editLiability(context, ref, debt),
                onDelete: () => notifier.removeLiability(debt.id),
              ),
          ],
        ),
      ],
    );
  }

  static String _describeAsset(Asset a) {
    final when = a.acquisitionYear == null
        ? 'owned'
        : 'bought ${a.acquisitionYear}';
    final until =
        a.plannedSaleYear == null ? 'kept' : 'sold ${a.plannedSaleYear}';
    return '${humanise(a.category.name)} · $when · $until';
  }

  Future<void> editLiability(
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
    var securedAssetId = existing?.securedAssetId;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add a debt' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
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
            if (household.assets.isNotEmpty) ...[
              const SizedBox(height: 12),
              SearchableField<Asset>(
                label: 'Secured against',
                helper: 'What the lender takes if it is not paid. Linking a '
                    'mortgage to its house is what lets selling the house '
                    'clear the debt.',
                values: household.assets,
                value: household.assets
                    .where((a) => a.id == securedAssetId)
                    .firstOrNull,
                noneLabel: 'Nothing',
                describe: (a) => a.label,
                onChanged: (a) => setState(() => securedAssetId = a?.id),
              ),
            ],
            const SizedBox(height: 12),
            LabelledTextField(
              label: 'Name it (optional)',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 4),
            Note('Left blank, this will be called "${defaultLiabilityLabel(household, kind: kind, securedAssetId: securedAssetId, excluding: existing?.id)}".'),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  final debtId = existing?.id ?? newId('debt');
                  notifier.saveLiability(Liability(
                    id: debtId,
                    householdId: household.id,
                    personId: existing?.personId ??
                        (household.taxUnits.length > 1
                            ? household.people.firstOrNull?.id
                            : null),
                    label: label.trim().isEmpty
                        ? defaultLiabilityLabel(household,
                            kind: kind,
                            securedAssetId: securedAssetId,
                            excluding: existing?.id)
                        : label.trim(),
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
                    securedAssetId: securedAssetId,
                    isTaxDeductibleInterest: deductible,
                  ));
                  // Invariant 5: the two ends of the link have to agree, so
                  // the asset is updated alongside rather than left pointing
                  // at a debt that no longer claims it.
                  for (final asset in household.assets) {
                    final shouldPoint = asset.id == securedAssetId;
                    if ((asset.securedByLiabilityId == debtId) ==
                        shouldPoint) {
                      continue;
                    }
                    notifier.saveAsset(asset.withSecuring(
                        shouldPoint ? debtId : null));
                  }
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

  Future<void> editAsset(
      BuildContext context, WidgetRef ref, Asset? existing) async {
    final household = ref.read(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    final assumed = ref.read(scenarioProvider).assumptions;

    var label = existing?.label ?? '';
    var category = existing?.category ?? AssetCategory.primaryResidence;
    var value = existing?.currentValue ?? Money.zero;
    var basis = existing?.costBasis ?? Money.zero;
    // A new asset starts on what its kind usually does rather than on a zero
    // that quietly says a car holds its value forever.
    double? appreciation = existing?.realAppreciationRate ??
        assumed.assetAppreciationByCategory[category];
    var saleYear = existing?.plannedSaleYear;
    var acquisitionYear = existing?.acquisitionYear;
    var fundingAccount = existing?.purchaseFundingAccountId;
    final thisYear = DateTime.now().year;
    var proceedsAccount = existing?.saleProceedsAccountId;

    await showEditor<void>(
      context,
      title: existing == null ? 'Add an asset' : existing.label,
      build: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            FieldRow([
              EnumField<AssetCategory>(
                label: 'Category',
                helper: category.carriesSaleCost
                    ? 'Selling costs about 6% on real property'
                    : 'Sells at no modelled cost',
                values: AssetCategory.values,
                value: category,
                onChanged: (v) => setState(() {
                  // The rate follows the kind of thing until somebody says
                  // otherwise, so a car is not left appreciating like a house.
                  if (appreciation == null ||
                      appreciation ==
                          assumed.assetAppreciationByCategory[category]) {
                    appreciation = assumed.assetAppreciationByCategory[v];
                  }
                  category = v;
                }),
              ),
              if (acquisitionYear == null)
                MoneyField(
                  label: 'Value today',
                  helper: 'Re-enter after an appraisal',
                  initial: value,
                  onChanged: (v) => value = v,
                )
              else
                MoneyField(
                  key: ValueKey('price$acquisitionYear'),
                  label: 'What it will cost',
                  helper: "In today's money. It enters the plan at this in "
                      '$acquisitionYear and grows from there, so there is no '
                      'value today to enter.',
                  initial: basis,
                  onChanged: (v) => basis = v,
                ),
            ]),
            FieldRow([
              if (acquisitionYear == null)
                MoneyField(
                  label: 'Cost basis',
                  helper: 'Purchase price plus improvements. This is what a '
                      'gain on sale is measured against.',
                  initial: basis,
                  onChanged: (v) => basis = v,
                ),
              PercentField(
                key: ValueKey(appreciation),
                label: 'Gains value at',
                helper: 'Above inflation, each year. Suggested from what this '
                    'kind of thing usually does, which you can change here or '
                    'for everything at once on the Plan screen.',
                initial: appreciation,
                onChanged: (v) => appreciation = v,
              ),
            ]),
            // Buying something later is what makes a plan a plan: a house in
            // ten years, a replacement car in four. Held from that year, paid
            // for in it, and absent from net worth until then (§3.5).
            NumberChoiceField(
              label: 'When you get it',
              helper: 'A future purchase costs what you enter under "Value '
                  'today", is paid for from the account below, and counts for '
                  'nothing until then.',
              first: thisYear,
              last: thisYear + 60,
              value: acquisitionYear,
              noneLabel: 'I already own it',
              onChanged: (v) => setState(() {
                acquisitionYear = v;
                if (v == null) fundingAccount = null;
              }),
            ),
            if (acquisitionYear != null && household.accounts.isNotEmpty) ...[
              const SizedBox(height: 12),
              SearchableField<Account>(
                label: 'Paid for from',
                helper: 'The deposit comes out of here, or the whole price '
                    'where no mortgage secures it. Nothing at all means it was '
                    'given to you.',
                values: household.accounts,
                value: household.accounts
                    .where((a) => a.id == fundingAccount)
                    .firstOrNull,
                noneLabel: 'Nothing, it was a gift or an inheritance',
                describe: (a) => a.label,
                onChanged: (a) => setState(() => fundingAccount = a?.id),
              ),
            ],
            const SizedBox(height: 12),
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
            const SizedBox(height: 12),
            LabelledTextField(
              label: 'Name it (optional)',
              initial: label,
              onChanged: (v) => label = v,
            ),
            const SizedBox(height: 4),
            Note('Left blank, this will be called "${defaultAssetLabel(household, category: category, excluding: existing?.id)}".'),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () async {
                  notifier.saveAsset(Asset(
                    id: existing?.id ?? newId('asset'),
                    householdId: household.id,
                    personId: existing?.personId ??
                        (household.taxUnits.length > 1
                            ? household.people.firstOrNull?.id
                            : null),
                    label: label.trim().isEmpty
                        ? defaultAssetLabel(household,
                            category: category, excluding: existing?.id)
                        : label.trim(),
                    category: category,
                    // §3.5: something bought later enters at what it cost, so
                    // the price is both its basis and its opening value.
                    currentValue: acquisitionYear == null ? value : basis,
                    costBasis: basis,
                    realAppreciationRate: appreciation ?? 0,
                    accumulatedDepreciation:
                        existing?.accumulatedDepreciation ?? Money.zero,
                    landFraction: existing?.landFraction ?? 0.20,
                    securedByLiabilityId: existing?.securedByLiabilityId,
                    acquisitionYear: acquisitionYear,
                    purchaseFundingAccountId: fundingAccount,
                    plannedSaleYear: saleYear,
                    saleProceedsAccountId:
                        saleYear == null ? null : proceedsAccount,
                  ));
                  Navigator.of(context).pop();
                  // Selling the roof over your head is one field. Where you
                  // live afterwards is another, and nothing else in the model
                  // would notice it was missing.
                  final sold = saleYear;
                  if (sold != null &&
                      category == AssetCategory.primaryResidence) {
                    await askAboutRent(context, ref, from: sold);
                  }
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

/// Asked when a home is given a sale year, because the plan would otherwise
/// project the household living for free from that year on.
///
/// Offered rather than imposed: moving in with family is a real answer, and
/// `noHousingCost` keeps saying so on the Spending screen for anyone who takes
/// it.
Future<void> askAboutRent(
  BuildContext context,
  WidgetRef ref, {
  required int from,
}) async {
  final household = ref.read(householdProvider);
  if (housedIn(household, from)) return;

  var monthly = Money.zero;
  final added = await showEditor<bool>(
    context,
    title: from <= DateTime.now().year
        ? 'What do you pay to live there?'
        : 'Where will you live from $from?',
    build: (context) => StatefulBuilder(
      builder: (context, setState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Note(from <= DateTime.now().year
              ? 'Rent counts as spending like anything else, and it is what '
                  'keeps the plan from projecting you as living for free.'
              : 'Selling a home leaves the plan with nowhere to put you. Rent '
                  'is the usual answer, and buying somewhere smaller is '
                  'another asset with its own year.'),
          const SizedBox(height: 16),
          MoneyField(
            label: from <= DateTime.now().year
                ? 'Rent a month'
                : 'Rent a month, from $from',
            helper: "In today's money, like everything else here.",
            initial: monthly,
            onChanged: (v) => monthly = v,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('I will sort it out later'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Add it'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  if (added != true || !monthly.isPositive) return;

  final notifier = ref.read(householdProvider.notifier);
  final category = household.expenseCategories
          .where((c) => c.metaCategory == MetaCategory.housing)
          .firstOrNull ??
      ExpenseCategory(
        id: newId('cat'),
        householdId: household.id,
        label: 'Housing',
        metaCategory: MetaCategory.housing,
      );
  notifier.saveCategory(category);
  notifier.saveExpenseItem(ExpenseItem(
    id: newId('exp'),
    categoryId: category.id,
    label: 'Rent',
    amount: monthly * 12,
    frequency: ExpenseFrequency.annual,
    // Rent already being paid needs no start year; rent from a future sale
    // does, or it would be charged from today.
    startYear: from <= DateTime.now().year ? null : from,
  ));
}

/// "House mortgage", or "Mortgage" where nothing is pledged against it.
String defaultLiabilityLabel(
  Household household, {
  required LiabilityKind kind,
  required Id? securedAssetId,
  Id? excluding,
}) {
  final what = humanise(kind.name);
  final asset = household.assets
      .where((a) => a.id == securedAssetId)
      .firstOrNull
      ?.label;
  final base = asset == null ? what : '$asset ${what.toLowerCase()}';
  return uniqueLabel(
      base,
      household.liabilities
          .where((l) => l.id != excluding)
          .map((l) => l.label));
}

/// What the thing is, in the words people use for it.
String defaultAssetLabel(
  Household household, {
  required AssetCategory category,
  Id? excluding,
}) {
  final base = switch (category) {
    AssetCategory.primaryResidence => 'House',
    AssetCategory.investmentProperty => 'Rental property',
    AssetCategory.vehicle => 'Car',
    AssetCategory.collectible => 'Collection',
    AssetCategory.businessEquity => 'Business',
    AssetCategory.other => 'Property',
  };
  return uniqueLabel(base,
      household.assets.where((a) => a.id != excluding).map((a) => a.label));
}
