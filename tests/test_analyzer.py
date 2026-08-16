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

save = analyzer.default_save_path()
if save.is_file():
    header, globals_table = analyzer.read_save(save)
    assert header["checksum_valid"]
    assert "GameState" in globals_table

print("analyzer checks passed")
