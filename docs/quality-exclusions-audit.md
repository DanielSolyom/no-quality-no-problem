# Quality exclusion audit — 2026-09-20

The reported acid immobilisation is reproducible in Factorio 2.1.19 with only
the official mods and No Quality, No Problem 1.0.2 enabled. Information mods
are not required to trigger it.

## Confirmed defect and correction

Version 1.0.2 preserved an enemy sticker's effective lifetime by shortening its
prototype duration before normal quality received legendary multipliers.
However, the engine interpolates changing movement modifiers against the
unscaled prototype duration. Restoring the lifetime without also correcting
the interpolation extrapolates beyond the intended starting slowdown.

These are measured initial speeds, expressed as a percentage of the same
unaffected character's speed:

| Acid effect | Unmodified normal | Mod 1.0.2 | Corrected 1.0.3 |
| --- | ---: | ---: | ---: |
| Small spitter/worm | 60% | 0% | 60% |
| Medium spitter/worm | 50% | -25% | 50% |
| Big spitter/worm | 40% | -50% | 40% |
| Behemoth spitter/worm | 30% | -75% | 30% |
| Stomper, each size | 60% | 0% | 60% |

Repeated contact refreshes the sticker, keeping the incorrect starting value
active. This explains being unable to walk out of a puddle. The same issue
affects interpolated vehicle speed and friction. Constant effects such as
demolisher ash do not have this interpolation defect.

Version 1.0.3 scales the difference between each modifier's starting and ending
values by the change in prototype duration. This preserves the complete
movement recovery curve as well as the lifetime. The correction also covers
interpolated character and vehicle speed limits. Player effects retain the
unmodified game's best-quality behavior.

## Verification

Both Factorio 2.1.19 (the reported version) and the CI-pinned 2.1.17 pass
`scripts/ci-test.sh all`. Each comparison uses a separate run with this mod
disabled as its reference, with the same official expansion content enabled.

| Coverage per engine version | Vanilla | Custom quality fixture |
| --- | ---: | ---: |
| World entity health comparisons | 212 | 214 |
| Asteroid variants, including actual space-platform collisions | 16 | 17 |
| Combat, collision and attack-range cases | 56 | 58 |
| Movement and vehicle traces, 320 ticks each | 37 | 38 |
| Smoke lifetime comparisons | 103 | 103 |
| Complete puddle/fire lifetime comparisons | 13 | 13 |

Combat cases include every biter, spitter, worm, wriggler, strafer, stomper and
demolisher size, nest acid, demolisher ash, lightning and crash-site fires.
Movement cases include isolated effects, repeated hits, mixed acid types,
walking out of every spitter/worm/stomper puddle, vehicle modifiers, and player
weapon/food effects at the baseline's best quality. Regeneration, world-object
inventories, natural lightning attractors and factory/player bonuses are also
checked.

The custom fixture uses a level-7 quality with explicit 4x stat and 1.8x range
multipliers. It adds an enemy, an asteroid with default health, and an acid
sticker with changing speed limits and non-default ending modifiers.

Additional checks on 2.1.19:

- The released 1.0.2 package fails 24 of the new movement cases.
- A save created under 1.0.2 with active acid effects passes all 37 movement
  cases after loading it with 1.0.3. No save reset or runtime migration is needed.
- Lua lint reports zero warnings/errors; Lua, shell and Python syntax checks pass.

No further differences were found in the tested world stats, attacks, collision
damage or hazard lifetimes. Mixed acid types still stack strongly in the
unmodified game; the correction preserves that behavior. Unusual gameplay mods
and future engine changes are outside this audit. Fractional durations from
custom quality multipliers still round down to whole prototype ticks, as
documented in the README.
