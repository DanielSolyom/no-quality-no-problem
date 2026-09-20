# Compatibility research and regression coverage — 2026-09-20

The shipping mod retains the 1.0.3 data-stage implementation. Version 1.0.4 is a
reissue of that code to replace the portal dependency metadata left by the deleted
2.0.0 release. No generator, static prototype compiler, or runtime entity-replacement
system is part of this change.

## Reports from similar mods

These are firsthand reports and maintainer changelogs, used to choose tests.
Reports about older Factorio versions are not assumed to reproduce on 2.1; the
tests compare two runs of the same current engine instead of copying old fixes.

| Source | Pitfall | Validation here |
| --- | --- | --- |
| [Legendary Normal: 1.0.4 changelog](https://mods.factorio.com/mod/legendarynormal/changelog) | The maintainer replaced runtime enemy replacement with data-stage compensation and fixed pentapods, demolishers, asteroid health and acid damage. | Every unit/spider-unit/segmented-unit/worm variant is discovered from runtime prototypes; actual enemy attacks, asteroid impacts, acid/ash damage and slowing are compared with normal-quality baselines. |
| [Legendary Normal: asteroid report](https://mods.factorio.com/mod/legendarynormal/discussion/6870f88846888dfb4b49044e) and [demolisher/asteroid report](https://mods.factorio.com/mod/legendarynormal/discussion/699b2b03f2cd10e9b530a7b4) | An enemy-only exclusion misses asteroids. A proposed resistance change could also alter which weapons work against them. | All four sizes and four materials are tested as real entities and space-platform collisions. Resistance, collision and drop definitions must remain unchanged. |
| [Legendary Quality 4 All: legendary enemies](https://mods.factorio.com/mod/LegendaryQualityForAll/discussion/690aa778da6f4fd8de407da9) | Boosted enemies can look acceptable early and become a problem at behemoth tier. | All enemy sizes are included, with health checked at every quality, not just small normal-quality biters. |
| [Legendary Quality 4 All: drills and inserters](https://mods.factorio.com/mod/LegendaryQualityForAll/discussion/680791bddf1e9656f2bb0c7e) | Matching a quality level does not prove that resource drain, science or inserters get their expected bonuses. | Actual resource depletion and output, actual research/science consumption, and engine-reported inserter speeds must match the baseline's best quality. |
| [Legendary Everything: negative quality from speed modules](https://mods.factorio.com/mod/LegendaryEverything/discussion/689835ecd9c7b8e654bb8e0a) | Adding a large quality chance still interacts with negative quality effects from speed modules. | Existing module cleanup remains tested: remove quality effects while retaining useful speed/productivity/efficiency effects; hidden penalty-only modules must be inert. |
| [Legendary Factory changelog](https://mods.factorio.com/mod/Legendary_Factory/changelog) | Space-platform placement and loading without Space Age needed separate fixes. | Run the packaged mod with Quality + Recycler alone and with all official expansion content. World tests create real space platforms and collide asteroids with structures. |
| [Legendary Quality 4 All: Factorissimo report](https://mods.factorio.com/mod/LegendaryQualityForAll/discussion/68250a702b5cd2cc7b207388) and [Legendary Normal: modded entities](https://mods.factorio.com/mod/legendarynormal/discussion/69c6e535981aeef966527178) | Scripted quality mechanics, load order and mod-added prototypes can bypass a generic stat adjustment. | The custom tier/enemy/asteroid/acid fixture guards against hardcoded vanilla multipliers and names. This does not establish compatibility with those third-party mods; their scripted behavior needs separate integration tests. |

## Lessons retained from the withdrawn implementation

The previous build's gameplay probes and local incident investigation were reviewed
from `backup/before-v1.0.3-reset-20260920` and the saved `.build/incident` artifacts.
The useful checks are now plain Lua scenarios alongside the existing test runner:

- Electric poles must power real lamps inside their supply area and leave lamps
  outside it unpowered. Reading a radius alone does not establish power delivery.
- Capsule attacks must travel through their original projectile/effect chain.
  Defender, distractor and destroyer cases must spawn robots and deal damage.
  Robot health, damage observations and player slow/poison effects are compared
  against the unmodified game's best-quality result.
- Mining and science checks must exercise consumption. Merely reporting a
  multiplier is insufficient, especially where the engine rounds quantities.
- A missing prototype, attack, result section, or unfinished benchmark must not
  make a comparison pass. Numeric measurements cannot be booleans or NaN.
- Packaging must preserve `.build` caches and diagnostic evidence. CI tests the
  unpacked release zip without rewriting its dependency manifest.

These are regression risks, not claims that every observed player issue had the
same cause. The recorded pole measurements in the old incident investigation, for
example, matched its reference; the permanent test protects that behavior.

## Validation results

Factorio **2.1.17** and **2.1.19** pass the expanded scenarios with the 1.0.4 Lua
code, which is byte-for-byte identical to 1.0.3. The Space Age cases include:

| Coverage | Vanilla | Custom tier fixture |
| --- | ---: | ---: |
| World entity health, at every quality | 212 | 214 |
| Asteroid types, including collisions | 16 | 17 |
| Combat and range cases | 56 | 58 |
| 320-tick movement/vehicle traces | 37 | 38 |
| Smoke lifetimes | 103 | 103 |
| Fire/puddle lifetimes | 13 | 13 |

The player scenario covers four powered pole grids, six inserter prototypes,
four working drills, science consumption and seven capsule attacks. Without Space
Age there are five inserters and three drills; the other player cases remain.
Data-stage checks also compare 188 Space Age world prototypes' resistance, loot,
mining, regeneration, movement, spawn and collision definitions (48 without Space Age).

The actual released **1.0.2** was loaded in separate isolated directories and is
rejected by the new suite. Its movement traces differ in 24 vanilla cases and 25
custom-tier cases. Small acid changes initial walking speed from about 0.09 to
zero in vanilla, and to about -0.09 with the custom tier. The 1.0.3/1.0.4 traces
match the baseline instead. No personal save or installed mod was modified.

Eight report mutations additionally prove rejection of boosted asteroid health,
boosted enemy health, boosted acid damage, immobilisation, missing combat cases,
truncated acid pulses, extended ash duration and incomplete runs. These mutations
test the validator; they do not substitute for the actual engine runs above.

## Continuous checks

The hourly detector uses Factorio's official
[latest-release endpoint](https://factorio.com/api/latest-releases) and
[headless update index](https://updater.factorio.com/get-available-versions).
The [Factorio download API documentation](https://wiki.factorio.com/Download_API)
describes metadata polling rather than downloading the game to discover its version.

The detector tracks both stable and experimental releases within the supported
2.1 line and catches up missed versions numerically. A new release triggers the
same packaged-mod validation as normal CI and tagged releases. Pass/fail state is
stored in git with the source commit and workflow link; malformed responses or
missing test evidence fail the job. Failed versions require a manual retry rather
than consuming full engine-test runs every hour.

The state commit uses `GITHUB_TOKEN`, whose pushes
[do not recursively trigger other push workflows](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow#triggering-a-workflow-from-a-workflow).
Compatibility builds are archived as Actions artifacts. Mod portal releases remain
tag-triggered and require both profiles and both engine versions to pass.

## Boundaries

The suite exercises the real headless engine, not the graphical quality selectors.
Headless capsule tests use a fixture that exposes the unchanged capsule attack as
a gun/ammo pair; they do not simulate a connected player's GUI interaction.
It does not certify arbitrary third-party scripted mechanics, pre-existing saves
from the withdrawn architecture, or future entity types. Enemy effects added by
mods under unrelated names still need explicit exclusion support and tests.
Custom quality multipliers can also require fractional enemy-effect durations;
the existing implementation rounds those down to whole prototype ticks.
