"""Lighting, switch and socket layout per room (Suggest wiring, step 2).

Deterministic: every number comes from skills/wirewise-bs7671/references/rule-profile.json
(lumen method, lux targets, Section 701, RCD notes) or layout-defaults.json (socket counts,
placement offsets). The AI only names rooms; it never sets a count. Each check carries the
trust tag of the value it used. Coordinates are canvas cm.
"""

::py::
import json, math, os

REF_DIR = os.path.join("skills", "wirewise-bs7671", "references")
_FILES = {}


def _ref(name):
    """Load a reference JSON (reloaded when the file changes, so edits apply without a restart)."""
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (os.path.join(here, "..", REF_DIR), os.path.join(os.getcwd(), REF_DIR)):
        path = os.path.normpath(os.path.join(base, name))
        if os.path.exists(path):
            mtime = os.path.getmtime(path)
            cached = _FILES.get(path)
            if cached is None or cached[0] != mtime:
                with open(path, encoding="utf-8") as f:
                    _FILES[path] = (mtime, json.load(f))
            return _FILES[path][1]
    raise FileNotFoundError(name + " not found in " + REF_DIR)


def _trust(source):
    """Trust tag = text before the first ' — ' of a _source string."""
    return (source or "not in rule profile").split(" — ")[0].strip()


def _check(level, text, rule, source):
    return {"level": level, "text": text, "rule": rule, "trust": _trust(source)}


def _round_half_up(x):
    return int(math.floor(x + 0.5))


# ---- geometry (canvas cm; y grows downward) ----

def _points(poly, rect):
    if len(poly) >= 6:
        return [(poly[i], poly[i + 1]) for i in range(0, len(poly) - 1, 2)]
    x, y, w, h = rect
    return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]


def _inside(pts, x, y):
    hit = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-9) + xi:
            hit = not hit
        j = i
    return hit


def _area_cm2(pts):
    s = 0.0
    for i in range(len(pts)):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % len(pts)]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2.0


def _inward(pts, ax, ay, bx, by, d):
    """Point d cm inside the room, perpendicular to wall a-b at its middle (None if the wall is degenerate)."""
    ex, ey = bx - ax, by - ay
    length = math.hypot(ex, ey)
    if length < 1e-6:
        return None
    nx, ny = -ey / length, ex / length
    mx, my = (ax + bx) / 2, (ay + by) / 2
    if not _inside(pts, mx + nx * 2, my + ny * 2):
        nx, ny = -nx, -ny
    return nx * d, ny * d


def _walk(pts):
    """Wall segments with cumulative perimeter positions."""
    segs, total = [], 0.0
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        if length > 1e-6:
            segs.append((total, length, a, b))
            total += length
    return segs, total


def _at(pts, segs, total, s, inset):
    s %= total
    for start, length, a, b in segs:
        if s <= start + length:
            t = (s - start) / length
            px, py = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            off = _inward(pts, a[0], a[1], b[0], b[1], inset) or (0.0, 0.0)
            return px + off[0], py + off[1]
    return pts[0]


def _light_points(pts, n):
    """n ceiling points on an even grid over the room, kept inside its outline."""
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, y0, w, h = min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)
    cols = max(1, _round_half_up(math.sqrt(n * w / max(h, 1.0))))
    rows = max(1, math.ceil(n / cols))
    for _ in range(8):
        cells = [(x0 + w * (c + 0.5) / cols, y0 + h * (r + 0.5) / rows) for r in range(rows) for c in range(cols)]
        cells = [p for p in cells if _inside(pts, p[0], p[1])]
        if len(cells) >= n:
            if len(cells) == n:
                return cells
            step = len(cells) / n
            return [cells[int(i * step + step / 2)] for i in range(n)]
        if cols * h <= rows * w:
            cols += 1
        else:
            rows += 1
    cx = sum(xs) / len(xs)
    cy = sum(ys) / len(ys)
    return [(cx, cy)] * n


def _switch_point(pts, doors, place):
    """Inside the room, beside the widest door, a little past the door edge."""
    door = max(doors, key=lambda d: d[2])
    dx, dy, dw = door
    # Wall direction = nearest outline segment to the door centre
    best, best_d = None, 1e18
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        ex, ey = b[0] - a[0], b[1] - a[1]
        l2 = ex * ex + ey * ey
        if l2 < 1e-6:
            continue
        t = max(0.0, min(1.0, ((dx - a[0]) * ex + (dy - a[1]) * ey) / l2))
        dist = math.hypot(a[0] + ex * t - dx, a[1] + ey * t - dy)
        if dist < best_d:
            best, best_d = (a, b), dist
    a, b = best
    length = math.hypot(b[0] - a[0], b[1] - a[1])
    tx, ty = (b[0] - a[0]) / length, (b[1] - a[1]) / length
    off = _inward(pts, a[0], a[1], b[0], b[1], place["switch_inset_from_wall"]) or (0.0, 0.0)
    along = dw / 2 + place["switch_offset_from_door_edge"]
    for sign in (1, -1):
        sx = dx + tx * along * sign + off[0]
        sy = dy + ty * along * sign + off[1]
        if _inside(pts, sx, sy):
            return sx, sy
    return dx + off[0], dy + off[1]


def _socket_points(pts, n, doors, switch, place):
    """n outlets spread evenly along the walls, slid away from doors and the switch."""
    segs, total = _walk(pts)
    if n == 0 or total <= 0:
        return []
    inset = place["socket_inset_from_wall"]

    def clear(p):
        for dx, dy, dw in doors:
            if math.hypot(p[0] - dx, p[1] - dy) < dw / 2 + place["keep_sockets_from_door_edge"]:
                return False
        return switch is None or math.hypot(p[0] - switch[0], p[1] - switch[1]) >= place["keep_sockets_from_switch"]

    out = []
    for k in range(n):
        s = (k + 0.5) * total / n
        p = _at(pts, segs, total, s, inset)
        for step in range(1, 24):
            if clear(p):
                break
            s += total / n / 12.0 * (1 if step % 2 else -1) * step
            p = _at(pts, segs, total, s, inset)
        out.append(p)
    return out


# ---- design ----

def design_room(room_type, poly, rect, doors, sized):
    """Lights (lumen method), one switch by the door and socket outlets for one room.

    poly: flattened outline in canvas cm (may be empty -> rect); rect: (x, y, w, h);
    doors: flattened [x, y, width, ...] in canvas cm. Returns a plain dict.
    """
    prof = _ref("rule-profile.json")
    defs = _ref("layout-defaults.json")
    ld = prof["lighting_design"]
    lm = ld["lumen_method"]
    place = defs["placement_cm"]
    pts = _points(poly, rect)
    door_list = [(doors[i], doors[i + 1], doors[i + 2]) for i in range(0, len(doors) - 2, 3)]
    area = _area_cm2(pts) / 10000.0
    checks = []
    if not sized:
        checks.append(_check("WARNING", "Plan is not to scale, so the room area is assumed. Use Set scale before relying on these counts.",
                             "Input", "missing input"))

    # Lights: lumen method from the rule profile
    key = defs["room_type_to_profile"].get(room_type)
    lux = ld["target_lux"].get(key) if key else None
    uf, mf = lm["UF_default"], lm["MF_default"]
    lamps = sorted(lm["lamp_options"], key=lambda o: o["lumens"])
    if lux is None or area <= 0:
        lamp, n_lights, needed = dict(lm["default_lamp"]), 1, 0.0
        checks.append(_check("WARNING", "No target lux for this room type: not in rule profile. 1 light point placed; set a target to size it.",
                             "Lighting design (not BS 7671)", ld["target_lux"]["_source"]))
    else:
        needed = lux * area / (uf * mf)
        n_lights = max(1, _round_half_up(area / 6.0))
        lamp = next((o for o in lamps if o["lumens"] >= needed / n_lights), None)
        if lamp is None:
            # Too few points even with the brightest lamp: add points, then pick the
            # smallest lamp that still meets the target (profile rule: "smallest lamp that meets the lux target")
            n_lights = math.ceil(needed / lamps[-1]["lumens"])
            lamp = next(o for o in lamps if o["lumens"] >= needed / n_lights)
        provided = n_lights * lamp["lumens"]
        achieved = provided * uf * mf / area
        checks.append(_check("PASS", f"{lux} lx target ({key}): {n_lights} × {lamp['watts']} W LED ({lamp['lumens']} lm) = {provided} lm "
                             f"≥ {needed:.0f} lm needed, about {achieved:.0f} lx (UF {uf}, MF {mf})",
                             "Lumen method (design guidance, not BS 7671)", ld["target_lux"]["_source"]))
        density = n_lights * lamp["watts"] / area
        bench = ld["power_density_check"]["max_w_per_m2_benchmark"]
        checks.append(_check("INFO" if density > bench else "PASS",
                             f"Lighting power {density:.1f} W/m² vs {bench} W/m² benchmark" + (" (above benchmark)" if density > bench else ""),
                             "SLSEA 2009 Table 2.1 benchmark", ld["power_density_check"]["_source"]))
    lights = _light_points(pts, n_lights)

    # Switch: one per room, inside, next to the door
    switching = ld["switching"]
    if door_list:
        switch = _switch_point(pts, door_list, place)
        checks.append(_check("PASS", "1 switch inside the room next to the door", "One switch per enclosed room", switching["_source"]))
    else:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        switch = (min(xs) + 40.0, max(ys) - place["switch_inset_from_wall"])
        if not _inside(pts, switch[0], switch[1]):
            switch = lights[0]
        checks.append(_check("WARNING", "Door not found on the plan, so the switch is in a corner. Move it next to the door.",
                             "Switch location", switching["_source"]))

    # Socket outlets
    rule = defs["sockets_per_room"].get(room_type) or defs["sockets_per_room"]["other"]
    per = rule["m2_per_outlet"]
    n_sockets = min(rule["max"], max(rule["min"], math.ceil(area / per) if per > 0 else 0))
    sockets = _socket_points(pts, n_sockets, door_list, switch, place)
    if room_type in ("bathroom", "wc"):
        b701 = prof["bathroom_701"]
        checks.append(_check("INFO", f"No 13 A sockets: they must be at least {b701['socket_min_distance_from_zone1_m']} m from zone 1. Shaver supply unit only.",
                             "Section 701 (701.512.3)", b701["_source"]))
        checks.append(_check("INFO", f"Light fittings in zones 1 and 2 need {b701['min_ip']['zone1']} or better; every bathroom circuit needs a 30 mA RCD.",
                             "Section 701 (701.411.3.3)", b701["_source"]))
    else:
        checks.append(_check("PASS", f"{n_sockets} twin socket outlet{'s' if n_sockets != 1 else ''} ({prof['sockets']['type']}), "
                             f"at least {prof['sockets']['min_height_above_floor_or_worktop_mm']} mm above floor or worktop",
                             "Socket count: WireWise default", defs["sockets_per_room"]["_source"]))
        if n_sockets > 0:
            checks.append(_check("INFO", "Socket circuits need 30 mA RCD additional protection.", "411.3.3",
                                 prof["rcd"]["required_for"]["SOCKET_LE_32A"]))

    return {
        "area_m2": area,
        "lux": lux or 0,
        "lamp_watts": lamp["watts"],
        "lamp_lumens": lamp["lumens"],
        "lumens_needed": needed,
        "lights": [list(p) for p in lights],
        "switch": list(switch),
        "sockets": [list(p) for p in sockets],
        "checks": checks,
    }


# ---- Appliances: AC sizing, dedicated loads, plug bases, maximum demand ----

def _item(it, prof, cat):
    """Catalog item with watts / pf resolved from the rule profile where it defines them."""
    out = {k: v for k, v in it.items() if not k.startswith("_")}
    source = cat["_items_source"]
    if "profile_load" in it:
        out["watts"] = prof["typical_loads_w"][it["profile_load"]]
        source = prof["typical_loads_w"]["_source"]
    if it.get("template"):
        out["pf"] = prof["circuit_templates"][it["template"]]["pf"]
    out["watts"] = float(out.get("watts", 0))
    out["pf"] = float(out.get("pf", 1.0))
    out["trust"] = _trust(source)
    return out


def load_catalog():
    """Load categories for the picker: [{id, name, items: [...]}]."""
    prof = _ref("rule-profile.json")
    cat = _ref("load-catalog.json")
    return [{"id": c["id"], "name": c["name"], "items": [_item(i, prof, cat) for i in c["items"]]} for c in cat["categories"]]


def find_item(item_id):
    for c in load_catalog():
        for i in c["items"]:
            if i["id"] == item_id:
                return i
    return None


def ac_sizing(area_m2):
    """Required BTU from room area, the smallest standard unit that covers it, and its power from the profile."""
    prof = _ref("rule-profile.json")
    rule = _ref("load-catalog.json")["ac_sizing"]
    need = area_m2 * rule["btu_per_m2"]
    sizes = sorted(rule["unit_sizes_btu"])
    size = next((s for s in sizes if s >= need), None)
    units = 1
    if size is None:
        size = sizes[-1]
        units = math.ceil(need / size)
    return {"need_btu": need, "size_btu": size, "units": units, "btu_per_m2": rule["btu_per_m2"],
            "watts": float(prof["typical_loads_w"][f"AC_{size}_BTU"]), "item_id": f"ac_{size}",
            "trust": _trust(rule["_source"])}


def ac_room_types_excluded():
    return list(_ref("load-catalog.json")["ac_sizing"]["exclude_room_types"])


def protection(item, watts):
    """Design current, breaker and cable for one dedicated load (BS 7671 433.1.1: Ib <= In)."""
    prof = _ref("rule-profile.json")
    volts = prof["supply"]["voltage_v"]
    ratings = prof["device_ratings_a"]
    ib = watts / (volts * item["pf"])
    checks = []
    template = item.get("template")
    cable = 0.0
    if template:
        t = prof["circuit_templates"][template]
        curve, rating, cable = t["device"][0], int(t["device"][1:]), float(t["cable_mm2"])
        if ib > rating:
            bigger = next((r for r in ratings if r >= ib), None)
            checks.append(_check("WARNING", f"Ib {ib:.1f} A is above the template's {t['device']}; "
                                 + (f"needs {curve}{bigger} and a bigger cable." if bigger else "no standard rating is large enough."),
                                 "433.1.1", "rule profile circuit_templates"))
            rating = bigger or rating
        checks.append(_check("PASS", f"Ib = {watts:.0f} W / ({volts} V × pf {item['pf']}) = {ib:.1f} A ≤ In {curve}{rating} · {cable:g} mm² T&E ({template})",
                             "433.1.1 (Ib ≤ In)", "rule profile circuit_templates"))
    else:
        curve = item.get("curve", "B")
        rating = next((r for r in ratings if r >= max(ib, item.get("min_device_a", 0))), ratings[-1])
        checks.append(_check("PASS", f"Ib = {watts:.0f} W / ({volts} V × pf {item['pf']}) = {ib:.1f} A ≤ In {curve}{rating}",
                             "433.1.1 (Ib ≤ In)", item["trust"]))
        checks.append(_check("WARNING", "No circuit template for this load in the rule profile: the cable is sized in the circuit step (installation method needed).",
                             "433.1.1 / App 4", "not in rule profile"))
    if item.get("motor"):
        checks.append(_check("INFO", "Heavy motor load: starting current is several times the running current, so a type C breaker is used to avoid nuisance tripping. Give it its own circuit.",
                             "Breaker type (Table 41.3 type C)", "design choice"))
    if item.get("demand") in ("WATER_HEATER_INSTANT", "WATER_HEATER_STORAGE"):
        b701 = prof["bathroom_701"]
        checks.append(_check("INFO", f"Bathroom circuit: 30 mA RCD required; heater in zone 1 needs {b701['min_ip']['zone1']}. Switch is outside the bathroom.",
                             "701.411.3.3 / Section 701", b701["_source"]))
    return {"ib": ib, "breaker": f"{curve}{rating}", "cable": cable, "checks": checks}


def _clear_spot(pts, doors, taken, prefer_far_from_door, inset=15.0):
    """Best wall position: away from doors and existing devices (and far from the door if asked)."""
    segs, total = _walk(pts)
    best, best_s, best_score = None, 0.0, -1e18
    steps = 64
    for k in range(steps):
        s = (k + 0.5) * total / steps
        p = _at(pts, segs, total, s, inset)
        if not _inside(pts, p[0], p[1]):
            continue
        d_door = min([math.hypot(p[0] - d[0], p[1] - d[1]) - d[2] / 2 for d in doors] or [1000.0])
        if d_door < 40:
            continue
        if min(math.hypot(p[0] - v[0], p[1] - v[1]) for v in pts) < 45:
            continue   # not jammed into a corner
        d_taken = min([math.hypot(p[0] - t[0], p[1] - t[1]) for t in taken] or [1000.0])
        score = min(d_taken, 250.0) + (0.6 * min(d_door, 600.0) if prefer_far_from_door else 0.0)
        if score > best_score:
            best, best_s, best_score = p, s, score
    if best is None:
        best = _at(pts, segs, total, 0.0, inset)
    return best, best_s, segs, total


def place_appliance(poly, rect, doors, taken, item):
    """Appliance position and its plug base (beside it on the same wall)."""
    pts = _points(poly, rect)
    door_list = [(doors[i], doors[i + 1], doors[i + 2]) for i in range(0, len(doors) - 2, 3)]
    taken = [tuple(t) for t in taken]
    if item.get("ceiling"):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        app = (sum(xs) / len(xs), sum(ys) / len(ys))
        plug, _, _, _ = _clear_spot(pts, door_list, taken, False)
        return {"appliance": list(app), "plug": list(plug)}
    app, s, segs, total = _clear_spot(pts, door_list, taken, True, inset=20.0)
    plug = _at(pts, segs, total, s + 45.0, 15.0)
    if not _inside(pts, plug[0], plug[1]):
        plug = _at(pts, segs, total, s - 45.0, 15.0)
    return {"appliance": list(app), "plug": list(plug)}


def place_by_door(poly, rect, doors, taken, outside):
    """Plug/switch next to a door: inside the room, or just outside it (bathroom heaters).
    Tries every door and both sides, keeping the spot farthest from existing devices.
    Returns (point, found_door)."""
    pts = _points(poly, rect)
    door_list = [(doors[i], doors[i + 1], doors[i + 2]) for i in range(0, len(doors) - 2, 3)]
    taken = [tuple(t) for t in taken]
    if not door_list:
        p, _, _, _ = _clear_spot(pts, [], taken, False)
        return list(p), False
    best, best_score = None, -1e18
    for dx, dy, dw in door_list:
        wall, wall_d = None, 1e18
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            ex, ey = b[0] - a[0], b[1] - a[1]
            l2 = ex * ex + ey * ey
            if l2 < 1e-6:
                continue
            t = max(0.0, min(1.0, ((dx - a[0]) * ex + (dy - a[1]) * ey) / l2))
            dist = math.hypot(a[0] + ex * t - dx, a[1] + ey * t - dy)
            if dist < wall_d:
                wall, wall_d = (a, b), dist
        a, b = wall
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        tx, ty = (b[0] - a[0]) / length, (b[1] - a[1]) / length
        nx, ny = _inward(pts, a[0], a[1], b[0], b[1], 1.0) or (0.0, 0.0)
        depth = -25.0 if outside else 12.0
        # Past the light switch (15 cm from the door edge). Outside the room, stay right by the door
        # so the switch cannot slide past the corner into a different room.
        for extra in ((45.0,) if outside else (45.0, 75.0, 105.0)):
            along = dw / 2 + extra
            for sign in (-1, 1):
                p = (dx + tx * along * sign + nx * depth, dy + ty * along * sign + ny * depth)
                if outside == _inside(pts, p[0], p[1]):
                    continue
                clear = min([math.hypot(p[0] - q[0], p[1] - q[1]) for q in taken] or [1000.0])
                score = min(clear, 60.0) - extra * 0.05   # clear of other devices first, then closest to the door
                if score > best_score:
                    best, best_score = p, score
    if best is None:
        dx, dy, dw = max(door_list, key=lambda d: d[2])
        return [dx, dy], True
    return list(best), True


def max_demand(lighting_w, socket_rooms, loads):
    """Whole-house maximum demand with the profile's diversity (skill step 13).

    socket_rooms: [[room_type, general_outlets]]; loads: [{"name", "demand", "watts"}].
    """
    prof = _ref("rule-profile.json")
    md = prof["max_demand"]
    div = md["diversity"]
    volts = prof["supply"]["voltage_v"]
    rows = []

    def row(name, connected, demand, rule):
        rows.append({"name": name, "connected_w": float(connected), "demand_w": float(demand), "rule": rule})

    if lighting_w > 0:
        row("Lighting", lighting_w, lighting_w * div["LIGHTING"]["factor"], f"{div['LIGHTING']['factor']:.0%} of lighting")
    # Socket circuits: the kitchen gets its own; the rest are grouped up to the per-circuit outlet limit
    per = prof["rcd"]["max_double_sockets_per_circuit_recommended"]
    w_out = div["SOCKETS"]["estimated_w_per_outlet"]
    circuits = [n for t, n in socket_rooms if t == "kitchen" and n > 0]
    rest = sum(n for t, n in socket_rooms if t != "kitchen")
    while rest > 0:
        circuits.append(min(per, rest))
        rest -= per
    if circuits:
        ws = sorted((c * w_out for c in circuits), reverse=True)
        row(f"Socket outlets ({sum(circuits)} on {len(circuits)} circuits)", sum(ws), ws[0] + 0.4 * sum(ws[1:]),
            f"100% largest + 40% others, {w_out} W/outlet")
    groups = {}
    for ld in loads:
        groups.setdefault(ld["demand"], []).append(ld)
    for key, items in groups.items():
        watts = sorted((float(i["watts"]) for i in items), reverse=True)
        connected = sum(watts)
        label = ", ".join(sorted({i["name"] for i in items}))
        if key in ("AC", "FAN", "WATER_HEATER_STORAGE"):
            f = div[key]["factor"]
            row(label, connected, connected * f, f"{f:.0%} ({key})")
        elif key == "WATER_HEATER_INSTANT":
            row(label, connected, sum(watts[:2]) + 0.25 * sum(watts[2:]), "100% largest two + 25% rest")
        elif key == "COOKER":
            amps = [w / volts for w in watts]
            row(label, connected, sum((min(a, 10) + 0.3 * max(0.0, a - 10)) * volts for a in amps), "10 A + 30% of the rest")
        else:
            row(label, connected, connected, "100% (no diversity rule in profile)")
    total = sum(r["demand_w"] for r in rows)
    ib = total / volts
    main = md["main_switch_a"]
    pct = ib / main * 100.0
    th = md["thresholds"]
    level = "ERROR" if pct > th["error_pct_of_main_switch"] else ("WARNING" if pct >= th["warning_pct_of_main_switch"] else "PASS")
    return {"rows": rows, "total_w": total, "ib_a": ib, "main_a": float(main), "pct": pct, "level": level,
            "fixes": list(md["suggested_fixes"]) if level != "PASS" else [],
            "trust": _trust(div["_source"]), "main_trust": _trust(md["_source_main_switch"])}
::py::
