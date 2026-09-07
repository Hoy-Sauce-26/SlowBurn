# Implementation plan

How Slow Burn gets built, and in what order. [domain.md](domain.md) says what it has to
compute; this is how the code gets there.

## The shape of the problem

Slow Burn looks like a form-and-dashboard app and is not one. Behind the forms sits a tax
engine:

| | |
|---|---|
| entities | 17, carrying 192 fields |
| formula blocks | 38 |
| invariants | 29 |
| flags the engine can raise | 21 |
| bundled tax-year data points | 32 |

Two of those formulas are solves rather than expressions. §4.3 ⇄ §4.4 is a fixed point,
because tax depends on contributions and contributions depend on what is left after tax.
§8.2 leg 3 forks a **whole multi-decade projection per candidate retirement year, per
band**, which makes the engine's inner loop a simulation and not a sum.

Everything the user sees is a rendering of numbers that solve came up with. So the engine
is the product, and it is built first and alone.

## Stack

Flutter, matching Roamfree (`../step_counter`). The design language is already written
in it, and its desktop targets are the cheapest route to a real desktop build.

| | | |
|---|---|---|
| state | `flutter_riverpod` | as Roamfree |
| storage | `sqflite` + `sqflite_common_ffi` | the ffi half is how sqflite reaches macOS, Windows and Linux; Roamfree never needed it |
| charts | `fl_chart` | as Roamfree |
| formatting | `intl` | currency and dates |

**No telemetry, no crash reporting, no network client.** §1.4 and §11 make local-only a
domain rule rather than a preference, and a dependency that phones home would violate it
silently.

### The engine is a package, not a folder

`packages/burn_engine`, a pure Dart package with **no Flutter dependency at all**, mirroring
how Roamfree vendors `packages/roameter`.

This is the single most important structural decision here. A `flutter` import inside the
engine means the engine can only be tested through a widget harness, and 38 formula blocks
resolving a fixed point need to be testable as arithmetic. Pure Dart also means the whole
engine runs in `dart test` in milliseconds, and can be moved to an isolate later if a
multi-band solve turns out to block the frame.

```
packages/burn_engine/lib/
  entities/     the 17 types, immutable, with copyWith
  taxyear/      the bundled ruleset and its loader
  pipeline/     §4.1 → §4.5, one year
  loop/         §6, the projection
  solve/        §8.2 and §8.1
  measures/     §5
lib/            the Flutter app: screens, widgets, persistence
```

## Build order

Each stage ends at a number that can be checked, because a stage that ends at "it compiles"
teaches nothing.

### Stage 1. Entities and the ruleset

The 17 types and a `TaxYear` loaded from a bundled versioned JSON asset. No behavior.

**Done when** a household can be constructed in a test and a `TaxYear` round-trips through
its loader. The 29 invariants land here too, as a `validate()` returning findings rather
than throwing, matching §12's warn-don't-block posture.

### Stage 2. One year

§4.1 through §4.5 for a single year, with `retirementYear` handed in rather than solved.
This is where the §4.3 ⇄ §4.4 fixed point gets written, and where most of the tax law lives.

**Done when** the FICA example from §4.2 computes: someone with $150,000 of `ficaWages` and
$50,000 of `seNetEarnings` gets the wage base applied in the right order.

### Stage 3. The loop

§6: horizon, `frac`, the mid-year convention, growth, basis maintenance, amortization, asset
purchase and sale, RMDs, the `activeFraction` proration.

**Done when** the §6.3 basis rule holds: $40,000 drawn from a $100,000 account takes **40%**
of basis, not the 67% a closing-balance denominator would take. That single test is worth
writing first, because it is the bug the domain review found and the one most likely to come
back.

### Stage 4. The solve

§8.2's three legs, the baseline pass, the candidate fork, the final pass, across three
bands. Leg 3 is expensive by construction, so leg 1 and 2 gate it exactly as §6.1 says.

**Done when** §8.1's worked example reproduces: $70,000 of base spending plus a $22,000
mortgage running ten more years, leaving $6,000 of continuing escrow, over 40 years at 3.5%
gives a first year of $92,000, a level equivalent of **$82,231**, and a FIRE number of
**$2.35M**. The doc also gives three sensitivities off the same household ($397,000,
$104,000, and zero), so this is four assertions from one fixture.

**This is the first point the app is worth looking at.** Everything before it is
scaffolding, and everything after it is presentation.

### Stage 5. Persistence

sqflite with the ffi initializer for desktop, the export/import JSON of §11, and
`ProjectionSnapshot` with its `inputDigest` and trigger rules (§10).

**Done when** a household survives a round trip through export and import, and a snapshot
comparison across two scenarios reports what differs (§10.2).

### Stage 6. The shell

Navigation, theming, and the responsive frame below. No real screens yet.

### Stage 7. The screens

Household, Income, Accounts, Expenses, Debts, Assets, Plan. Each is a list plus an editor.
This is the largest stage by file count and the least interesting by decision count.

### Stage 8. The guided flow, variants, and flags

The walkthrough, §9's four variants as onboarding presets, and the 21 flags surfaced where
they belong.

## Desktop is the better fit, and the layout should say so

Roamfree is a phone app with essentially no responsive code, one `MediaQuery` in the
tutorial overlay and nothing else. Slow Burn cannot inherit that, so this is the part being
designed rather than borrowed.

The reason desktop matters more here is specific. A retirement plan is an argument between
inputs and a result, and the interesting moment is watching the result move. On a phone the
inputs and the answer cannot share a screen, so every change is a round trip. On a desktop
they can, which makes the app better there rather than merely bigger.

```
< 600      one column, bottom navigation, results on their own screen
600–1024   two columns, navigation rail
> 1024     rail + content + a persistent results panel
```

The results panel is the desktop feature: retirement year, FIRE number,
`sustainableLevelSpending`, and the current flags, recomputed as the user types. It is the
same data the phone shows on its own screen, given a place to live rather than a new
concept.

**Layout lives in one place.** A single `AdaptiveScaffold` owns the breakpoints and every
screen fills a slot in it. Scattering `MediaQuery` checks through 7 screens is how a
codebase ends up responsive in some places and not others.

## Design language

Taken from Roamfree, with one substitution.

```dart
ColorScheme.fromSeed(seedColor: const Color(0xFFFF7467))
```

Material 3, light and dark generated from that one seed exactly as Roamfree does. Everything
else carries over: `Card` with `margin: EdgeInsets.zero`, the 16/8 padding rhythm, and the
`MetricCard` shape of icon, large value, unit, label, already the right shape for a FIRE
number.

`FF7467` is a coral where Roamfree's `FFC067` is an amber, and it is a darker seed. The
generated `onPrimary` and `primaryContainer` pairs need a contrast check in both brightnesses
before the palette is settled, rather than after seven screens are built on it.

The walkthrough follows `tutorial_overlay.dart`: `GlobalKey` targets, a dimmed scrim, a
cut-out per stop, and a tour that passes over any target whose key has no context. That last
behavior matters more here than it did in Roamfree, since Slow Burn's screens legitimately
differ, there being no debt step for a household with no debt.

## Testing

The domain doc was written with worked numbers in it, and **15 passages carry concrete
dollar figures**. Those are the acceptance tests, and they can be written before the code
they check.

The ones worth building fixtures around:

- §8.1's $92,000 / $82,231 / $2.35M household, plus its three payoff sensitivities
- §6.3's basis rule, $40,000 of $100,000 taking 40%
- §8.4.1's taxable draw splitting $40,000 into $28,000 basis and $12,000 gain
- §4.2's wage base with mixed W-2 and self-employment income
- §3.4.2's §415(c) and §402(g) interaction across two employers

Beyond those: a property test that `netSurplus` reconciles against the change in net worth
each year, and one that the fixed point converges within its pass cap for randomized
households. The 29 invariants become a validation suite run against every fixture.

`scripts/check-domain.py` keeps working on the doc throughout. When the code and the doc
disagree, the doc is the specification and the code is wrong until a decision says otherwise.

## Not in v1

Everything in §13 stays deferred. Two more things are worth naming as out of scope now
rather than discovered later:

- **Monte Carlo.** §13.1 defers it and the three-band model stands in its place. Adding it
  later changes the engine's shape, so the band structure should not be written as though a
  distribution is coming.
- **Sync of any kind.** Local-only is a domain rule (§1.4), and export/import is the whole
  portability story (§11).

## The one thing to get right early

The engine's public surface is `project(Household, Assumptions, TaxYear) → Projection`, and
nothing above it should reach inside. Every screen, every measure, and every snapshot reads
that one result. If the UI starts computing a number of its own, the number will eventually
disagree with the engine's, and the user will be shown two answers to the same question.
