# Backlog

Work the app owes, that is not a defect in what is already there. Two other
lists exist and this is not either of them: §13 of [domain.md](domain.md) is
what the model deliberately does not do, and
[domain-review-backlog.md](domain-review-backlog.md) is ideas for the review
lenses. This is the ordinary queue.

## Data

**State retirement-income exclusions.** `retirementIncomeExclusion` is zero for
all fifty-one jurisdictions. The engine applies it correctly, capped by the
retirement income a household actually received, so this is a data job rather
than a model one. Illinois, Pennsylvania and Mississippi exempt retirement
income almost entirely and roughly thirty more states exclude part of it,
usually behind an age or income test that the current shape cannot express, so
some of those states will need a qualifier field before their number can be
entered. Until then retirees in those states are shown more state tax than they
owe, which for a FIRE app is the wrong direction to be wrong in.

**ACA benchmark premiums.** `acaBenchmarkPremiumByAge` is a smooth curve
standing in for a national average, and 2026 premiums rose steeply. Real
figures vary by rating area as much as by age, so the honest fix is either a
rating-area table or a prompt that makes entering your own benchmark the
expected path rather than an override.

**The edges of the 529 model.** Money left after the last education bill is
flagged, and its one way out is the penalty route: the rollover of up to
$35,000 into the beneficiary's Roth IRA is not modelled. Contributions above a
state's cap are not carried forward, which understates Virginia, Ohio and
Maryland for anyone putting in more than the cap in one year. Oregon's credit
is stored at a single income tier.

## Product

**Coach marks over the screens.** The ordered setup path in
`lib/screens/setup_screen.dart` covers getting a plan built. What is still
missing is the tour of the app itself, pointing at the results panel and the
flags and saying what they are for. Left until the setup path has been in front
of people, since it will be obvious afterwards which parts still need pointing
at.

**Two screens over the same numbers.** `Breakdown` asks the three questions
somebody actually has and carries the levers beside each answer; `Plan` shows
the chart, the bands and every assumption in one list. Breakdown is the one to
keep if only one survives, and Plan holds three things it does not yet: the
net-worth chart, the three-band comparison, and the assumptions nobody asks
about in the ordinary case. Worth revisiting once Breakdown has been used.

**Nothing in the app answers `acaMagiBelowSubsidyFloor`.** The flag names a
real, already-priced cost: below the federal poverty line the marketplace pays
nothing, and the plan is charged the full premium. The remedy is a Roth
conversion or a deliberate realisation of gains, and §13.3 defers conversion
ladders, so a person reading the warning has nowhere to go inside the app. The
flag says so rather than implying an adjustment exists. Whichever lands first,
conversions or a "realise this much income" input, closes it.

## Consistency

**Year fields in the payroll deduction editor** are still typed, where the
person and income editors pick them from a list. Same concept, two input
styles.
