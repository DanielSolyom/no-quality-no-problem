# Repository instructions

- Keep `README.md` brief and for players. Do not add developer/project documentation
  or a `docs/` directory; keep essential agent instructions here.
- `no-quality-no-problem/` is the mod source and the only directory packaged.
  `PORTAL.md` and `portal.json` supply the published mod page.
- Preserve the highest quality's factory/player bonuses and normal enemy/world stats.
  Quality modules needed by useful recipes become inert ordinary items automatically;
  recycling and module-only recipes must not trigger retention.
- Keep temporary compatibility fixtures in the test environment, outside the release
  ZIP and the mod's dependency manifest. Tests must not touch real saves or installed mods.

Run the relevant code/tooling checks:

```bash
luacheck .
python3 -m unittest discover -s tests -v
bash -n build.sh publish.sh scripts/*.sh
```

For gameplay or packaging changes, run `FACTORIO_BIN=/path/to/factorio ./build.sh --test`.
It validates the actual ZIP with both Quality-only and Space Age profiles by default.

CI on `main` handles the patch version, changelog, tag and publication of the tested ZIP.
Use that workflow for releases instead of manually bumping versions, tagging or rebuilding.
Let in-flight CI releases finish; do not cancel them when requirements change.
Hourly checks publish a tested patch for each new supported Factorio version, stable or
experimental, even when gameplay code is unchanged. Promotion of a previously checked
experimental version to stable gets another release; publication retries reuse the same
mod version and tag. Test only the target engine for compatibility releases and the newest
tracked engine in main CI, with both Quality-only and Space Age profiles; do not add a
fixed legacy engine to the matrix.
