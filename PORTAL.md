Quality, gone. Legendary, everywhere.

This mod does two things at once:

* **Removes the quality mechanic.** No quality badges on items, no quality selector in
  recipe/filter/logistic GUIs, no quality modules, no quality technologies, no quality
  entries in Factoriopedia. The interface goes back to exactly what it looked like before
  you researched quality.
* **Makes everything legendary.** Every item, machine, building and piece of equipment has
  full legendary stats — assembler speed, module slots, accumulator capacity, beacon
  efficiency, mining drill drain, roboport range, the lot. Nothing is a "normal" version of
  itself any more.

## Why both halves

If you turn quality off and nothing else changes, your factory is quietly weaker than
everyone else's for the rest of the run. If you make everything legendary and leave the
quality mechanic in, you still click through quality selectors you will never use. This mod
does both, so you can play Space Age without quality *and* without falling behind.

## How it works

It rewrites the quality prototypes in `data-final-fixes`: every quality is flattened onto
the stats of the highest-level one, then all of them are hidden the same way the base game
already hides "normal". There are no per-item lists anywhere in the mod. That means:

* it works with any mod set, including mods that add their own quality tiers or new
  machines;
* it keeps working when the base game adds new quality multipliers, with no mod update
  needed.

Quality modules lose their quality effect and are hidden; modded hybrid modules that also
do something else keep their other effects. Speed modules keep working — only their quality
penalty is removed. Quality-only technologies are hidden and spliced out of other
technologies' prerequisites, so the tech tree stays connected.

## Notes

* Requires the Quality mod to be enabled — it works by rewriting quality, not by turning it
  off. (In Factorio 2.1 you *can* simply disable the Quality mod, but then everything is
  normal quality. This mod is the other option: quality invisible, legendary stats.)
* Safe to add to an existing save. Items you already have at a non-normal quality keep their
  (now identical) stats, but items of different qualities still do not stack.
* Removing the mod restores the quality mechanic, since everything it changes is
  prototype-level.
