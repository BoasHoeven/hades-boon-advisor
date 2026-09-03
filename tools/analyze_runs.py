"""Read-only Hades save and BoonAdvisor telemetry analysis.

This parser follows the documented Supergiant save header, raw LZ4 block, and
Luabins value format. It opens saves only in binary read mode and never writes
to them. Historical saves contain final run builds, not the offers that were
shown, so save backtests are correlation checks.

The telemetry half reads BoonAdvisor-runs.log and prints a PER-DECISION
report: every overrule sorted by the model's own margin, with what happened
in the rooms after it; which reasons and which score terms show up in the
picks you overruled; and the follow rate per advisor. Run-level clear rates
are only compared once a bucket holds ten runs, because with fewer they say
nothing.
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
MIN_RUNS_FOR_CLEAR_RATE = 10


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


# --------------------------------------------------------------------------
# Telemetry
# --------------------------------------------------------------------------

# key=value where value is either "quoted text" or a run of non-space,
# non-pipe characters. Field names are the mod's own (see BA_Telemetry.lua).
FIELD_RE = re.compile(r'(?:^|\s)([A-Za-z][A-Za-z0-9_-]*)=("(?:[^"]*)"|[^\s|]+)')
# One option in an [offer] segment: flags, name, score, rank, then terms.
OPTION_RE = re.compile(r'^([>*]*)([A-Za-z][A-Za-z0-9_:/]*)=(-?\d+)(?:\((\w)\))?(.*)$')
# One option in a [door]/[shop]/[well]/[purge]/[keep] segment.
STOCK_RE = re.compile(r'^([>*]*)([A-Za-z][A-Za-z0-9_:/]*)=(-?\d+)(?:@(\d+))?(\[[^\]]*\])?$')
SESSION_RE = re.compile(r'^=== BoonAdvisor v(\S+)\s+(.*?)\s*===$')
TAG_RE = re.compile(r'^\[([a-z-]+)\s*\]\s*(.*)$')
LEGACY_TOOK_RE = re.compile(r"^\[took \]\s+(.*?)\s+recommended=(.*?)\s+followed=(true|false)\s*$")


def parse_fields(text):
    fields = {}
    for key, value in FIELD_RE.findall(text):
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        fields[key] = value
    return fields


def to_number(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def parse_terms(text):
    terms = {}
    for key, value in FIELD_RE.findall(text):
        number = to_number(value.strip('"'))
        if number is not None:
            terms[key] = number
    return terms


def parse_offer_options(segments):
    options = []
    for segment in segments:
        match = OPTION_RE.match(segment.strip())
        if not match:
            continue
        flags, name, score, rank, rest = match.groups()
        options.append({
            "name": name, "score": int(score), "rank": rank,
            "starred": "*" in flags, "terms": parse_terms(rest),
        })
    return options


def parse_stock_options(segments):
    options = []
    for segment in segments:
        match = STOCK_RE.match(segment.strip())
        if not match:
            continue
        flags, name, score, cost, note = match.groups()
        options.append({
            "name": name, "score": int(score), "cost": int(cost) if cost else None,
            "taken": ">" in flags, "starred": "*" in flags,
            "note": note.strip("[]") if note else None,
        })
    return options


def new_run_record(context):
    return {"context": context, "decisions": [], "rooms": [], "offers": [],
            "rerolls": 0, "result": None, "time": None, "end": {}}


def analyze_telemetry(path: Path):
    """Parse BoonAdvisor-runs.log into runs, decisions and rooms.

    A decision is any line where the advisor recommended something and the
    player chose: boon/pom/hammer/chaos picks ([took ]), doors, shop and Well
    purchases, purge sales, keepsakes and story choices. Each carries the
    model's margin (recommended minus taken) so overrules can be ranked.
    """
    result = {"present": path.is_file(), "path": str(path), "lines": 0,
              "offers": 0, "choices": 0, "followed": 0, "rerolls": 0,
              "doors": 0, "shops": 0, "wells": 0, "purges": 0, "story": 0,
              "keepsakes": 0, "rooms": 0, "decisions": 0,
              "followed_decisions": 0, "runs": [], "sessions": []}
    if not path.is_file():
        return result
    current = None
    session = None
    last_offer = None
    room_index = 0

    def ensure_run(fields):
        nonlocal current
        if current is None:
            current = new_run_record(fields if fields else {})
            current["implicit"] = True
        return current

    def add_decision(kind, fields, margin, followed, reason=None, options=None,
                     taken=None, recommended=None, terms=None, extra=None):
        run = ensure_run(fields)
        decision = {
            "kind": kind, "run": fields.get("run", "?"),
            "depth": to_number(fields.get("depth"), None),
            "biome": fields.get("biome"), "aspect": fields.get("aspect"),
            "taken": taken, "recommended": recommended,
            "margin": margin, "followed": followed, "reason": reason,
            "options": options or [], "terms": terms or {},
            "room_index": len(run["rooms"]),
            "session": session["fingerprint"] if session else None,
            "line": fields.get("_line"),
        }
        if extra:
            decision.update(extra)
        run["decisions"].append(decision)
        result["decisions"] += 1
        result["followed_decisions"] += int(bool(followed))
        return decision

    with path.open(encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            result["lines"] += 1
            session_match = SESSION_RE.match(line)
            if session_match:
                fields = parse_fields(session_match.group(2))
                session = {"version": session_match.group(1),
                           "fingerprint": fields.get("ratings", "unknown"),
                           "objective": fields.get("objective"), "runs": 0}
                result["sessions"].append(session)
                continue
            tag_match = TAG_RE.match(line)
            if not tag_match:
                continue
            tag, body = tag_match.groups()
            segments = [part.strip() for part in body.split("|")]
            fields = parse_fields(segments[0])
            fields["_line"] = result["lines"]
            build = next((parse_fields(part)["build"] for part in segments[1:]
                          if part.startswith("build=")), None)

            if tag == "run-start":
                current = new_run_record(fields)
                current["build"] = build
                current["session"] = session["fingerprint"] if session else None
                if session:
                    session["runs"] += 1
            elif tag == "offer":
                result["offers"] += 1
                options = parse_offer_options(segments[1:])
                summary = {}
                for part in segments[1:]:
                    if part.startswith("kind=") or " margin=" in " " + part:
                        summary.update(parse_fields(part))
                last_offer = {"fields": fields, "options": options,
                              "kind": summary.get("kind", "boon"),
                              "reason": summary.get("reason"),
                              "verdict": summary.get("verdict"),
                              "build": build}
                ensure_run(fields)["offers"].append(last_offer)
            elif tag == "took":
                result["choices"] += 1
                legacy = LEGACY_TOOK_RE.match(line)
                if "taken" in fields:
                    followed = fields.get("followed") == "true"
                    taken = fields.get("taken")
                    recommended = fields.get("recommended")
                    margin = to_number(fields.get("margin"), 0.0)
                    kind = fields.get("kind", "boon")
                    reason = fields.get("reason")
                elif legacy:
                    taken, recommended = legacy.group(1), legacy.group(2)
                    followed = legacy.group(3) == "true"
                    margin = None
                    kind = "boon"
                    reason = None
                else:
                    continue
                terms = {}
                options = []
                if last_offer is not None:
                    options = last_offer["options"]
                    starred = next((o for o in options if o["starred"]), None)
                    chosen = next((o for o in options if o["name"] == taken), None)
                    if starred is not None:
                        terms = starred["terms"]
                    if reason is None:
                        reason = last_offer.get("reason")
                    if margin is None and starred and chosen:
                        margin = float(starred["score"] - chosen["score"])
                    taken_terms = chosen["terms"] if chosen else {}
                else:
                    taken_terms = {}
                result["followed"] += int(followed)
                add_decision(kind, fields, margin, followed, reason, options,
                             taken, recommended, terms,
                             {"taken_terms": taken_terms,
                              "verdict": last_offer.get("verdict") if last_offer else None,
                              "build": last_offer.get("build") if last_offer else build})
            elif tag == "reroll":
                result["rerolls"] += 1
                ensure_run(fields)["rerolls"] += 1
            elif tag in ("door", "shop", "well", "purge"):
                result[{"door": "doors", "shop": "shops", "well": "wells",
                        "purge": "purges"}[tag]] += 1
                options = parse_stock_options(segments[1:])
                taken = next((o["name"] for o in options if o["taken"]), fields.get("took"))
                recommended = next((o["name"] for o in options if o["starred"]), None)
                followed = fields.get("followed")
                if followed is None:
                    followed = any(o["taken"] and o["starred"] for o in options)
                else:
                    followed = followed == "true"
                margin = to_number(fields.get("margin"))
                if margin is None:
                    star = next((o["score"] for o in options if o["starred"]), None)
                    took = next((o["score"] for o in options if o["taken"]), None)
                    margin = float(star - took) if star is not None and took is not None else 0.0
                add_decision(tag, fields, margin, followed, None, options,
                             taken, recommended, {},
                             {"build": build, "reroll_advised": fields.get("reroll") == "true"})
            elif tag == "keep":
                result["keepsakes"] += 1
                options = parse_stock_options(segments[1:])
                add_decision("keepsake", fields, to_number(fields.get("margin"), 0.0),
                             fields.get("followed") == "true", None, options,
                             fields.get("took"), fields.get("recommended"), {},
                             {"build": build, "stage": fields.get("stage")})
            elif tag == "story":
                result["story"] += 1
                add_decision("story", fields, to_number(fields.get("margin"), 0.0),
                             fields.get("followed") == "true", None, [],
                             fields.get("took"), fields.get("recommended"), {},
                             {"build": build})
            elif tag == "room":
                result["rooms"] += 1
                run = ensure_run(fields)
                run["rooms"].append({
                    "index": len(run["rooms"]),
                    "room": fields.get("room"), "encounter": fields.get("encounter"),
                    "type": fields.get("type"),
                    "clear": to_number(fields.get("clear")),
                    "damage": to_number(fields.get("damage_taken"), 0.0),
                    "hit": fields.get("hit") == "true",
                    "hp": fields.get("hp"), "depth": to_number(fields.get("depth")),
                    "biome": fields.get("biome"), "next": fields.get("next"),
                    "decisions_before": len(run["decisions"]),
                })
            elif tag == "run-end":
                run = ensure_run(fields)
                run["result"] = fields.get("result")
                run["time"] = to_number(fields.get("time"))
                run["end"] = fields
                run["final_build"] = build
                result["runs"].append(run)
                current = None
                last_offer = None
    if current is not None and (current["decisions"] or current["offers"]
                                or current["rooms"] or current["rerolls"]):
        current["result"] = "incomplete"
        result["runs"].append(current)

    result["follow_rate"] = (result["followed"] / result["choices"]
                             if result["choices"] else None)
    result["all_decision_follow_rate"] = (
        result["followed_decisions"] / result["decisions"]
        if result["decisions"] else None)
    result["report"] = decision_report(result["runs"])
    return result


def _median(values):
    values = [value for value in values if isinstance(value, (int, float))]
    return statistics.median(values) if values else None


def room_aftermath(run, decision, count=3):
    """Clear time and damage of the next `count` rooms, relative to the run's
    medians. Positive damage_delta means more damage than usual."""
    rooms = run["rooms"]
    start = decision["room_index"]
    window = [room for room in rooms[start:start + count]
              if room["type"] != "NonCombat"]
    median_clear = _median([room["clear"] for room in rooms])
    median_damage = _median([room["damage"] for room in rooms])
    clears = [room["clear"] for room in window if room["clear"] is not None]
    damages = [room["damage"] for room in window]
    return {
        "rooms": len(window),
        "clear": _median(clears),
        "damage": _median(damages),
        "clear_delta": (_median(clears) - median_clear)
        if clears and median_clear is not None else None,
        "damage_delta": (_median(damages) - median_damage)
        if damages and median_damage is not None else None,
    }


def decision_report(runs):
    decisions = [(run, decision) for run in runs for decision in run["decisions"]]
    overrules = []
    for run, decision in decisions:
        if decision["followed"]:
            continue
        entry = dict(decision)
        entry["aftermath"] = room_aftermath(run, decision)
        entry["run_result"] = run.get("result")
        overrules.append(entry)
    overrules.sort(key=lambda item: -(item["margin"] or 0))

    reason_counts = Counter(item["reason"] for item in overrules
                            if item["kind"] in ("boon", "pom", "hammer", "chaos")
                            and item["reason"])
    reason_totals = Counter(decision["reason"] for _, decision in decisions
                            if decision["kind"] in ("boon", "pom", "hammer", "chaos")
                            and decision["reason"])

    per_kind = {}
    for _, decision in decisions:
        bucket = per_kind.setdefault(decision["kind"], {"decisions": 0, "followed": 0,
                                                        "margins": []})
        bucket["decisions"] += 1
        bucket["followed"] += int(bool(decision["followed"]))
        if decision["margin"] is not None:
            bucket["margins"].append(decision["margin"])
    for bucket in per_kind.values():
        bucket["follow_rate"] = (bucket["followed"] / bucket["decisions"]
                                 if bucket["decisions"] else None)
        bucket["median_margin"] = _median(bucket["margins"])
        del bucket["margins"]

    term_sums = defaultdict(lambda: {"followed": [], "overruled": []})
    for _, decision in decisions:
        if decision["kind"] not in ("boon", "pom", "hammer", "chaos"):
            continue
        bucket = "followed" if decision["followed"] else "overruled"
        for name, value in decision["terms"].items():
            term_sums[name][bucket].append(value)
    term_averages = {}
    for name, buckets in term_sums.items():
        term_averages[name] = {
            "followed_mean": statistics.mean(buckets["followed"]) if buckets["followed"] else None,
            "followed_n": len(buckets["followed"]),
            "overruled_mean": statistics.mean(buckets["overruled"]) if buckets["overruled"] else None,
            "overruled_n": len(buckets["overruled"]),
        }

    spikes = []
    for run in runs:
        damages = [room["damage"] for room in run["rooms"]]
        median_damage = _median(damages)
        if median_damage is None:
            continue
        for room in run["rooms"]:
            if room["damage"] >= max(25.0, 2.5 * median_damage) and room["damage"] > median_damage:
                before = run["decisions"][:room["decisions_before"]][-3:]
                spikes.append({
                    "run": run["context"].get("run", "?"),
                    "room": room["room"], "encounter": room["encounter"],
                    "depth": room["depth"], "damage": room["damage"],
                    "median_damage": median_damage, "hp": room["hp"],
                    "build": run.get("final_build") or run.get("build"),
                    "decisions": [{"kind": d["kind"], "taken": d["taken"],
                                   "recommended": d["recommended"],
                                   "followed": d["followed"], "margin": d["margin"]}
                                  for d in before],
                })
    spikes.sort(key=lambda item: -item["damage"])

    buckets = {}
    for label, predicate in (("mostly_followed", lambda rate: rate >= 0.5),
                             ("mostly_not_followed", lambda rate: rate < 0.5)):
        group = [run for run in runs if run["decisions"]
                 and predicate(sum(1 for d in run["decisions"] if d["followed"])
                               / len(run["decisions"]))]
        clears = [run for run in group if run.get("result") == "clear"]
        buckets[label] = {
            "runs": len(group), "clears": len(clears),
            "clear_rate": (len(clears) / len(group)
                           if len(group) >= MIN_RUNS_FOR_CLEAR_RATE else None),
            "median_clear_time": _median([run["time"] for run in clears])
            if len(group) >= MIN_RUNS_FOR_CLEAR_RATE else None,
        }

    return {
        "decisions": len(decisions),
        "overrules": overrules,
        "reason_frequency": [
            {"reason": reason, "overruled": count,
             "total": reason_totals[reason],
             "overrule_rate": count / reason_totals[reason] if reason_totals[reason] else None}
            for reason, count in reason_counts.most_common()],
        "per_kind": per_kind,
        "term_averages": term_averages,
        "damage_spikes": spikes,
        "run_buckets": buckets,
        "runs_recorded": len(runs),
    }


def fmt_delta(value, unit=""):
    if value is None:
        return "   n/a"
    return "%+6.1f%s" % (value, unit)


def print_decision_report(telemetry):
    report = telemetry.get("report")
    if not report:
        return
    runs = report["runs_recorded"]
    print("\nPer-decision report (%d decisions across %d run records)" %
          (report["decisions"], runs))
    if telemetry["sessions"]:
        print("  Sessions: " + ", ".join(
            "v%s ratings=%s objective=%s (%d runs)" %
            (s["version"], s["fingerprint"], s["objective"], s["runs"])
            for s in telemetry["sessions"]))
        if len({s["fingerprint"] for s in telemetry["sessions"]}) > 1:
            print("  NOTE: more than one ratings fingerprint; term averages mix tunings.")

    print("\nFollow rate per advisor (n = decisions)")
    for kind, bucket in sorted(report["per_kind"].items(), key=lambda kv: -kv[1]["decisions"]):
        rate = "n/a" if bucket["follow_rate"] is None else "%3.0f%%" % (100 * bucket["follow_rate"])
        median = "n/a" if bucket["median_margin"] is None else "%.1f" % bucket["median_margin"]
        print("  %-9s n=%-4d followed %s   median margin %s" %
              (kind, bucket["decisions"], rate, median))

    overrules = report["overrules"]
    print("\nOverrules by margin (n = %d; big margin + clean rooms = model error, "
          "big margin + damage spike = player error, small margin = noise)" % len(overrules))
    if not overrules:
        print("  none")
    for item in overrules[:25]:
        after = item["aftermath"]
        print("  %+6.1f  %-8s run %-3s d%-3s %-30s over %-30s"
              % (item["margin"] or 0, item["kind"], item["run"],
                 int(item["depth"]) if item["depth"] is not None else "?",
                 (item["taken"] or "?")[:30], (item["recommended"] or "?")[:30]))
        detail = "          next %d rooms: clear %s s, damage %s" % (
            after["rooms"], fmt_delta(after["clear_delta"]), fmt_delta(after["damage_delta"]))
        if item.get("reason"):
            detail += '   star: "%s"' % item["reason"]
        print(detail)

    print("\nStar reasons among overruled boon picks (overruled / total with that reason)")
    if not report["reason_frequency"]:
        print("  none")
    for item in report["reason_frequency"][:12]:
        print("  %3d / %-3d  %s" % (item["overruled"], item["total"], item["reason"]))

    print("\nScore terms of the star, mean when followed vs overruled (n)")
    rows = []
    for name, item in report["term_averages"].items():
        if item["followed_mean"] is None and item["overruled_mean"] is None:
            continue
        gap = ((item["overruled_mean"] or 0) - (item["followed_mean"] or 0))
        rows.append((abs(gap), name, item))
    for _, name, item in sorted(rows, reverse=True)[:15]:
        followed = "n/a" if item["followed_mean"] is None else "%6.1f" % item["followed_mean"]
        overruled = "n/a" if item["overruled_mean"] is None else "%6.1f" % item["overruled_mean"]
        print("  %-12s followed %s (%d)   overruled %s (%d)" %
              (name, followed, item["followed_n"], overruled, item["overruled_n"]))
    if not rows:
        print("  none (offer lines without term breakdowns)")

    spikes = report["damage_spikes"]
    print("\nDamage-spike rooms (n = %d; damage >= 2.5x the run's median)" % len(spikes))
    for spike in spikes[:10]:
        print("  run %-3s d%-3s %-18s %-22s damage %4.0f (median %3.0f) hp %s" %
              (spike["run"], int(spike["depth"]) if spike["depth"] is not None else "?",
               (spike["room"] or "?")[:18], (spike["encounter"] or "?")[:22],
               spike["damage"], spike["median_damage"], spike["hp"] or "?"))
        for decision in spike["decisions"]:
            print("      before: %-8s took %-28s %s" %
                  (decision["kind"], (decision["taken"] or "?")[:28],
                   "followed" if decision["followed"]
                   else "over %s (margin %s)" % ((decision["recommended"] or "?")[:20],
                                                  decision["margin"])))
        if spike["build"]:
            print("      build: %s" % spike["build"][:110])
    if not spikes:
        print("  none")

    print("\nRun outcome by follow rate (clear rates need >= %d runs per bucket)" %
          MIN_RUNS_FOR_CLEAR_RATE)
    for label, bucket in report["run_buckets"].items():
        rate = ("%.0f%%" % (100 * bucket["clear_rate"])
                if bucket["clear_rate"] is not None else "n/a (too few runs)")
        print("  %-20s %2d runs  %2d clears  clear rate %s  median %s" %
              (label.replace("_", " "), bucket["runs"], bucket["clears"], rate,
               format_time(bucket["median_clear_time"])))


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
        return
    boon_follow = "n/a" if telemetry["follow_rate"] is None else "%.1f%%" % (100 * telemetry["follow_rate"])
    all_follow = ("n/a" if telemetry["all_decision_follow_rate"] is None
                  else "%.1f%%" % (100 * telemetry["all_decision_follow_rate"]))
    print("  %d offers, %d boon choices, boon follow %s, all decisions %s, "
          "%d rooms, %d run records" %
          (telemetry["offers"], telemetry["choices"], boon_follow, all_follow,
           telemetry["rooms"], len(telemetry["runs"])))
    print_decision_report(telemetry)


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
    parser.add_argument("--telemetry-only", action="store_true",
                        help="skip the save file and report on the log alone")
    args = parser.parse_args(argv)
    telemetry_path = args.telemetry or default_telemetry_path(args.save)

    if args.json_out:
        # Never let the report path clobber the inputs this tool promises to
        # leave untouched (the save itself, or the telemetry log).
        target = args.json_out.resolve()
        for protected in (args.save, telemetry_path):
            if protected.exists() and target == protected.resolve():
                parser.error("--json-out must not overwrite %s" % protected)

    if args.telemetry_only or not args.save.is_file():
        telemetry = analyze_telemetry(telemetry_path)
        report = {"telemetry": telemetry}
        if args.json_out:
            args.json_out.write_text(json.dumps(report, indent=2), encoding="utf-8")
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            if not args.telemetry_only:
                print("No save at %s; reporting on telemetry alone." % args.save)
            print("Telemetry: %s" % telemetry["path"])
            if telemetry["present"]:
                print_decision_report(telemetry)
            else:
                print("  No log yet. The analyzer is ready for the next run.")
        return 0

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
            "Per-decision telemetry shows systematic disagreements and outliers; "
            "whether following the star raises the clear rate needs dozens of runs per aspect.",
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
