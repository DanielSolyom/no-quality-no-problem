# No Quality, No Problem

**Quality, gone. Your factory, legendary.**

A Factorio mod that removes the quality mechanic and gives your factory and player
equipment legendary-quality stats. Enemies and world hazards keep their normal stats.

[![CI](https://github.com/DanielSolyom/no-quality-no-problem/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielSolyom/no-quality-no-problem/actions/workflows/ci.yml)
[![Mod portal](https://img.shields.io/factorio-mod-portal/v/no-quality-no-problem?label=mod%20portal&color=orange)](https://mods.factorio.com/mod/no-quality-no-problem)
[![Downloads](https://img.shields.io/factorio-mod-portal/dt/no-quality-no-problem?color=blue)](https://mods.factorio.com/mod/no-quality-no-problem)
[![Factorio](https://img.shields.io/badge/factorio-2.1-yellow)](https://factorio.com)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[Mod portal](https://mods.factorio.com/mod/no-quality-no-problem) ·
[Changelog](no-quality-no-problem/changelog.txt) ·
[Portal page source](PORTAL.md)

Playing Space Age with quality turned off leaves your factory permanently weaker than it
would otherwise be. Making everything legendary while leaving quality in place means
clicking through quality selectors you will never use. This mod does both halves, so the
mechanic disappears and the payoff stays.

## How it works

The shared `QualityPrototype` controls the engine's quality multipliers and bonuses.
The mod runs in `data-final-fixes.lua` and:

1. finds the highest-level quality present and copies **all** of its stat fields onto every
   other quality with a generic key loop;
2. offsets the changed multipliers for entities in the exclusion list, preserving their
   original normal-quality health, attack damage, attack range and relevant world-object stats;
3. hides every quality (`hidden`, `draw_sprite_by_default = false`) — the same mechanism the
   base game already uses to hide `normal` — and severs the quality upgrade chain;
4. strips the `quality` effect from every module and converts quality-only modules to ordinary
   items; keeps the items and production chains needed by useful recipes, hides unused ones,
   and removes unnecessary quality technologies while keeping the tech tree connected;
5. removes the quality tips-and-tricks entries and hides the quality signal.

### Quality modules as crafting ingredients

When another mod uses quality modules as ingredients for useful products, the required
modules remain available automatically. No setting is needed. They become **ordinary items**
with no effects and cannot be installed in machines or beacons. Their original crafting
costs and recipe-unlocking research are preserved, including lower tiers needed to make them.

Recycling recipes and recipes that only make more quality modules do not trigger retention.
Hidden recipes do not trigger it either. Without a useful consumer, quality modules and their
research stay hidden. Quality tiers, badges, selectors and quality-unlocking effects remain
disabled. Speed modules and useful hybrid modules retain their non-quality effects.

### Exclusion list

[`quality-exclusions.lua`](no-quality-no-problem/quality-exclusions.lua) lists entity types,
names and name prefixes that retain normal stats:

* All asteroid sizes and materials: metallic, carbonic, oxide and promethium.
* Biters, spitters, nests, worms, pentapods and their legs, demolishers and their segments.
* Crash-site wrecks, containers and fires, natural Fulgoran lightning attractors, markets and
  simple entities with an owner or force.

Spitter and worm acid damage is corrected at the attacking entity, including the damage
inherited by projectiles and lingering puddles. Shared player projectiles retain their bonuses.
Nest acid clouds, demolisher ash clouds and enemy slowing/disruption effects are excluded too.
Gradual slow effects preserve both their lifetime and their movement/vehicle recovery curves.
Trees, rocks and ordinary natural plants already ignore quality health scaling.

Factories, logistics (including belt splitters), player defences, characters, vehicles and
equipment keep their bonuses. Parts shared by enemies and player vehicles are separated
before applying exclusions.

Adding a prototype name requires handling its quality-sensitive properties in
[`preserve-world-stats.lua`](no-quality-no-problem/preserve-world-stats.lua) if it uses a
different entity type. Mods with additional scripted quality mechanics may need compatibility
code. Enemy effect durations round down to whole ticks when a modded quality multiplier would
require a fractional prototype duration.

* Higher quality tiers are supported. Tests include a level-7 tier with explicit multipliers
  and mod-added enemies and asteroids.
* Speed modules keep working — vanilla speed modules carry a *negative* quality effect, and
  only that field is removed.
* Quality stats are changed at the prototype level. A configuration-change handler updates
  module recipe and research availability in existing saves when the mod set changes.
  Uninstalling restores the quality mechanic.

## Repository layout

```
no-quality-no-problem/    the mod itself (this is what gets zipped)
scripts/ci-test.sh           data-stage + runtime test runner
build.sh                     package a portal-ready zip
publish.sh                   upload a release to the mod portal
portal.json + PORTAL.md      the mod portal page content, versioned in git
.github/workflows/           CI, tagged releases and hourly experimental-release checks
```

## Development

Install it for local play by symlinking the mod folder into Factorio's mods directory:

```bash
ln -s "$PWD/no-quality-no-problem" ~/.factorio/mods/no-quality-no-problem
```

### Testing

`scripts/ci-test.sh` needs only a Factorio binary — the **free headless build** works and
ships the expansion data (`quality`, `space-age`), so no licensed files or account are
required:

```bash
curl -fSL "https://factorio.com/get-download/2.1.17/headless/linux64" | tar -xJ
FACTORIO_BIN=factorio/bin/x64/factorio scripts/ci-test.sh all
```

To build and validate the actual ZIP with both Quality-only and Space Age profiles:

```bash
FACTORIO_BIN=factorio/bin/x64/factorio ./build.sh --test
```

CI and release builds use this command. A failed gameplay or compatibility check fails
the build before publication. `TEST_PROFILE=quality` or `space-age` selects one profile.

It runs every Factorio invocation against an isolated config, mod directory and write-data
directory, so it never touches your real saves, mods or script output.

| stage | what it checks |
|---|---|
| `data` | the mod loads, then every quality prototype is compared against a **baseline dump taken with the mod disabled** — level, hidden flag, severed chain, multipliers, module effects, technology unlocks |
| `runtime` | checks assembler speed and accumulator capacity, then compares world health, every enemy size, asteroid collisions on space platforms, acid/ash damage, hazard lifetimes, actual movement and vehicle slowing, repeated/overlapping acid, puddle escape, attack range, regeneration and player bonuses against an unmodified baseline; repeated with a custom quality tier and modded entities |

The runtime stage also compares working electric-pole grids, inserter speeds,
actual mining/resource consumption, science consumption, and seven capsule attacks
(including spawned combat robots) against the unmodified game's highest quality.
World health is checked at every quality tier, including old higher-quality objects.
Data checks protect asteroid/enemy resistances, drops, regeneration, movement and
collision properties. Missing observations, shortened attack traces and incomplete
scenarios fail validation. Eight deliberately damaged reports verify that the
checker rejects the reported enemy, asteroid, acid and ash regressions.

Use `TEST_PROFILE=quality` for Quality + Recycler without Space Age; the default
`space-age` profile enables all official expansion mods. Both profiles run in CI.
`scripts/ci-test.sh player` and `scripts/ci-test.sh exclusions` run the focused
gameplay suites. CI builds and unpacks the zip first, then tests its actual files
and dependencies. Packaging preserves existing logs and cached engine downloads.

The packaged build is also tested with and without recipes that need quality modules.
`scripts/ci-test.sh modules` checks ordinary-item conversion, rejection from module slots,
research unlocks, module production and equipment crafting, partial tier retention, recycling
and upgrade-only loops, and existing saves when useful recipes are added or removed.

The [exclusion audit](docs/quality-exclusions-audit.md) records the 1.0.2 acid slowdown
defect, its correction and the full verification scope.
The [compatibility research](docs/compatibility-validation.md) connects reports from
similar mods and the withdrawn implementation's probes to the current tests.

The baseline comparison is deliberate: an assertion like "every quality has the highest level
present" is self-referential and passes even on a mod that flattens everything to the *worst*
quality. Both tiers are negative-tested — a copy with the template selection inverted, and a
copy with the module cleanup deleted, each fail.

## Releasing

Releases are automated. Tag the version and push:

```bash
git tag v1.1.0 && git push --tags
```

`.github/workflows/release.yml` then runs the full test suite against a real headless
Factorio on the baseline and newest checked engine, with and without Space Age.
Only if both versions and profiles pass, it uploads to the mod portal, syncs the page content from
`portal.json` + `PORTAL.md`, and mirrors the zip as a GitHub release.

### New Factorio releases

[`factorio-updates.yml`](.github/workflows/factorio-updates.yml) checks the official
release metadata **hourly, at minute 17**. The normal no-change run only checks out
the repository and reads two small JSON indexes; it does not download Factorio or
run tests. The update index also catches releases missed between hourly runs.

Each new supported **2.1 experimental** release stages the next mod patch version
and tests that package on both the baseline engine and the new engine, with and
without Space Age. **When all tests pass, it automatically publishes that patch
to the mod portal and GitHub.** The upload uses the tested archive. The workflow
also archives the package, logs, JSON observations and pass/fail report as Actions
artifacts named by engine version and profile (30-day retention).

Missed experimental releases are processed one per hourly run, in version order.
Publication saves a commit and tag before uploading. A partial upload resumes
that frozen version on the next check, without allocating another patch. Changes
pushed while a candidate is being tested stop its publication and are tested on
the next run. Automatic and manual releases share a queue to avoid collisions.

[`.github/factorio-releases.json`](.github/factorio-releases.json) records the exact
source commit, mod version, result, publication status and workflow link. Published
versions are skipped. Failed validation is remembered and retried automatically
when code, tests or release tooling change, avoiding expensive repeated failures
every hour. A failed run never publishes a patch. Use **Actions → Check Factorio
releases → Run workflow**, supplying the exact engine version, to force a retry
(and publish a patch if it passes). Ordinary pushes also test the newest observed
engine, including a version that failed. New engine release lines require an
explicit compatibility update.

Manual equivalents:

```bash
FACTORIO_API_KEY=... ./publish.sh --check-key             # verify the key
FACTORIO_API_KEY=... ./publish.sh --first-publish         # first ever upload
FACTORIO_API_KEY=... ./publish.sh --sync-details          # release + page content
```

The key comes from <https://factorio.com/profile> and needs the usages *ModPortal: Upload
Mods* (plus *Publish Mods* for the very first upload and *Edit Mods* for `--sync-details`).
Store it as the `FACTORIO_API_KEY` repository secret. Note the portal has no delete API: a
published mod name is permanent.

## License

[MIT](LICENSE) — do what you like with it, no warranty of any kind.
