import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/readiness.dart';
import '../widgets/entity_list.dart';
import '../widgets/fields.dart';
import 'accounts_screen.dart';
import 'property_screen.dart';
import 'household_screen.dart';
import 'housing_screen.dart';
import 'income_screen.dart';
import 'spending_screen.dart';

/// The ordered path through a plan, and the only place the app asks for
/// anything in a particular order.
///
/// It creates the same entities the seven screens do, through the same editors,
/// so nothing here is a second way to enter an account. What it adds is
/// sequence: which question comes next, why it is being asked, and the fact
/// that no answer is worked out until the person says the plan is ready.
class SetupFlow extends ConsumerStatefulWidget {
  /// Where to start, for somebody returning to finish a step.
  final SetupStep? startAt;

  const SetupFlow({super.key, this.startAt});

  static Future<void> open(BuildContext context, {SetupStep? at}) =>
      Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SetupFlow(startAt: at),
      ));

  @override
  ConsumerState<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends ConsumerState<SetupFlow> {
  late int _index = widget.startAt?.index ?? 0;

  SetupStep get _step => SetupStep.values[_index];
  bool get _isLast => _index == SetupStep.values.length - 1;

  void _go(int delta) => setState(() => _index =
      (_index + delta).clamp(0, SetupStep.values.length - 1));

  void _declare() {
    ref.read(setupProgressProvider.notifier).declareReady();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final household = ref.watch(householdProvider);
    final setup = ref.watch(setupProgressProvider);

    final gating = SetupStep.values.where((s) => s.gates).toList();
    final done = setup.doneCount(household);
    final canDeclare = setup.canDeclare(household);

    return Scaffold(
      appBar: AppBar(
        title: Text(_step.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Finish later'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          LinearProgressIndicator(
            value: done / gating.length,
            minHeight: 4,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              children: [
                Text(
                  _step.gates
                      ? 'Step ${_index + 1} of ${gating.length}'
                      : 'Optional',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 4),
                Text(_step.question, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  _step.because,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                const _Blocking(),
                _StepBody(step: _step),
              ],
            ),
          ),
          _Footer(
            step: _step,
            isFirst: _index == 0,
            isLast: _isLast,
            canDeclare: canDeclare,
            outstanding: setup.remaining(household).toList(),
            entered: _step.enteredIn(household),
            passed: setup.passed.contains(_step),
            onBack: () => _go(-1),
            onNext: () => _go(1),
            onNone: () {
              ref.read(setupProgressProvider.notifier).pass(_step);
              _go(1);
            },
            onDeclare: _declare,
          ),
        ],
      ),
    );
  }
}

/// Back, forward, and the two answers that are not entries: "none of these"
/// and "I am ready".
class _Footer extends StatelessWidget {
  final SetupStep step;
  final bool isFirst;
  final bool isLast;
  final bool canDeclare;

  /// The steps still unanswered, so a shut door can say what is holding it.
  final List<SetupStep> outstanding;
  final bool entered;
  final bool passed;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onNone;
  final VoidCallback onDeclare;

  const _Footer({
    required this.step,
    required this.isFirst,
    required this.isLast,
    required this.canDeclare,
    required this.outstanding,
    required this.entered,
    required this.passed,
    required this.onBack,
    required this.onNext,
    required this.onNone,
    required this.onDeclare,
  });

  @override
  Widget build(BuildContext context) {
    // Spending is the last gating step, so it is where the door is. The
    // refinements page after it is optional and carries the same door.
    final atTheDoor = step == SetupStep.spending || isLast;

    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (atTheDoor && !canDeclare) ...[
              Text(
                'Still to answer: ${_list(outstanding)}. A step you have '
                'nothing for takes "I have none of these".',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
            if (!isFirst)
              TextButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
            const Spacer(),
            if (step.canBeNone && !entered && !passed) ...[
              TextButton(
                onPressed: onNone,
                child: const Text('I have none of these'),
              ),
              const SizedBox(width: 8),
            ],
            if (atTheDoor)
              Tooltip(
                message: canDeclare
                    ? ''
                    : 'Still missing something the answer depends on',
                child: FilledButton.icon(
                  onPressed: canDeclare ? onDeclare : null,
                  icon: const Icon(Icons.insights),
                  label: const Text('Show me my plan'),
                ),
              )
            else
              FilledButton(onPressed: onNext, child: const Text('Next')),
            if (step == SetupStep.spending && canDeclare) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: onNext,
                child: Text(SetupStep.refinements.title),
              ),
            ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _list(List<SetupStep> steps) {
    final names = steps.map((s) => s.title.toLowerCase()).toList();
    if (names.length == 1) return names.single;
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }
}

/// What §12 found wrong, shown where it can be acted on rather than on a
/// screen the user has to go looking for.
class _Blocking extends ConsumerWidget {
  const _Blocking();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final blocking = ref
        .watch(findingsProvider)
        .where((f) => f.severity == Severity.blocking)
        .toList();
    if (blocking.isEmpty) return const SizedBox.shrink();

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              blocking.length == 1
                  ? 'One thing needs fixing before this can be worked out'
                  : '${blocking.length} things need fixing before this can be '
                      'worked out',
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
            const SizedBox(height: 8),
            for (final finding in blocking)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(finding.message,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onErrorContainer)),
              ),
          ],
        ),
      ),
    );
  }
}

class _StepBody extends ConsumerWidget {
  final SetupStep step;
  const _StepBody({required this.step});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (step) {
      SetupStep.people => const _People(),
      SetupStep.work => const _Work(),
      SetupStep.accounts => const _OtherAccounts(),
      SetupStep.owned => const _Owned(),
      SetupStep.owed => const _Owed(),
      SetupStep.housing => const _Housing(),
      SetupStep.spending => const _Spending(),
      SetupStep.refinements => const _Refinements(),
    };
  }
}

class _People extends ConsumerWidget {
  const _People();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    const screen = HouseholdScreen();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntitySection(
          title: 'People',
          addLabel: 'Add a person',
          emptyMessage: 'Start with yourself.',
          onAdd: () => screen.editPerson(context, ref, null),
          children: [
            for (final person in household.people)
              EntityTile(
                    icon: Icons.person_outline,
                title: person.displayName,
                subtitle: 'born ${person.birthDate.year}',
                onTap: () => screen.editPerson(context, ref, person),
                onDelete: () => ref
                    .read(householdProvider.notifier)
                    .removePerson(person.id),
              ),
          ],
        ),
        for (final unit in household.taxUnits) ...[
          const SizedBox(height: 16),
          TaxUnitCard(unit: unit),
        ],
      ],
    );
  }
}

/// The compound step: an employer, what it pays, and everything else that
/// arrives through the same paycheck.
///
/// A 401(k) is an account and an FSA is a payroll deduction, which matters to
/// the engine and to nobody else. Both are asked for here, under the job they
/// belong to, because that is where a person keeps them in their head.
class _Work extends ConsumerWidget {
  const _Work();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    const income = IncomeScreen();
    const accounts = AccountsScreen();

    if (household.employers.isEmpty) {
      return _Empty(
        message: 'Nobody working right now? That is a plan too.',
        actionLabel: 'Add a job',
        onAction: () => income.editEmployer(context, ref, null),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final employer in household.employers) ...[
          _JobCard(employer: employer),
          const SizedBox(height: 16),
        ],
        OutlinedButton.icon(
          onPressed: () => income.editEmployer(context, ref, null),
          icon: const Icon(Icons.add),
          label: const Text('Add another job'),
        ),
        const SizedBox(height: 24),
        Text(
          'Anything not tied to a job comes next.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        // Left here as well as on the next step, because somebody who is
        // self-employed has pay with no employer behind it.
        TextButton(
          onPressed: () => income.editIncome(context, ref, null),
          child: const Text('Add income with no employer'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => accounts.editAccount(context, ref, null),
          child: const Text('Add an account with no employer'),
        ),
      ],
    );
  }
}

class _JobCard extends ConsumerWidget {
  final Employer employer;
  const _JobCard({required this.employer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final household = ref.watch(householdProvider);
    const income = IncomeScreen();
    const accounts = AccountsScreen();

    final pay =
        household.incomeStreams.where((s) => s.employerId == employer.id);
    final held = household.accounts.where((a) => a.employerId == employer.id);
    final people = household.people.map((p) => p.id).toSet();
    final deductions =
        household.payrollDeductions.where((d) => people.contains(d.personId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(employer.label,
                      style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => income.editEmployer(context, ref, employer),
                ),
              ],
            ),
            EntitySection(
              title: 'What it pays',
              addLabel: 'Add pay',
              emptyMessage: 'Salary, bonus, vesting shares.',
              onAdd: () => income.editIncome(context, ref, null),
              children: [
                for (final stream in pay)
                  EntityTile(
                    icon: Icons.payments_outlined,
                    title: stream.label,
                    subtitle: formatMoney(stream.grossAnnualAmount),
                    onTap: () => income.editIncome(context, ref, stream),
                    onDelete: () => ref
                        .read(householdProvider.notifier)
                        .removeIncomeStream(stream.id),
                  ),
              ],
            ),
            EntitySection(
              title: 'What you save through it',
              blurb: 'A 401(k), an HSA, anything that stays yours and grows.',
              addLabel: 'Add an account',
              emptyMessage: 'Nothing saved here yet.',
              onAdd: () => accounts.editAccount(context, ref, null),
              children: [
                for (final account in held)
                  EntityTile(
                    icon: Icons.savings_outlined,
                    title: account.label,
                    subtitle: formatMoney(account.balance),
                    onTap: () => accounts.editAccount(context, ref, account),
                    onDelete: () => ref
                        .read(householdProvider.notifier)
                        .removeAccount(account.id),
                  ),
              ],
            ),
            EntitySection(
              title: 'What it takes out',
              blurb: 'An FSA, a health premium, a transit pass. Money that '
                  'goes out and does not come back.',
              addLabel: 'Add a deduction',
              emptyMessage: 'Nothing coming out yet.',
              onAdd: () => income.editDeduction(context, ref, null),
              children: [
                for (final deduction in deductions)
                  EntityTile(
                    icon: Icons.remove_circle_outline,
                    title: deduction.label,
                    subtitle: '${formatMoney(deduction.annualAmount)} a year',
                    onTap: () =>
                        income.editDeduction(context, ref, deduction),
                    onDelete: () => ref
                        .read(householdProvider.notifier)
                        .removePayrollDeduction(deduction.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OtherAccounts extends ConsumerWidget {
  const _OtherAccounts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    const screen = AccountsScreen();
    final loose =
        household.accounts.where((a) => a.employerId == null).toList();

    return EntitySection(
      title: 'Accounts',
      blurb: 'Old employers\' plans, IRAs, brokerages, savings, the current '
          'account.',
      addLabel: 'Add an account',
      emptyMessage: 'Nothing here yet.',
      onAdd: () => screen.editAccount(context, ref, null),
      children: [
        for (final account in loose)
          EntityTile(
                    icon: Icons.savings_outlined,
            title: account.label,
            subtitle: '${humanise(account.kind.name)} · '
                '${formatMoney(account.balance)}',
            onTap: () => screen.editAccount(context, ref, account),
            onDelete: () =>
                ref.read(householdProvider.notifier).removeAccount(account.id),
          ),
      ],
    );
  }
}

/// The one step that is not a list of things to add: it shows the whole plan's
/// housing at once, because a gap fourteen years out is invisible in a list.
class _Housing extends ConsumerWidget {
  const _Housing();

  @override
  Widget build(BuildContext context, WidgetRef ref) => const HousingTimeline();
}

class _Owned extends ConsumerWidget {
  const _Owned();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    const screen = PropertyScreen();

    return EntitySection(
      title: 'Property',
      blurb: 'A house, a car, anything else worth selling. Something you plan '
          'to buy later belongs here too, with the year you get it.',
      addLabel: 'Add something',
      emptyMessage: 'Renting and cycling is a perfectly good answer.',
      onAdd: () => screen.editAsset(context, ref, null),
      children: [
        for (final asset in household.assets)
          EntityTile(
                    icon: Icons.home_outlined,
            title: asset.label,
            subtitle: '${humanise(asset.category.name)} · '
                '${formatMoney(asset.currentValue)}',
            onTap: () => screen.editAsset(context, ref, asset),
            onDelete: () =>
                ref.read(householdProvider.notifier).removeAsset(asset.id),
          ),
      ],
    );
  }
}

class _Owed extends ConsumerWidget {
  const _Owed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    const screen = PropertyScreen();

    return EntitySection(
      title: 'Debts',
      blurb: 'A mortgage points at the house it is secured against, so add '
          'that first if you have not.',
      addLabel: 'Add a debt',
      emptyMessage: 'Nothing owed.',
      onAdd: () => screen.editLiability(context, ref, null),
      children: [
        for (final liability in household.liabilities)
          EntityTile(
                    icon: Icons.credit_card_outlined,
            title: liability.label,
            subtitle: '${humanise(liability.kind.name)} · '
                '${formatMoney(liability.currentBalance)}',
            onTap: () => screen.editLiability(context, ref, liability),
            onDelete: () => ref
                .read(householdProvider.notifier)
                .removeLiability(liability.id),
          ),
      ],
    );
  }
}

/// One number, then as much detail as anyone wants.
///
/// The important part is what it does not ask for. Debt payments, health
/// premiums and payroll deductions are all counted already, and a person
/// answering thoroughly would enter them twice.
class _Spending extends ConsumerStatefulWidget {
  const _Spending();

  @override
  ConsumerState<_Spending> createState() => _SpendingState();
}

class _SpendingState extends ConsumerState<_Spending> {
  bool? _detailed;

  /// The single coarse line, if that is how it was entered.
  static const coarseId = 'exp-everything';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);
    const screen = SpendingScreen();

    final items = household.expenseItems;
    final coarse = items.where((i) => i.id == coarseId).firstOrNull;
    // Detail is a view, not a one-way door. Somebody who opens it to see what
    // is in there has to be able to close it again.
    final detailed = _detailed ?? items.any((i) => i.id != coarseId);

    final counted = <String>[
      if (household.liabilities.isNotEmpty) 'your debt payments',
      if (household.liabilities.any((l) => l.monthlyEscrowAmount != null))
        'the property tax and insurance inside your mortgage',
      if (household.payrollDeductions.isNotEmpty)
        'what already comes out of your pay',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (counted.isNotEmpty)
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.playlist_add_check,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Already counted, so leave them out: '
                      '${_list(counted)}.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (!detailed) ...[
          MoneyField(
            label: 'Everything else, a year',
            helper: 'Housing, food, travel, the lot. A round number is fine, '
                'and you can break it up later.',
            initial: coarse?.amount ?? Money.zero,
            onChanged: (v) {
              if (!v.isPositive) return;
              final category = household.expenseCategories
                      .where((c) => c.metaCategory == MetaCategory.misc)
                      .firstOrNull ??
                  ExpenseCategory(
                    id: newId('cat'),
                    householdId: household.id,
                    label: 'Living',
                    metaCategory: MetaCategory.misc,
                  );
              notifier.saveCategory(category);
              notifier.saveExpenseItem(ExpenseItem(
                id: coarseId,
                categoryId: category.id,
                label: 'Everything else',
                amount: v,
                frequency: ExpenseFrequency.annual,
              ));
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _detailed = true),
              icon: const Icon(Icons.unfold_more),
              label: const Text('Break it down instead'),
            ),
          ),
        ] else ...[
          EntitySection(
            title: 'What a year costs',
            blurb: 'One line each, at whatever detail suits you.',
            addLabel: 'Add a cost',
            emptyMessage: 'Nothing entered.',
            onAdd: () => screen.editExpense(context, ref, null),
            children: [
              for (final item in items)
                EntityTile(
                    icon: Icons.receipt_long_outlined,
                  title: item.label,
                  subtitle: '${formatMoney(item.amount)} a year',
                  onTap: () => screen.editExpense(context, ref, item),
                  onDelete: () => ref
                      .read(householdProvider.notifier)
                      .removeExpenseItem(item.id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _detailed = false),
              icon: const Icon(Icons.unfold_less),
              label: const Text('Go back to one number'),
            ),
          ),
        ],
      ],
    );
  }

  static String _list(List<String> parts) => parts.length == 1
      ? parts.single
      : '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}

class _Refinements extends ConsumerWidget {
  const _Refinements();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final household = ref.watch(householdProvider);
    const spending = SpendingScreen();
    const people = HouseholdScreen();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntitySection(
          title: 'Social Security',
          blurb: 'Entered on the person it belongs to, since it depends on '
              'their earnings and when they claim.',
          addLabel: '',
          children: [
            for (final person in household.people)
              EntityTile(
                    icon: Icons.person_outline,
                title: person.displayName,
                subtitle: person.socialSecurity == null
                    ? 'not counted'
                    : 'counted from '
                        '${person.socialSecurity!.claimingAge}',
                onTap: () => people.editPerson(context, ref, person),
              ),
          ],
        ),
        const SizedBox(height: 16),
        EntitySection(
          title: 'One-off costs',
          blurb: 'A new roof, a wedding, a car replacement.',
          addLabel: 'Add one',
          emptyMessage: 'Nothing planned.',
          onAdd: () => spending.editEvent(context, ref, null),
          children: [
            for (final event in household.oneTimeEvents)
              EntityTile(
                    icon: Icons.event_outlined,
                title: event.label,
                subtitle: '${event.year} · ${formatMoney(event.amount)}',
                onTap: () => spending.editEvent(context, ref, event),
                onDelete: () => ref
                    .read(householdProvider.notifier)
                    .removeOneTimeEvent(event.id),
              ),
          ],
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _Empty({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add),
            label: Text(actionLabel),
          ),
        ],
      );
}
