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
                             "Socket count: LUMIRA default", defs["sockets_per_room"]["_source"]))
        if n_sockets > 0:
            checks.append(_check("INFO", "Socket circuits need 30 mA RCD additional protection.", "411.3.3",
                                 prof["rcd"]["required_for"]["SOCKET_LE_32A"]))

    return {
        "area_m2": area,
        "uf": uf,
        "mf": mf,
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


# ---- Consumer unit and circuits ("Start wire") ----

def wiring_options():
    """Choices for the Start wire form, all read from the reference files."""
    prof = _ref("rule-profile.json")
    w = _ref("layout-defaults.json")["wiring"]
    cf = prof["correction_factors"]
    return {
        "methods": [{"id": k, "label": v} for k, v in w["installation_methods"].items()],
        "methods_trust": _trust(w["_methods_source"]),
        "ambients": sorted(int(k) for k in cf["ca_ambient_pvc70"] if not k.startswith("_")),
        "groupings": sorted(int(k) for k in cf["cg_grouping"]["single_layer_wall_method_c"] if not k.startswith("_")),
        "main_switch_a": int(prof["max_demand"]["main_switch_a"]),
    }


def _hull(points):
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def _seg_dist(p, a, b):
    ex, ey = b[0] - a[0], b[1] - a[1]
    l2 = ex * ex + ey * ey
    t = 0.0 if l2 < 1e-9 else max(0.0, min(1.0, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ey) / l2))
    return math.hypot(a[0] + ex * t - p[0], a[1] + ey * t - p[1])


def suggest_cu(rooms, taken):
    """Consumer unit spot: inside a room against an outside wall, close to the load centre,
    preferring hall/utility/garage, never a bathroom. rooms: [{id, name, type, poly, rect, doors, loads: [[x, y, w]]}]."""
    w = _ref("layout-defaults.json")["wiring"]
    penalty = w["cu_room_penalty_cm"]
    all_pts, loads = [], []
    for r in rooms:
        all_pts += _points(r["poly"], r["rect"])
        loads += r["loads"]
    if not all_pts:
        return None
    hull = _hull([(round(p[0], 1), round(p[1], 1)) for p in all_pts])
    total_w = sum(l[2] for l in loads) or 1.0
    cx = sum(l[0] * l[2] for l in loads) / total_w if loads else sum(p[0] for p in all_pts) / len(all_pts)
    cy = sum(l[1] * l[2] for l in loads) / total_w if loads else sum(p[1] for p in all_pts) / len(all_pts)
    taken = [tuple(t) for t in taken]
    best, best_score = None, 1e18
    for r in rooms:
        if r["type"] in ("bathroom", "wc"):
            continue
        pts = _points(r["poly"], r["rect"])
        door_list = [(r["doors"][i], r["doors"][i + 1], r["doors"][i + 2]) for i in range(0, len(r["doors"]) - 2, 3)]
        segs, total = _walk(pts)
        for k in range(48):
            s = (k + 0.5) * total / 48
            on_wall = _at(pts, segs, total, s, 0.0)
            # Outside wall = close to the building outline
            if min(_seg_dist(on_wall, hull[i], hull[(i + 1) % len(hull)]) for i in range(len(hull))) > 40:
                continue
            p = _at(pts, segs, total, s, 15.0)
            if not _inside(pts, p[0], p[1]):
                continue
            if any(math.hypot(p[0] - d[0], p[1] - d[1]) < d[2] / 2 + 40 for d in door_list):
                continue
            if any(math.hypot(p[0] - t[0], p[1] - t[1]) < 35 for t in taken):
                continue
            score = math.hypot(p[0] - cx, p[1] - cy) + penalty.get(r["type"], penalty["other"])
            if score < best_score:
                best, best_score = (p, r), score
    if best is None:
        return None
    p, r = best
    return {"x": p[0], "y": p[1], "room_id": r["id"], "room_name": r["name"],
            "reason": f"On an outside wall of the {r['name']}, close to the load centre", "trust": _trust(w["_cu_source"])}


def _route(start, pts):
    """Nearest-neighbour chain from the consumer unit through every point, drawn as right-angle runs."""
    left = [tuple(p) for p in pts]
    path, cur, length = [list(start)], tuple(start), 0.0
    while left:
        nxt = min(left, key=lambda q: abs(q[0] - cur[0]) + abs(q[1] - cur[1]))
        left.remove(nxt)
        length += abs(nxt[0] - cur[0]) + abs(nxt[1] - cur[1])
        path.append([nxt[0], cur[1]])
        path.append([nxt[0], nxt[1]])
        cur = nxt
    return path, length / 100.0


def _size_cable(start_mm2, method, ca, cg, rating, ib, length_m, vd_limit_pct, prof):
    """Smallest cable from start_mm2 up with Iz*Ca*Cg >= In and voltage drop within the limit."""
    volts = prof["supply"]["voltage_v"]
    sizes = sorted((float(k) for k in prof["cables"] if not k.startswith("_")))
    tried = []
    for size in sizes:
        if size < start_mm2:
            continue
        c = prof["cables"][_cable_key(prof, size)]
        iz = float(c["iz"][method]) * ca * cg
        vd_pct = c["mv_a_m"] * ib * length_m / 1000.0 / volts * 100.0
        if iz >= rating and vd_pct <= vd_limit_pct:
            return size, iz, vd_pct, c, tried
        tried.append((size, iz, vd_pct))
    return None, 0.0, 0.0, None, tried


def _cable_key(prof, size):
    for k in prof["cables"]:
        if not k.startswith("_") and float(k) == size:
            return k
    return str(size)


def _summary(levels):
    """Skill golden rule 3: never 'compliant'. Any ERROR (circuit or whole installation) changes the verdict."""
    if "ERROR" in levels:
        return "Errors found under selected rule profile — fix the open issues, review required"
    return "Passed under selected rule profile — review required"


def design_wiring(cu, rooms, opts):
    """Circuits, cable sizes, breakers and the consumer unit, all from the rule profile (skill design procedure).

    cu: [x, y]. rooms: [{id, name, type, area_m2, centroid, lights: [[x, y, w]], switches: [[x, y]], sockets: [[x, y]],
    loads: [{tag, name, item_id, watts, x, y}]}]. opts: {method, ambient_c, grouped, ra_ohm, main_a, spd}.
    """
    prof = _ref("rule-profile.json")
    defs = _ref("layout-defaults.json")
    w = defs["wiring"]
    volts = prof["supply"]["voltage_v"]
    templates = prof["circuit_templates"]
    ratings = prof["device_ratings_a"]
    cf = prof["correction_factors"]
    method = str(opts["method"])
    ca = float(cf["ca_ambient_pvc70"][str(int(opts["ambient_c"]))])
    cg_table = cf["cg_grouping"]["bunched_enclosed" if method == "A" else "single_layer_wall_method_c"]
    cg = float(cg_table[str(max(1, min(6, int(opts["grouped"]))))])
    drops = w["drops_m"]
    limits = prof["voltage_drop_limit_pct"]
    order = sorted(rooms, key=lambda r: math.hypot(r["centroid"][0] - cu[0], r["centroid"][1] - cu[1]))

    # 1. Divide circuits (314.1): lighting groups, socket groups (kitchen alone), one per dedicated load
    max_pts = prof["lighting_design"]["circuit_limits"]["max_points_per_lighting_circuit"]
    light_groups, cur, n = [], [], 0
    for r in order:
        k = len(r["lights"])
        if k == 0:
            continue
        if cur and n + k > max_pts:
            light_groups.append(cur)
            cur, n = [], 0
        cur.append(r)
        n += k
    if cur:
        light_groups.append(cur)
    if len(light_groups) == 1 and len(light_groups[0]) >= 2:   # at least 2 lighting circuits per house
        g = light_groups[0]
        half = len(g) // 2
        light_groups = [g[:half], g[half:]]
    # A bathroom never gets a lighting circuit of its own: share with an adjoining room (split rule)
    for i, g in enumerate(list(light_groups)):
        if all(r["type"] in ("bathroom", "wc") for r in g) and len(light_groups) > 1:
            j = i - 1 if i > 0 else i + 1
            light_groups[j] = light_groups[j] + g
            light_groups[i] = []
    light_groups = [g for g in light_groups if g]

    radial = templates["SOCKET_RADIAL_20"]
    max_out = prof["rcd"]["max_double_sockets_per_circuit_recommended"]
    socket_groups, cur, area, outs = [], [], 0.0, 0
    for r in order:
        k = len(r["sockets"])
        if k == 0:
            continue
        if r["type"] == "kitchen":
            socket_groups.append([r])
            continue
        if cur and (area + r["area_m2"] > radial["max_area_m2"] or outs + k > max_out):
            socket_groups.append(cur)
            cur, area, outs = [], 0.0, 0
        cur.append(r)
        area += r["area_m2"]
        outs += k
    if cur:
        socket_groups.append(cur)
    # A radial longer than the standard circuit's length is split by room
    split = []
    while socket_groups:
        g = socket_groups.pop(0)
        _, run = _route(cu, [tuple(p) for r in g for p in r["sockets"]])
        n_out = sum(len(r["sockets"]) for r in g)
        est = run * w["route_factor"] + drops["socket_first"] + drops["socket_each"] * max(0, n_out - 1) + drops["cu"]
        if len(g) > 1 and est > radial["max_length_m"]:
            half = len(g) // 2
            socket_groups[:0] = [g[:half], g[half:]]
        else:
            split.append(g)
    socket_groups = split

    circuits = []

    def names(group):
        return ", ".join(r["name"] for r in group)

    for g in light_groups:
        pts = [(p[0], p[1]) for r in g for p in r["lights"]] + [tuple(p) for r in g for p in r["switches"]]
        watts = sum(p[2] for r in g for p in r["lights"])
        drop = drops["light"] * sum(len(r["lights"]) for r in g) + drops["switch"] * sum(len(r["switches"]) for r in g)
        circuits.append({"kind": "lighting", "name": "Lighting · " + names(g), "rooms": [r["name"] for r in g],
                         "template": "LIGHTING", "points": pts, "watts": watts, "pf": templates["LIGHTING"]["pf"],
                         "drop": drop, "count": sum(len(r["lights"]) for r in g),
                         "bathroom": any(r["type"] in ("bathroom", "wc") for r in g)})
    for g in socket_groups:
        pts = [tuple(p) for r in g for p in r["sockets"]]
        area = sum(r["area_m2"] for r in g)
        tkey = "SOCKET_RADIAL_20" if area <= templates["SOCKET_RADIAL_20"]["max_area_m2"] else "SOCKET_RADIAL_32"
        circuits.append({"kind": "sockets", "name": "Sockets · " + names(g), "rooms": [r["name"] for r in g],
                         "template": tkey, "points": pts, "watts": 0.0, "pf": templates[tkey]["pf"],
                         "drop": drops["socket_first"] + drops["socket_each"] * max(0, len(pts) - 1),
                         "count": len(pts), "area": area, "bathroom": False})
    for r in order:
        for ld in r["loads"]:
            item = find_item(ld["item_id"]) or {"pf": 1.0, "trust": "not in rule profile", "outlet": ""}
            circuits.append({"kind": "dedicated", "name": f"{ld['tag']} · {ld['name']}", "rooms": [r["name"]],
                             "template": item.get("template"), "item": item, "points": [(ld["x"], ld["y"])],
                             "watts": float(ld["watts"]), "pf": float(item.get("pf", 1.0)), "tag": ld["tag"],
                             "drop": drops["appliance"], "count": 1, "bathroom": r["type"] in ("bathroom", "wc"),
                             "special": item.get("demand") in ("AC", "DEDICATED") or bool(item.get("motor"))})

    # 2-6. Per circuit: route, Ib, In, Iz, voltage drop, cpc
    for c in circuits:
        path, run = _route(cu, c["points"])
        length = run * w["route_factor"] + c["drop"] + drops["cu"]
        c["path"] = path
        c["length_m"] = length
        checks = []
        t = templates.get(c["template"]) if c["template"] else None
        if c["kind"] == "sockets":
            rating = int(t["device"][1:])
            curve = t["device"][0]
            ib = float(rating)
            checks.append(_check("PASS", f"Socket final: Ib taken as In = {rating} A (no diversity on socket finals); {c['count']} outlets, {c['area']:.0f} m² ≤ {t['max_area_m2']} m²",
                                 "311.1 / 433.1.1", "rule profile circuit_templates"))
        elif c["kind"] == "lighting":
            ib = c["watts"] / (volts * c["pf"])
            rating = int(t["device"][1:])
            if ib > rating:
                rating = next((r for r in ratings if r >= ib), rating)
            curve = t["device"][0]
            cap = t["max_device_a"]
            checks.append(_check("PASS" if rating <= cap else "ERROR",
                                 f"Ib = {c['watts']:.0f} W / {volts} V = {ib:.2f} A ≤ In {curve}{rating} (lighting ≤ {cap} A)",
                                 "433.1.1 / 559.6.1.6", t["_max_device_source"]))
        else:
            prot = protection(c["item"], c["watts"])
            ib = prot["ib"]
            curve, rating = prot["breaker"][0], int(prot["breaker"][1:])
            checks += [ck for ck in prot["checks"] if "cable" not in ck["text"]]
        start = float(t["cable_mm2"]) if t else 1.5
        vd_cat = (t or {}).get("vd_category", "other")
        vd_limit = float(limits[vd_cat])
        size, iz, vd_pct, cab, tried = _size_cable(start, method, ca, cg, rating, ib, length, vd_limit, prof)
        if size is None:
            checks.append(_check("ERROR", f"No cable in the profile meets Iz ≥ {rating} A and voltage drop ≤ {vd_limit}% over {length:.0f} m (method {method}).",
                                 "433.1.1 / 525", limits["_source"]))
            size, iz, vd_pct = start, 0.0, 0.0
            cab = prof["cables"][_cable_key(prof, start)]
        else:
            if size > start:
                why = ", ".join(f"{s:g} mm² gave Iz {i:.1f} A / VD {v:.1f}%" for s, i, v in tried)
                checks.append(_check("WARNING", f"Cable upsized from {start:g} to {size:g} mm² ({why}).", "433.1.1 / 525", cab["_source"]))
            checks.append(_check("PASS", f"Iz = {cab['iz'][method]} A × Ca {ca} × Cg {cg} = {iz:.1f} A ≥ In {rating} A ({size:g} mm², method {method})",
                                 "433.1.1, Appendix 4", cab["_source"]))
            checks.append(_check("PASS", f"Voltage drop {cab['mv_a_m']} mV/A/m × {ib:.1f} A × {length:.0f} m = {vd_pct:.2f}% ≤ {vd_limit:g}%",
                                 "525, Appendix 4", limits["_source"]))
        checks.append(_check("INFO", f"Length {length:.0f} m estimated from the plan route plus drops; measure on site.", "Input", w["_route_source"]))
        if t and t.get("max_length_m") and length > t["max_length_m"]:
            checks.append(_check("WARNING", f"Length {length:.0f} m is over the standard circuit's {t['max_length_m']} m: check the inputs.",
                                 "Sanity check (2008 Table C9.2)", templates["_note"]))
        cpc = cab["cpc_mm2"]
        mincpc = prof["min_cpc_mm2_with_mcb"]
        checks.append(_check("PASS", f"cpc {cpc:g} mm² ≥ {mincpc['B_6_to_50']:g} mm² minimum with {curve}{rating} MCB",
                             "434 / 543.1", mincpc["_source"]))
        if c["kind"] == "sockets":
            rcd_note = prof["rcd"]["required_for"]["SOCKET_LE_32A"]
        elif c["kind"] == "lighting":
            rcd_note = prof["rcd"]["required_for"]["LIGHTING_DOMESTIC"]
        else:
            rcd_note = prof["rcd"]["required_for"]["BATHROOM_ALL"] if c["bathroom"] else prof["rcd"]["required_for"]["CONCEALED_LT_50MM"]
        checks.append(_check("PASS", "30 mA RCD additional protection (split-load RCCB)", "411.3.3 / 411.3.4 / 701.411.3.3", rcd_note))
        levels = [ck["level"] for ck in checks]
        c.update({"ib": ib, "rating": rating, "curve": curve, "breaker": f"{curve}{rating}", "cable": size, "cpc": cpc,
                  "iz": iz, "vd_pct": vd_pct, "vd_limit": vd_limit, "checks": checks,
                  "status": "ERROR" if "ERROR" in levels else ("WARNING" if "WARNING" in levels else "PASS")})

    # 7-9. Split-load board: lighting circuits alternate between the RCCBs, then the rest balance by Ib
    load = {"RCD1": 0.0, "RCD2": 0.0}
    lights = [c for c in circuits if c["kind"] == "lighting"]
    for i, c in enumerate(lights):
        c["rcd"] = "RCD1" if i % 2 == 0 else "RCD2"
        load[c["rcd"]] += c["ib"]
    for c in sorted((c for c in circuits if c["kind"] != "lighting"), key=lambda c: -c["ib"]):
        c["rcd"] = min(load, key=load.get)
        load[c["rcd"]] += c["ib"]
    kind_order = {"lighting": 0, "sockets": 1, "dedicated": 2}
    circuits.sort(key=lambda c: (c["rcd"], kind_order[c["kind"]], c["name"]))
    for i, c in enumerate(circuits):
        c["id"] = f"C{i + 1}"
        c["spd"] = bool(opts["spd"])

    main_a = int(opts["main_a"])
    rccb = next((r for r in w["rccb_ratings_a"] if r >= main_a), w["rccb_ratings_a"][-1])
    mods = w["modules"]
    used = mods["main_switch"] + 2 * mods["rccb"] + (mods["spd"] if opts["spd"] else 0) + mods["mcb"] * len(circuits)
    row = w["row_modules"]
    spare_min = w["spare_ways_min_pct"]
    rows = max(1, math.ceil(used / (row * (1 - spare_min / 100.0))))
    spare_pct = (rows * row - used) / (rows * row) * 100.0

    # Whole-installation checks: TT earth electrode, Ze/PFC, max demand, spare ways, lighting split
    inst = []
    tt = prof["tt"]
    ra = float(opts.get("ra_ohm") or 0)
    idn = prof["rcd"]["additional_protection_ma"] / 1000.0
    if ra <= 0:
        inst.append(_check("WARNING", "Earth electrode resistance RA not entered: RA × IΔn ≤ 50 V cannot be checked.", "411.5.3", tt["_source"]))
    else:
        touch = ra * idn
        inst.append(_check("PASS" if touch <= tt["touch_voltage_limit_v"] else "ERROR",
                           f"RA {ra:g} Ω × IΔn {idn * 1000:g} mA = {touch:.1f} V ≤ {tt['touch_voltage_limit_v']} V", "411.5.3", tt["_source"]))
        if ra > tt["max_recommended_electrode_ohm"]:
            inst.append(_check("WARNING", f"RA {ra:g} Ω is above the recommended {tt['max_recommended_electrode_ohm']} Ω: improve the earth electrode.", "411.5.3", tt["_source"]))
    if prof["supply"]["ze_ohm"] is None or prof["supply"]["pfc_ka"] is None:
        inst.append(_check("WARNING", "Ze and prospective fault current are not in the rule profile: ask CEB/LECO (SQCR Reg 64) to confirm MCB breaking capacity.",
                           "434 / 536", prof["supply"]["_source_earthing"]))
    eb = prof["earthing_bonding"]
    inst.append(_check("INFO", f"TT earth electrode; earthing conductor {eb['typical_domestic_earthing_conductor_mm2']} mm² (TT minimum {eb['tt_earthing_conductor_min_mm2']} mm²); main bonding {eb['typical_main_bonding_mm2']} mm² to incoming metal water/gas pipes.",
                       "542 / 544", eb["_source"]))
    n_light = len(lights)
    inst.append(_check("PASS" if n_light >= 2 else "WARNING", f"{n_light} lighting circuit(s), split across both RCCBs",
                       "Lighting split rule", prof["lighting_design"]["circuit_limits"]["_source"]))
    inst.append(_check("PASS" if spare_pct >= spare_min else "WARNING", f"Spare capacity {spare_pct:.0f}% of {rows * row} modules (≥ {spare_min}% wanted)",
                       "Board size", w["_board_source"]))
    if opts["spd"]:
        inst.append(_check("INFO", "Type 2 SPD after the main switch protects every circuit.", "443 / 534", "design choice"))
    md = max_demand(sum(p[2] for r in rooms for p in r["lights"]),
                    [[r["type"], len(r["sockets"])] for r in rooms],
                    [{"name": ld["name"], "demand": (find_item(ld["item_id"]) or {}).get("demand", "DEDICATED"), "watts": ld["watts"]} for r in rooms for ld in r["loads"]])
    inst.append(_check(md["level"], f"Maximum demand {md['ib_a']:.1f} A of {main_a} A main switch ({md['ib_a'] / main_a * 100:.0f}%)", "311.1", md["trust"]))

    for c in circuits:
        c.pop("item", None)
        c.pop("points", None)
        c["rooms"] = list(c["rooms"])
    return {
        "circuits": circuits,
        "board": {"main_a": main_a, "spd": bool(opts["spd"]), "rccb_a": rccb, "rccb_ma": prof["rcd"]["additional_protection_ma"],
                  "rccb_type": w["rccb_type"], "rows": rows, "row_modules": row, "used_modules": used, "spare_pct": spare_pct,
                  "rcd_load_a": load, "trust": _trust(w["_rccb_source"])},
        "checks": inst,
        "method": method, "ca": ca, "cg": cg,
        "summary": _summary([c["status"] for c in circuits] + [k["level"] for k in inst]),
    }



# ---- Wiring booklet ----

def booklet_meta():
    """Standard, supply and input labels for the booklet cover."""
    prof = _ref("rule-profile.json")
    w = _ref("layout-defaults.json")["wiring"]
    sup = prof["supply"]
    return {"standard": prof["standard"], "profile_id": prof["profile_id"], "status": prof["status"],
            "voltage_v": sup["voltage_v"], "frequency_hz": sup["frequency_hz"], "phases": sup["phases"],
            "earthing": sup["earthing_system"], "methods": w["installation_methods"]}


def bill_of_materials(circuits, board, devices):
    """Cable lengths per size, protective devices and accessories.

    circuits: [{cable, cpc, length_m, breaker}]; board: {main_a, spd, rccb_a, rccb_ma, rccb_type, rows, row_modules};
    devices: [{kind, spec, outlet}]. Returns [{group, item, spec, qty, unit, note, trust}].
    """
    prof = _ref("rule-profile.json")
    defs = _ref("layout-defaults.json")
    bom = defs["bom"]
    lines = []

    def add(group, item, spec, qty, unit, note="", trust=""):
        lines.append({"group": group, "item": item, "spec": spec, "qty": float(qty), "unit": unit, "note": note, "trust": trust})

    # Cables: one line per conductor size, total of the circuits that use it
    by_size = {}
    for c in circuits:
        key = (float(c["cable"]), float(c["cpc"]))
        by_size.setdefault(key, [0.0, []])
        by_size[key][0] += float(c["length_m"])
        by_size[key][1].append(c["id"])
    allow = bom["cable_allowance_pct"]
    step = bom["round_up_to_m"]
    for (size, cpc), (length, ids) in sorted(by_size.items()):
        buy = math.ceil(length * (1 + allow / 100.0) / step) * step
        add("Cables", f"Twin & earth {size:g}/{cpc:g} mm²", prof["cables"]["_type"], round(length, 1), "m",
            f"{', '.join(ids)} · buy about {buy} m (+{allow}%)", _trust(bom["_source"]))
    eb = prof["earthing_bonding"]
    add("Cables", f"Earthing conductor {eb['typical_domestic_earthing_conductor_mm2']} mm²", "green/yellow, consumer unit to earth electrode",
        0, "m", "measure on site", _trust(eb["_source"]))
    add("Cables", f"Main protective bonding {eb['typical_main_bonding_mm2']} mm²", "green/yellow, to incoming metal water / gas pipes",
        0, "m", "measure on site", _trust(eb["_source"]))

    # Protective devices and the enclosure
    add("Consumer unit", "Main switch", f"2-pole isolator {board['main_a']} A", 1, "pcs", "", "rule profile max_demand")
    if board["spd"]:
        add("Consumer unit", "Surge protective device", "Type 2, 1P+N", 1, "pcs", "", "design choice")
    add("Consumer unit", "RCCB", f"2-pole {board['rccb_a']} A, {board['rccb_ma']} mA, Type {board['rccb_type']}", 2, "pcs",
        "split load", _trust(defs["wiring"]["_rccb_source"]))
    mcbs = {}
    for c in circuits:
        mcbs[c["breaker"]] = mcbs.get(c["breaker"], 0) + 1
    for b in sorted(mcbs, key=lambda x: (x[0], int(x[1:]))):
        add("Consumer unit", "MCB", f"Type {b[0]} {b[1:]} A, 1-pole, {prof['mcb_breaking_capacity_ka_typical_domestic']['value']} kA", mcbs[b], "pcs",
            "", "rule profile circuit_templates")
    add("Consumer unit", "Enclosure", f"{board['rows']} row(s) × {board['row_modules']} modules", 1, "pcs",
        f"{board['used_modules']} modules used", _trust(defs["wiring"]["_board_source"]))
    add("Consumer unit", "Earth electrode", "rod + inspection pit (TT)", 1, "pcs", "test RA after installing", _trust(prof["tt"]["_source"]))

    # Accessories from the devices on the plan
    acc = {}
    for d in devices:
        if d["kind"] == "Lighting point":
            key = ("Lighting", "Light point", d["spec"] or "LED")
        elif "switch" in d["kind"].lower():
            key = ("Switches", "Light switch", d["spec"] or "1-gang 1-way")
        elif d["kind"].startswith("Socket"):
            key = ("Sockets", "Socket outlet", d["spec"] or prof["sockets"]["type"])
        elif d["kind"] == "Plug base":
            key = ("Appliance outlets", d["outlet"].split(" · ")[0] or "Dedicated outlet", d["spec"])
        else:
            continue
        acc[key] = acc.get(key, 0) + 1
    for (group, item, spec), n in sorted(acc.items()):
        add(group, item, spec, n, "pcs")
    return lines
::py::
