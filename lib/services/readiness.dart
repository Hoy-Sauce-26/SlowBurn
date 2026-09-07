import 'package:burn_engine/burn_engine.dart';

import '../widgets/fields.dart';

/// What a plan needs before its numbers mean anything, in the order a person
/// naturally thinks of it.
///
/// This exists because the engine will answer whatever it is asked. A household
/// with a salary and a 401(k) balance but nothing entered for spending gets a
/// retirement year eleven years earlier than the truth, stated with the same
/// confidence as a complete one. Rather than guess, the app holds its numbers
/// back until the person says they are ready, and this is the list it walks
/// them through and then measures that readiness against.
enum SetupStep {
  /// Everyone the plan covers. Every age gate and the whole tax layer hangs
  /// off this, so nothing else can be asked first.
  people,

  /// A job, the pay it brings, and the things attached to it that come out of
  /// the same paycheck: the 401(k), an HSA, an FSA, the health premium.
  work,

  /// Everything held outside a current job. Old employers' plans, IRAs,
  /// brokerages, savings, the current account.
  accounts,

  /// A house, a car, anything else worth something that is not an account.
  /// Asked before debts, because a mortgage points at the house it secures.
  owned,

  /// A mortgage, a car loan, cards, student debt.
  owed,

  /// Somewhere to live, for every year of the plan rather than for today.
  /// Asked after property and debts, since owning a home is what usually
  /// answers it and a mortgage is what usually pays for it.
  housing,

  /// What a year costs. The one that decides the FIRE number outright, and the
  /// only step that cannot be answered "none".
  spending,

  /// Social Security, one-off events, a planned move. These move the answer;
  /// the six above decide whether there is an answer.
  refinements;

  /// Whether a plan is allowed to be declared ready without this step.
  bool get gates => this != SetupStep.refinements;

  /// Whether "I have none of these" is a real answer. Nobody spends nothing.
  bool get canBeNone =>
      this != SetupStep.people &&
      this != SetupStep.spending &&
      this != SetupStep.housing;

  String get title => switch (this) {
        SetupStep.people => 'Who the plan covers',
        SetupStep.work => 'Work',
        SetupStep.accounts => 'What you have',
        SetupStep.owned => 'What you own',
        SetupStep.owed => 'What you owe',
        SetupStep.housing => 'Where you live',
        SetupStep.spending => 'What a year costs',
        SetupStep.refinements => 'Sharpen it',
      };

  /// Asked the way someone would ask it out loud.
  String get question => switch (this) {
        SetupStep.people => 'Who is in your household?',
        SetupStep.work =>
          'Where do you work, and what comes out of that paycheck?',
        SetupStep.accounts => 'What else are you holding?',
        SetupStep.owned => 'What do you own that is worth something?',
        SetupStep.owed => 'What do you owe?',
        SetupStep.housing => 'Where do you live, for the whole of this plan?',
        SetupStep.spending => 'What does a year cost you?',
        SetupStep.refinements => 'Anything else worth telling me?',
      };

  /// Why it is being asked, in terms of the answer it changes.
  String get because => switch (this) {
        SetupStep.people =>
          'Ages decide when retirement money is reachable, and how you file '
              'decides the tax on everything else.',
        SetupStep.work =>
          'Your pay, and everything attached to it. A 401(k), an HSA and an '
              'FSA all come out of the same paycheck, so they are all here.',
        SetupStep.accounts =>
          'Where you start from. Which pot each one sits in is what decides '
              'whether you can reach it before 59½.',
        SetupStep.owned =>
          'A house and a car are worth something without being money you can '
              'spend, and the plan counts them differently because of it.',
        SetupStep.owed =>
          'Debt is money going out now and money that stops going out later, '
              'which moves a retirement date in both directions.',
        SetupStep.housing =>
          'Owning, renting, or owning something you have not bought yet. A '
              'plan with a year nobody lives anywhere is a plan that looks '
              'cheaper than it is.',
        SetupStep.spending =>
          'This one sets the target. Everything else says how fast you reach '
              'it; this says what it is.',
        SetupStep.refinements =>
          'Benefits, one-off costs and anything that only happens once.',
      };

  /// What the entities this step creates are called elsewhere in the app, so
  /// somebody can go and find them afterwards.
  String get livesOn => switch (this) {
        SetupStep.people => 'Household',
        SetupStep.work => 'Income',
        SetupStep.accounts => 'Accounts',
        SetupStep.owned => 'Property',
        SetupStep.owed => 'Property',
        SetupStep.housing => 'Housing',
        SetupStep.spending => 'Spending',
        SetupStep.refinements => 'Plan',
      };

  /// Whether the household holds anything for this step yet.
  bool enteredIn(Household h) => switch (this) {
        SetupStep.people => h.people.isNotEmpty,
        SetupStep.work => h.incomeStreams.isNotEmpty,
        SetupStep.accounts => h.accounts.isNotEmpty,
        SetupStep.owned => h.assets.isNotEmpty,
        SetupStep.owed => h.liabilities.isNotEmpty,
        // Not "is there a housing line", but "is every year covered", which
        // is the whole reason this is a step of its own.
        SetupStep.housing => h.people.isNotEmpty &&
            housingTimeline(h,
                    fromYear: DateTime.now().year,
                    toYear: horizonYear(h, const Assumptions(taxYearId: ''),
                        DateTime.now().year))
                .every((span) => !span.isGap),
        SetupStep.spending => h.expenseItems.isNotEmpty,
        SetupStep.refinements =>
          h.oneTimeEvents.isNotEmpty || h.people.any((p) => p.socialSecurity != null),
      };

  /// A line for the checklist: what was entered, not how many fields it took.
  String? summaryIn(Household h) {
    String plural(int n, String one, String many) =>
        '$n ${n == 1 ? one : many}';
    switch (this) {
      case SetupStep.people:
        if (h.people.isEmpty) return null;
        final where = h.taxUnits.isEmpty
            ? null
            : usStateCodes[h.taxUnits.first.stateCode];
        final names = h.people.map((p) => p.displayName).join(', ');
        return where == null ? names : '$names · $where';
      case SetupStep.work:
        if (h.incomeStreams.isEmpty) return null;
        final pay = sumMoney(h.incomeStreams.map((s) => s.grossAnnualAmount));
        return '${plural(h.incomeStreams.length, 'job', 'jobs')} · '
            '${formatMoneyCompact(pay)}';
      case SetupStep.accounts:
        if (h.accounts.isEmpty) return null;
        final held = sumMoney(h.accounts.map((a) => a.balance));
        return '${plural(h.accounts.length, 'account', 'accounts')} · '
            '${formatMoneyCompact(held)}';
      case SetupStep.owned:
        if (h.assets.isEmpty) return null;
        final worth = sumMoney(h.assets.map((a) => a.currentValue));
        return '${plural(h.assets.length, 'thing', 'things')} · '
            '${formatMoneyCompact(worth)}';
      case SetupStep.owed:
        if (h.liabilities.isEmpty) return null;
        final owed = sumMoney(h.liabilities.map((l) => l.currentBalance));
        return '${plural(h.liabilities.length, 'debt', 'debts')} · '
            '${formatMoneyCompact(owed)}';
      case SetupStep.housing:
        if (h.people.isEmpty) return null;
        final gaps = housingTimeline(h,
                fromYear: DateTime.now().year,
                toYear: horizonYear(
                    h, const Assumptions(taxYearId: ''), DateTime.now().year))
            .where((s) => s.isGap)
            .toList();
        if (gaps.isEmpty) return 'covered for every year';
        return '${plural(gaps.length, 'gap', 'gaps')} · '
            'from ${gaps.first.fromYear}';
      case SetupStep.spending:
        if (h.expenseItems.isEmpty) return null;
        final total = sumMoney(h.expenseItems.map((e) => e.amount));
        return '${formatMoneyCompact(total)} a year';
      case SetupStep.refinements:
        return enteredIn(h) ? 'entered' : null;
    }
  }
}

/// How far through the setup a household is, and whether its owner has said
/// they are ready to be shown numbers.
///
/// Kept beside the plan rather than inside it: this is a fact about how far
/// somebody has got, read by no calculation, and it has no business travelling
/// in a §11 export.
class SetupProgress {
  /// Steps the household has explicitly passed with nothing to enter. A renter
  /// owns no property, and that is an answer rather than an omission.
  final Set<SetupStep> passed;

  /// Whether the person has declared themselves ready to see a projection.
  final bool declaredReady;

  const SetupProgress({this.passed = const {}, this.declaredReady = false});

  bool isDone(SetupStep step, Household h) =>
      step.enteredIn(h) || (step.canBeNone && passed.contains(step));

  Iterable<SetupStep> remaining(Household h) =>
      SetupStep.values.where((s) => s.gates && !isDone(s, h));

  /// The next thing to ask about, or null when the six are answered.
  SetupStep? nextFor(Household h) => remaining(h).firstOrNull;

  int doneCount(Household h) =>
      SetupStep.values.where((s) => s.gates && isDone(s, h)).length;

  int get stepCount => SetupStep.values.where((s) => s.gates).length;

  /// Whether the declare action is live. Being ready is the person's call, but
  /// not over a plan that is missing something the answer depends on.
  bool canDeclare(Household h) => remaining(h).isEmpty;

  /// Numbers are shown once the person has declared the plan ready and it
  /// still holds the two things without which the answer means nothing.
  ///
  /// Deliberately weaker than [canDeclare]. Selling the car afterwards should
  /// not send somebody back behind the gate, but emptying the spending would
  /// leave the engine answering a question nobody asked.
  bool showsProjection(Household h) =>
      declaredReady &&
      SetupStep.people.enteredIn(h) &&
      SetupStep.spending.enteredIn(h);

  SetupProgress copyWith({Set<SetupStep>? passed, bool? declaredReady}) =>
      SetupProgress(
        passed: passed ?? this.passed,
        declaredReady: declaredReady ?? this.declaredReady,
      );
}
