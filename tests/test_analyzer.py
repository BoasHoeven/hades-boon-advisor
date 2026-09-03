"""Focused checks for the read-only save and telemetry analyzer."""
import importlib.util
import struct
import sys
import tempfile
from pathlib import Path, PurePosixPath, PureWindowsPath

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "analyze_runs", ROOT / "tools" / "analyze_runs.py")
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


def luabins_string(value):
    data = value.encode("utf-8")
    return b"S" + struct.pack("<I", len(data)) + data


assert analyzer.decompress_lz4_block(b"\x50hello") == b"hello"

payload = (b"\x01T" + struct.pack("<ii", 0, 1)
           + luabins_string("answer") + b"N" + struct.pack("<d", 42.0))
decoded = analyzer.LuabinsReader(payload).tuple()
assert decoded == [{"answer": 42}]

windows_save = PureWindowsPath(
    r"C:\Users\player\Documents\Saved Games\Hades\Profile1.sav")
assert analyzer.default_telemetry_path(
    windows_save, platform="win32") == windows_save.with_name(
        "BoonAdvisor-runs.log")
unix_home = PurePosixPath("/home/player")
assert analyzer.default_telemetry_path(
    PurePosixPath("/proton/Profile1.sav"), platform="linux",
    home=unix_home) == unix_home / "BoonAdvisor-runs.log"
mac_home = PurePosixPath("/Users/player")
assert analyzer.default_telemetry_path(
    PurePosixPath("/saves/Profile1.sav"), platform="darwin",
    home=mac_home) == mac_home / "BoonAdvisor-runs.log"

# The v1.13 line shapes must still parse.
with tempfile.TemporaryDirectory() as directory:
    log = Path(directory) / "BoonAdvisor-runs.log"
    log.write_text(
        "[run-start] run=1 objective=Speed aspect=BowLoadAmmoTrait\n"
        "[offer] run=1 objective=Speed loot=AphroditeUpgrade | *Crush Shot=99(S)\n"
        "[took ] Crush Shot recommended=Crush Shot followed=true\n"
        "[run-end] run=1 objective=Speed result=clear time=900 room=D_Boss01\n",
        encoding="utf-8")
    telemetry = analyzer.analyze_telemetry(log)
    assert telemetry["offers"] == 1
    assert telemetry["choices"] == 1
    assert telemetry["follow_rate"] == 1.0
    assert telemetry["runs"][0]["result"] == "clear"

# The v1.14 per-decision log: one run with an overrule, a room outcome line
# after it, a damage spike, and stock lines for the door, Well and purge.
CTX = ("run=2 objective=Balanced weapon=BowWeapon aspect=BowMarkHomingTrait "
       "biome=Tartarus depth=%d heat=0 hp=90/100 dd=1 gold=120 rerolls=1")
LINES = [
    "=== BoonAdvisor v1.14.0 objective=Balanced ratings=1a2b3c4d channel=queued saveignores=true ===",
    "[run-start] " + CTX % 1 + " ratings=1a2b3c4d | build=none",
    "[offer] " + CTX % 2 + " loot=AresUpgrade | *TriggerCurseTrait=98(S) base=94 scarcity=12 "
    "archetype=20 | AphroditeWeaponTrait=97(S) base=84 slot=8 hit=8 archetype=10.8 | "
    "kind=boon margin=13 reason=\"completes the Chiron Merciful End build\" | "
    "reroll=unavailable | build=AresSecondaryTrait,AthenaRushTrait",
    "[took ] " + CTX % 2 + " kind=boon loot=AresUpgrade taken=AphroditeWeaponTrait score=97.2 "
    "recommended=TriggerCurseTrait best=98.1 margin=13.4 followed=false "
    "reason=\"completes the Chiron Merciful End build\"",
    "[room ] " + CTX % 2 + " room=A_Combat03 encounter=GeneratedA type=Default clear=28.5 "
    "damage_taken=10 hit=true timer=- next=Money",
    "[door ] " + CTX % 3 + " took=Money margin=12 followed=false reroll=false | *ZeusUpgrade=78 | >Money=66 | build=x",
    "[room ] " + CTX % 3 + " room=A_Combat07 encounter=GeneratedB type=Default clear=45.0 "
    "damage_taken=80 hit=true timer=- next=Shop",
    "[trial] " + CTX % 4 + " took=ZeusUpgrade margin=0 followed=true | "
    ">*ZeusUpgrade=84 | AresUpgrade=79 | build=x",
    "[well ] " + CTX % 4 + " took=KeepsakeChargeDrop margin=20 followed=false | "
    "*TemporaryImprovedWeaponTrait=74@60 | >KeepsakeChargeDrop=54@20 | build=x",
    "[purge] " + CTX % 5 + " took=ChamberGoldTrait margin=0 followed=true | "
    ">*ChamberGoldTrait=92@60 | ZeusWeaponTrait=40@60 | build=x",
    "[room ] " + CTX % 5 + " room=A_Combat09 encounter=GeneratedC type=Default clear=20.0 "
    "damage_taken=5 hit=false timer=- next=Boon",
    "[offer] " + CTX % 6 + " loot=ZeusUpgrade | *AthenaRushTrait=94(S) base=92 slot=8 | "
    "ZeusWeaponTrait=70(B) base=68 slot=8 hit=-9 | kind=boon margin=33 "
    "reason=\"fills empty Dash\" | reroll=unavailable | build=x",
    "[took ] " + CTX % 6 + " kind=boon loot=ZeusUpgrade taken=AthenaRushTrait score=94.5 "
    "recommended=AthenaRushTrait best=94.5 margin=0 followed=true reason=\"fills empty Dash\"",
    "[room ] " + CTX % 6 + " room=A_Combat11 encounter=GeneratedD type=Default clear=22.0 "
    "damage_taken=8 hit=true timer=- next=Boon",
    "[run-end] " + CTX % 7 + " result=death time=640 room=A_Boss01 killer=Megaera "
    "damage_taken=200 | build=x",
]
with tempfile.TemporaryDirectory() as directory:
    log = Path(directory) / "BoonAdvisor-runs.log"
    log.write_text("\n".join(LINES) + "\n", encoding="utf-8")
    telemetry = analyzer.analyze_telemetry(log)
    assert telemetry["sessions"][0]["fingerprint"] == "1a2b3c4d"
    assert telemetry["rooms"] == 4
    assert telemetry["wells"] == 1 and telemetry["purges"] == 1 and telemetry["trials"] == 1
    run = telemetry["runs"][0]
    assert run["result"] == "death" and run["end"]["killer"] == "Megaera"
    kinds = [d["kind"] for d in run["decisions"]]
    assert kinds == ["boon", "door", "trial", "well", "purge", "boon"], kinds
    report = telemetry["report"]
    overrules = report["overrules"]
    assert [o["kind"] for o in overrules] == ["well", "boon", "door"], \
        [(o["kind"], o["margin"]) for o in overrules]
    boon_overrule = next(o for o in overrules if o["kind"] == "boon")
    assert boon_overrule["taken"] == "AphroditeWeaponTrait"
    assert boon_overrule["recommended"] == "TriggerCurseTrait"
    assert abs(boon_overrule["margin"] - 13.4) < 1e-9
    assert boon_overrule["reason"] == "completes the Chiron Merciful End build"
    assert boon_overrule["terms"]["scarcity"] == 12
    # The rooms after the overrule took more damage than the run's median.
    assert boon_overrule["aftermath"]["rooms"] == 3
    assert boon_overrule["aftermath"]["damage_delta"] > 0
    assert report["per_kind"]["boon"]["decisions"] == 2
    assert report["per_kind"]["boon"]["follow_rate"] == 0.5
    assert report["reason_frequency"][0]["reason"] == "completes the Chiron Merciful End build"
    terms = report["term_averages"]
    assert terms["scarcity"]["overruled_mean"] == 12 and terms["scarcity"]["followed_n"] == 0
    spikes = report["damage_spikes"]
    assert spikes and spikes[0]["room"] == "A_Combat07" and spikes[0]["damage"] == 80
    assert [d["kind"] for d in spikes[0]["decisions"]] == ["boon", "door"]
    # Too few runs: no clear-rate comparison is printed as a number.
    assert report["run_buckets"]["mostly_not_followed"]["clear_rate"] is None
    # The printed report must not crash on this data.
    import contextlib, io
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        analyzer.print_decision_report(telemetry)
    text = buffer.getvalue()
    assert "Overrules by margin" in text and "AphroditeWeaponTrait" in text
    assert "Damage-spike rooms" in text and "A_Combat07" in text
    assert "too few runs" in text

save = analyzer.default_save_path()
if save.is_file():
    header, globals_table = analyzer.read_save(save)
    assert header["checksum_valid"]
    assert "GameState" in globals_table

print("analyzer checks passed")
