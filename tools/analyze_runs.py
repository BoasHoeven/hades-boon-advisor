"""Read-only Hades save and BoonAdvisor telemetry analysis.

This parser follows the documented Supergiant save header, raw LZ4 block, and
Luabins value format. It opens saves only in binary read mode and never writes
to them. Historical saves contain final run builds, not the offers that were
shown, so save backtests are correlation checks. Exact recommendation follow
rates come from BoonAdvisor-runs.log.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import struct
import sys
import zlib
from collections import Counter, defaultdict
from pathlib import Path


MAGIC = 0x31424753
MAX_DECOMPRESSED = 32 * 1024 * 1024


class SaveFormatError(ValueError):
    pass


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, size: int) -> bytes:
        if size < 0 or self.pos + size > len(self.data):
            raise SaveFormatError("unexpected end of data at byte %d" % self.pos)
        value = self.data[self.pos:self.pos + size]
        self.pos += size
        return value

    def unpack(self, fmt: str):
        size = struct.calcsize(fmt)
        return struct.unpack(fmt, self.take(size))[0]

    def string_bytes(self) -> bytes:
        size = self.unpack("<I")
        return self.take(size)

    def string(self) -> str:
        return self.string_bytes().decode("utf-8", errors="replace")


def decompress_lz4_block(data: bytes) -> bytes:
    """Decode the raw LZ4 block stored by Hades without external packages."""
    source = 0
    output = bytearray()
    while source < len(data):
        token = data[source]
        source += 1

        literal_length = token >> 4
        if literal_length == 15:
            while True:
                if source >= len(data):
                    raise SaveFormatError("truncated LZ4 literal length")
                extra = data[source]
                source += 1
                literal_length += extra
                if extra != 255:
                    break
        if source + literal_length > len(data):
            raise SaveFormatError("truncated LZ4 literals")
        if len(output) + literal_length > MAX_DECOMPRESSED:
            raise SaveFormatError("decompressed save exceeds safety limit")
        output.extend(data[source:source + literal_length])
        source += literal_length
        if source == len(data):
            break

        if source + 2 > len(data):
            raise SaveFormatError("truncated LZ4 match offset")
        offset = data[source] | (data[source + 1] << 8)
        source += 2
        if offset == 0 or offset > len(output):
            raise SaveFormatError("invalid LZ4 match offset")

        match_length = token & 0x0F
        if match_length == 15:
            while True:
                if source >= len(data):
                    raise SaveFormatError("truncated LZ4 match length")
                extra = data[source]
                source += 1
                match_length += extra
                if extra != 255:
                    break
        match_length += 4
        # Enforce the limit before materializing: a corrupt length extension
        # could otherwise expand a small file by ~255x into memory first.
        if len(output) + match_length > MAX_DECOMPRESSED:
            raise SaveFormatError("decompressed save exceeds safety limit")
        for _ in range(match_length):
            output.append(output[-offset])
    return bytes(output)


class LuabinsReader(Reader):
    def value(self, depth: int = 0):
        if depth > 250:
            raise SaveFormatError("Luabins table nesting is too deep")
        tag = self.take(1)
        if tag == b"-":
            return None
        if tag == b"0":
            return False
        if tag == b"1":
            return True
        if tag == b"N":
            number = self.unpack("<d")
            if math.isfinite(number) and number.is_integer():
                return int(number)
            return number
        if tag == b"S":
            return self.string()
        if tag == b"T":
            array_size = self.unpack("<i")
            hash_size = self.unpack("<i")
            total = array_size + hash_size
            if array_size < 0 or hash_size < 0 or total > 10_000_000:
                raise SaveFormatError("invalid Luabins table size")
            table = {}
            for _ in range(total):
                key = self.value(depth + 1)
                value = self.value(depth + 1)
                if key is None:
                    raise SaveFormatError("nil Luabins table key")
                table[key] = value
            return table
        raise SaveFormatError("unknown Luabins tag %r at byte %d" %
                              (tag, self.pos - 1))

    def tuple(self):
        count = self.unpack("<B")
        if count > 250:
            raise SaveFormatError("invalid Luabins tuple size")
        values = [self.value() for _ in range(count)]
        if self.pos != len(self.data):
            raise SaveFormatError("%d unread Luabins bytes" %
                                  (len(self.data) - self.pos))
        return values


def read_save(path: Path):
    raw = path.read_bytes()
    reader = Reader(raw)
    header = {
        "magic": reader.unpack("<I"),
        "checksum": reader.unpack("<I"),
        "game_version": reader.unpack("<H"),
        "save_flags": reader.unpack("<H"),
        "timestamp": reader.unpack("<Q"),
        "location": reader.string(),
        "completed_runs": reader.unpack("<I"),
        "accumulated_meta_points": reader.unpack("<I"),
        "active_shrine_points": reader.unpack("<I"),
    }
    if header["magic"] != MAGIC:
        raise SaveFormatError("not a Hades save (magic %08X)" % header["magic"])
    if header["game_version"] != 0x10:
        raise SaveFormatError("expected Hades 1 save version 0x10, got 0x%X" %
                              header["game_version"])
    header["easy_mode"] = bool(reader.unpack("<B"))
    header["hard_mode"] = bool(reader.unpack("<B"))
    notable_count = reader.unpack("<I")
    if notable_count > 100_000:
        raise SaveFormatError("invalid notable-data count")
    header["notable_lua_data"] = [reader.string() for _ in range(notable_count)]
    header["map_name"] = reader.string()
    header["map_name_2"] = reader.string()
    compressed = reader.string_bytes()
    if reader.pos != len(raw):
        raise SaveFormatError("%d trailing save bytes" % (len(raw) - reader.pos))
    header["checksum_valid"] = (zlib.adler32(raw[8:]) & 0xFFFFFFFF) == header["checksum"]
    decoded = decompress_lz4_block(compressed)
    values = LuabinsReader(decoded).tuple()
    if len(values) != 1 or not isinstance(values[0], dict):
        raise SaveFormatError("expected one global save table")
    return header, values[0]


ASPECT_NAMES = {
    "SwordBaseUpgradeTrait": "Zagreus Blade",
    "SwordCriticalParryTrait": "Nemesis Blade",
    "DislodgeAmmoTrait": "Poseidon Blade",
    "SwordConsecrationTrait": "Arthur Blade",
    "SpearBaseUpgradeTrait": "Zagreus Spear",
    "SpearTeleportTrait": "Achilles Spear",
    "SpearWeaveTrait": "Hades Spear",
    "SpearSpinTravel": "Guan Yu Spear",
    "ShieldBaseUpgradeTrait": "Zagreus Shield",
    "ShieldRushBonusProjectileTrait": "Chaos Shield",
    "ShieldTwoShieldTrait": "Zeus Shield",
    "ShieldLoadAmmoTrait": "Beowulf Shield",
    "BowBaseUpgradeTrait": "Zagreus Bow",
    "BowMarkHomingTrait": "Chiron Bow",
    "BowLoadAmmoTrait": "Hera Bow",
    "BowBondTrait": "Rama Bow",
    "FistBaseUpgradeTrait": "Zagreus Fists",
    "FistVacuumTrait": "Talos Fists",
    "FistWeaveTrait": "Demeter Fists",
    "FistDetonateTrait": "Gilgamesh Fists",
    "GunBaseUpgradeTrait": "Zagreus Rail",
    "GunGrenadeSelfEmpowerTrait": "Eris Rail",
    "GunManualReloadTrait": "Hestia Rail",
    "GunLoadedGrenadeTrait": "Lucifer Rail",
}


def ordered_values(table):
    if not isinstance(table, dict):
        return []
    numeric = [(key, value) for key, value in table.items()
               if isinstance(key, int)]
    return [value for _, value in sorted(numeric)]


def run_traits(run):
    cache = run.get("TraitCache", {}) if isinstance(run, dict) else {}
    return {str(name) for name, count in cache.items() if count}


def run_aspect(run):
    traits = run_traits(run)
    found = next((name for name in ASPECT_NAMES if name in traits), None)
    if found is not None:
        return found
    weapon_to_base = {
        "SwordWeapon": "SwordBaseUpgradeTrait",
        "SpearWeapon": "SpearBaseUpgradeTrait",
        "ShieldWeapon": "ShieldBaseUpgradeTrait",
        "BowWeapon": "BowBaseUpgradeTrait",
        "FistWeapon": "FistBaseUpgradeTrait",
        "GunWeapon": "GunBaseUpgradeTrait",
    }
    weapons = run.get("WeaponsCache", {}) if isinstance(run, dict) else {}
    return next((base for weapon, base in weapon_to_base.items()
                 if weapons.get(weapon)), "Unknown")


def format_time(seconds):
    if not isinstance(seconds, (int, float)):
        return "n/a"
    minutes, secs = divmod(int(round(seconds)), 60)
    return "%d:%02d" % (minutes, secs)


def load_benchmarks(path: Path | None):
    if path is None or not path.is_file():
        return []
    with path.open(encoding="utf-8") as handle:
        return json.load(handle).get("routes", [])


def route_progress(route, traits):
    targets = list(route.get("required", []))
    required_any = route.get("required_any", [])
    if required_any:
        targets.append(next((name for name in required_any if name in traits),
                            required_any[0]))
    payoff = route.get("payoff")
    if payoff:
        targets.append(payoff)
    if not targets:
        return 0.0, False
    hits = sum(name in traits for name in targets)
    core = all(name in traits for name in route.get("required", []))
    if required_any:
        core = core and any(name in traits for name in required_any)
    return hits / len(targets), core


def analyze_history(game_state, benchmarks):
    history = ordered_values(game_state.get("RunHistory", {}))
    rows = []
    routes_by_aspect = defaultdict(list)
    for route in benchmarks:
        routes_by_aspect[route.get("aspect")].append(route)

    for index, run in enumerate(history, 1):
        if not isinstance(run, dict):
            continue
        traits = run_traits(run)
        aspect = run_aspect(run)
        route_rows = []
        for route in routes_by_aspect.get(aspect, []):
            progress, core = route_progress(route, traits)
            route_rows.append({"id": route["id"], "progress": progress,
                               "core_present": core})
        rows.append({
            "run": index,
            "cleared": bool(run.get("Cleared")),
            "time": run.get("GameplayTime"),
            "heat": run.get("ShrinePointsCache", 0),
            "aspect": aspect,
            "aspect_name": ASPECT_NAMES.get(aspect, aspect),
            "traits": sorted(traits),
            "routes": route_rows,
        })

    aspect_stats = []
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["aspect"]].append(row)
    for aspect, group in grouped.items():
        clears = [row for row in group if row["cleared"]]
        times = [row["time"] for row in clears
                 if isinstance(row["time"], (int, float))]
        aspect_stats.append({
            "aspect": aspect,
            "name": ASPECT_NAMES.get(aspect, aspect),
            "runs": len(group),
            "clears": len(clears),
            "clear_rate": len(clears) / len(group) if group else 0,
            "median_clear_time": statistics.median(times) if times else None,
            "best_clear_time": min(times) if times else None,
        })
    aspect_stats.sort(key=lambda item: (-item["runs"], item["name"]))

    route_stats = []
    for route in benchmarks:
        matching = [row for row in rows if row["aspect"] == route["aspect"]]
        with_core = []
        without_core = []
        for row in matching:
            data = next((item for item in row["routes"] if item["id"] == route["id"]), None)
            (with_core if data and data["core_present"] else without_core).append(row)

        def summary(group):
            clears = [row for row in group if row["cleared"]]
            times = [row["time"] for row in clears
                     if isinstance(row["time"], (int, float))]
            return {"runs": len(group), "clears": len(clears),
                    "clear_rate": len(clears) / len(group) if group else None,
                    "median_clear_time": statistics.median(times) if times else None}

        route_stats.append({"id": route["id"], "name": route["name"],
                            "with_core": summary(with_core),
                            "without_core": summary(without_core)})

    clears = [row for row in rows if row["cleared"]]
    clear_times = [row["time"] for row in clears
                   if isinstance(row["time"], (int, float))]
    return {
        "runs": rows,
        "summary": {
            "recorded_runs": len(rows),
            "clears": len(clears),
            "clear_rate": len(clears) / len(rows) if rows else 0,
            "median_clear_time": statistics.median(clear_times) if clear_times else None,
            "best_clear_time": min(clear_times) if clear_times else None,
        },
        "aspects": aspect_stats,
        "routes": route_stats,
    }


TOOK_RE = re.compile(r"^\[took \]\s+(.*?)\s+recommended=(.*?)\s+followed=(true|false)\s*$")
FIELD_RE = re.compile(r"(?:^|\s)([A-Za-z][A-Za-z0-9_-]*)=([^\s|]+)")


def analyze_telemetry(path: Path):
    result = {"present": path.is_file(), "path": str(path), "lines": 0,
              "offers": 0, "choices": 0, "followed": 0, "rerolls": 0,
              "doors": 0, "shops": 0, "story": 0, "decisions": 0,
              "followed_decisions": 0, "runs": []}
    if not path.is_file():
        return result
    current = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            result["lines"] += 1
            fields = dict(FIELD_RE.findall(line))
            if line.startswith("[run-start]"):
                current = {"offers": 0, "choices": 0, "followed": 0,
                           "decisions": 0, "followed_decisions": 0,
                           "rerolls": 0, "context": fields}
            elif line.startswith("[offer]"):
                result["offers"] += 1
                if current is not None:
                    current["offers"] += 1
            elif line.startswith("[took ]"):
                result["choices"] += 1
                match = TOOK_RE.match(line)
                followed = bool(match and match.group(3) == "true")
                result["followed"] += int(followed)
                result["decisions"] += 1
                result["followed_decisions"] += int(followed)
                if current is not None:
                    current["choices"] += 1
                    current["followed"] += int(followed)
                    current["decisions"] += 1
                    current["followed_decisions"] += int(followed)
            elif line.startswith("[reroll]"):
                result["rerolls"] += 1
                if current is not None:
                    current["rerolls"] += 1
            elif line.startswith("[door ]"):
                result["doors"] += 1
                followed = ">*" in line
                result["decisions"] += 1
                result["followed_decisions"] += int(followed)
                if current is not None:
                    current["decisions"] += 1
                    current["followed_decisions"] += int(followed)
            elif line.startswith("[shop ]"):
                result["shops"] += 1
                followed = ">*" in line
                result["decisions"] += 1
                result["followed_decisions"] += int(followed)
                if current is not None:
                    current["decisions"] += 1
                    current["followed_decisions"] += int(followed)
            elif line.startswith("[story]"):
                result["story"] += 1
                followed = fields.get("followed") == "true"
                result["decisions"] += 1
                result["followed_decisions"] += int(followed)
                if current is not None:
                    current["decisions"] += 1
                    current["followed_decisions"] += int(followed)
            elif line.startswith("[run-end]"):
                if current is None:
                    current = {"offers": 0, "choices": 0, "followed": 0,
                               "decisions": 0, "followed_decisions": 0,
                               "rerolls": 0, "context": {}}
                current["result"] = fields.get("result")
                try:
                    current["time"] = float(fields["time"])
                except (KeyError, ValueError):
                    current["time"] = None
                current["end"] = fields
                result["runs"].append(current)
                current = None
    if current is not None and any(current[key] for key in
                                   ("offers", "choices", "decisions", "rerolls")):
        current["result"] = "incomplete"
        current["time"] = None
        result["runs"].append(current)
    result["follow_rate"] = (result["followed"] / result["choices"]
                             if result["choices"] else None)
    result["all_decision_follow_rate"] = (
        result["followed_decisions"] / result["decisions"]
        if result["decisions"] else None)
    for followed in (True, False):
        group = [run for run in result["runs"] if run["decisions"] and
                 (run["followed_decisions"] / run["decisions"] >= 0.5) == followed]
        clears = [run for run in group if run.get("result") == "clear"]
        times = [run["time"] for run in clears if run.get("time") is not None]
        result["mostly_followed" if followed else "mostly_not_followed"] = {
            "runs": len(group), "clears": len(clears),
            "clear_rate": len(clears) / len(group) if group else None,
            "median_clear_time": statistics.median(times) if times else None,
        }
    objective_groups = defaultdict(list)
    for run in result["runs"]:
        objective_groups[run.get("context", {}).get("objective", "Unknown")].append(run)
    result["objectives"] = {}
    for objective, group in objective_groups.items():
        clears = [run for run in group if run.get("result") == "clear"]
        times = [run["time"] for run in clears if run.get("time") is not None]
        decisions = sum(run["decisions"] for run in group)
        followed_count = sum(run["followed_decisions"] for run in group)
        result["objectives"][objective] = {
            "runs": len(group), "clears": len(clears),
            "clear_rate": len(clears) / len(group) if group else None,
            "median_clear_time": statistics.median(times) if times else None,
            "follow_rate": followed_count / decisions if decisions else None,
        }
    return result


def print_report(report):
    header = report["save_header"]
    history = report["history"]
    summary = history["summary"]
    print("Hades save: %s" % report["save_path"])
    print("Checksum: %s | header attempts: %s | stored history: %s" %
          ("valid" if header["checksum_valid"] else "INVALID",
           header["completed_runs"], summary["recorded_runs"]))
    print("Clears: %d/%d (%.1f%%) | median: %s | best: %s" %
          (summary["clears"], summary["recorded_runs"],
           100 * summary["clear_rate"], format_time(summary["median_clear_time"]),
           format_time(summary["best_clear_time"])))

    print("\nMost-played aspects")
    for item in history["aspects"][:10]:
        print("  %-22s %3d runs  %3d clears  %5.1f%%  median %s" %
              (item["name"], item["runs"], item["clears"],
               100 * item["clear_rate"], format_time(item["median_clear_time"])))

    usable_routes = [item for item in history["routes"]
                     if item["with_core"]["runs"] or item["without_core"]["runs"]]
    if usable_routes:
        print("\nHistorical benchmark routes (final-build correlation only)")
        for item in usable_routes:
            yes, no = item["with_core"], item["without_core"]
            yes_rate = "n/a" if yes["clear_rate"] is None else "%.0f%%" % (100 * yes["clear_rate"])
            no_rate = "n/a" if no["clear_rate"] is None else "%.0f%%" % (100 * no["clear_rate"])
            print("  %-30s core %2d runs/%4s, other %2d runs/%4s" %
                  (item["name"], yes["runs"], yes_rate, no["runs"], no_rate))

    telemetry = report["telemetry"]
    print("\nTelemetry: %s" % telemetry["path"])
    if not telemetry["present"]:
        print("  No log yet. The analyzer is ready for the next run.")
    else:
        boon_follow = "n/a" if telemetry["follow_rate"] is None else "%.1f%%" % (100 * telemetry["follow_rate"])
        all_follow = ("n/a" if telemetry["all_decision_follow_rate"] is None
                      else "%.1f%%" % (100 * telemetry["all_decision_follow_rate"]))
        print("  %d offers, %d boon choices, boon follow %s, all decisions %s, %d run records" %
              (telemetry["offers"], telemetry["choices"], boon_follow, all_follow,
               len(telemetry["runs"])))


def default_save_path():
    if sys.platform == "darwin":
        return (Path.home() / "Library" / "Application Support"
                / "Supergiant Games" / "Hades" / "Profile1.sav")
    if sys.platform.startswith("win"):
        return Path.home() / "Documents" / "Saved Games" / "Hades" / "Profile1.sav"
    # Linux / Steam Deck: Hades runs under Proton, so the save lives in the
    # compatibility prefix.
    return (Path.home() / ".steam" / "steam" / "steamapps" / "compatdata"
            / "1145360" / "pfx" / "drive_c" / "users" / "steamuser"
            / "Documents" / "Saved Games" / "Hades" / "Profile1.sav")


def default_telemetry_path(save_path, platform=None, home=None):
    """Match the mod's default log location on each supported platform."""
    platform = platform or sys.platform
    if platform.startswith("win"):
        return save_path.with_name("BoonAdvisor-runs.log")
    home = home or Path.home()
    return home / "BoonAdvisor-runs.log"


def main(argv=None):
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--save", type=Path, default=default_save_path())
    parser.add_argument("--telemetry", type=Path)
    parser.add_argument("--benchmarks", type=Path,
                        default=repo / "tests" / "build_benchmarks.json")
    parser.add_argument("--json", action="store_true",
                        help="print the full machine-readable report")
    parser.add_argument("--json-out", type=Path,
                        help="write a report file; the save remains untouched")
    args = parser.parse_args(argv)
    telemetry_path = args.telemetry or default_telemetry_path(args.save)

    if args.json_out:
        # Never let the report path clobber the inputs this tool promises to
        # leave untouched (the save itself, or the telemetry log).
        target = args.json_out.resolve()
        for protected in (args.save, telemetry_path):
            if protected.exists() and target == protected.resolve():
                parser.error("--json-out must not overwrite %s" % protected)

    try:
        header, globals_table = read_save(args.save)
    except (OSError, SaveFormatError) as error:
        parser.error(str(error))
    game_state = globals_table.get("GameState", {})
    benchmarks = load_benchmarks(args.benchmarks)
    report = {
        "save_path": str(args.save),
        "save_header": header,
        "history": analyze_history(game_state, benchmarks),
        "telemetry": analyze_telemetry(telemetry_path),
        "limitations": [
            "Historical saves retain final builds and outcomes, not each offered choice.",
            "Save correlations are not causal evidence for a recommendation.",
            "Exact follow-rate comparisons require BoonAdvisor telemetry.",
        ],
    }
    if args.json_out:
        args.json_out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
