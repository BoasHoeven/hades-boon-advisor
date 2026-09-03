# Tests

The suite runs the **real mod sources** from `../mod` in Lua 5.2, the version
Hades uses, against the **real** `TraitData.lua`, `LootData.lua` and
`MetaUpgradeData.lua` from your install. Only per-run state and the engine's
drawing calls are stubbed, so the duo graph, exclusion rules, curse effects and
all scoring logic under test are genuine.

```bash
pip install lupa
python tests/test_boonadvisor.py
```

Hades is found automatically; override with `HADES_PATH=/path/to/Hades`.

| Script | What it does |
| --- | --- |
| `test_boonadvisor.py` | 100+ assertions across scoring, exclusions, the Mirror, doors, shop, the Well, keepsakes, telemetry, save safety |
| `oracle.lua` | The high-sample sampling oracle the differential tests compare the exact forecasts against. Loaded by the harness after the mod; not part of the mod |
| `validate_aspects.py` | Checks all 24 aspects steer toward their configured archetype |
| `exhaustive_offers.py` | Scores every legal installed-game candidate for all 24 aspects and all three objectives |
| `test_analyzer.py` | Checks the read-only save decoder and telemetry parser |
| `test_performance.py` | Guards latency, cache invalidation, zero live generator calls, and exact forecasts against high-sample oracles |
| `analyse_mismatches.py` | Flags ratings that disagree with the duo graph |
| `simulate_runs.py` | Plays runs following the advice vs random, and compares duo paths unlocked |

The documented route regressions are stored in `build_benchmarks.json`. They
use the Hades Guides Compendium and Lee Reamsnyder's all-aspect guide as source
material. They verify that the advisor recognizes established routes; they are
not presented as measured win rates.

Run the complete deterministic checks with:

```bash
python tests/test_boonadvisor.py
python tests/test_performance.py
python tests/exhaustive_offers.py
python tests/test_analyzer.py
```

## Why some checks look paranoid

Several exist because the same class of bug shipped more than once:

- **Every name is asserted against real game data.** A wrong trait or Mirror key
  is not an error in Lua. It silently never matches. `"EffectVulnerability"`
  looked right (it *is* the icon name) but the real key is
  `VulnerabilityEffectBonusMetaUpgrade`, so all Mirror awareness sat dead.
- **The save-safety check has a canary**, because a test that cannot fail proves
  nothing.
- **Pick logging is asserted to reach a file**, not just to call `DebugPrint`,
  whose output never reaches `Hades.log` in the release build. Asserting on the
  stub would have passed while nothing was written.
