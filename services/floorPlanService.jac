import from services.planConvert { convert_plan }
import from services.planVision { scan_start }
import from services.layoutDesigner {
    design_room, load_catalog, find_item, ac_sizing, ac_room_types_excluded,
    protection, place_appliance, place_by_door, max_demand
}
import from services.roomAgent { identify_rooms, RoomGuess }
import from jaclang.byllm.lib { Image }

node Project {
    has name: str = "WireWise Residence";
    has standard: str = "BS 7671";
}

node Level {
    has name: str = "Ground";
    has order: int = 0;
}

node Room {
    has name: str = "";
    has x: float = 0.0;
    has y: float = 0.0;
    has width: float = 0.0;
    has height: float = 0.0;
    has room_type: str = "room";
    has poly: list[float] = [];     # outline from a plan scan, flattened x,y in canvas cm (empty = rectangle)
    has doors: list[float] = [];    # doorways from a plan scan, flattened x,y,width in canvas cm
}

node Device {
    has kind: str = "Socket 16A";
    has x: float = 0.0;
    has y: float = 0.0;
    has rotation: int = 0;
    has label: str = "";
    has spec: str = "";             # e.g. "12 W LED · 1100 lm"
    has auto: bool = False;         # placed by the layout designer (replaced on re-run)
    # Appliance loads (Appliances step): the appliance and its plug base share a tag, e.g. "AC1"
    has tag: str = "";
    has item_id: str = "";
    has load_w: float = 0.0;
    has demand: str = "";           # max-demand group: AC, WATER_HEATER_INSTANT, DEDICATED, ...
    has ib: float = 0.0;
    has breaker: str = "";
    has cable: float = 0.0;
    has outlet: str = "";
    has notes: list[dict[str, str]] = [];
}

"""Imported floor plan drawn under the rooms (one per level)."""
node Background {
    has image: str = "";
    has x: float = 50.0;
    has y: float = 50.0;
    has width: float = 0.0;
    has height: float = 0.0;
    has source: str = "";
    has scaled: bool = False;
}

"""AI room suggestion from a plan scan, waiting for the user to confirm, change or reject it."""
node RoomSuggestion {
    has region: int = 0;
    has room_type: str = "other";
    has name: str = "";
    has confidence: float = 0.0;
    has alternatives: list[str] = [];
    has status: str = "pending";    # pending | ask | confirmed | rejected
    has x: float = 0.0;
    has y: float = 0.0;
    has width: float = 0.0;
    has height: float = 0.0;
    has poly: list[float] = [];     # outline, flattened x,y pairs in canvas cm
    has doors: list[float] = [];    # doorways, flattened x,y,width in canvas cm
    has area_m2: float = 0.0;
    has sized: bool = False;        # True when the plan has a real scale
    has written_label: str = "";
    has written_size: str = "";
}

edge HasLevel: Project --> Level {}
edge HasRoom: Level --> Room {}
edge HasDevice: Room --> Device {}

obj PlanElement {
    has id: str;
    has kind: str;
    has x: float;
    has y: float;
    has width: float = 0.0;
    has height: float = 0.0;
    has label: str = "";
}

obj BackgroundInfo {
    has ok: bool = True;
    has message: str = "";
    has image: str = "";
    has x: float = 50.0;
    has y: float = 50.0;
    has width: float = 0.0;
    has height: float = 0.0;
    has source: str = "";
    has scaled: bool = False;
}

obj SuggestionInfo {
    has id: str;
    has region: int;
    has room_type: str;
    has name: str;
    has confidence: float;
    has alternatives: list[str];
    has status: str;
    has x: float;
    has y: float;
    has width: float;
    has height: float;
    has poly: list[float];
    has area_m2: float;
    has sized: bool;
    has written_label: str;
    has written_size: str;
}

obj ScanResult {
    has ok: bool = True;
    has message: str = "";
    has ai: bool = True;            # False when the AI model could not be reached
    has suggestions: list[SuggestionInfo] = [];
}

obj FloorPlan {
    has name: str;
    has level: str;
    has rooms: list[PlanElement];
    has devices: list[PlanElement];
}

"""How much work hangs off a project: rooms, devices, imported plan and pending suggestions."""
def _project_weight(project: Project) -> int {
    weight = 0;
    for level in [project ->:HasLevel:->] {
        for room in [level ->:HasRoom:->] {
            weight += 10 + len([room -->][?:Device]);
        }
        weight += 5 * len([level -->][?:Background]) + len([level -->][?:RoomSuggestion]);
    }
    return weight;
}

def _get_level() -> Level {
    projects = [root -->][?:Project];
    if len(projects) == 0 {
        project = Project(name="WireWise Residence");
        root ++> project;
    } elif len(projects) == 1 {
        project = projects[0];
    } else {
        # Parallel first requests can each create a Project, and the database does not keep them in
        # a fixed order: always use the one holding the most work (ties: lowest id) and drop empty duplicates.
        ranked = sorted(projects, key=lambda (p: Project) -> tuple[int, str] { return (-_project_weight(p), jid(p)); });
        project = ranked[0];
        for extra in ranked[1:] {
            if _project_weight(extra) == 0 {
                for lv in [extra ->:HasLevel:->] {
                    del lv;
                }
                del extra;
            }
        }
    }
    levels = [project ->:HasLevel:->];
    if len(levels) == 0 {
        level = Level(name="Ground", order=0);
        project +>:HasLevel:+> level;
        return level;
    }
    levels = sorted(levels, key=lambda (l: Level) -> tuple[int, str] { return (l.order, jid(l)); });
    return levels[0];
}

def _clear_level(level: Level) -> None {
    for room in [level ->:HasRoom:->] {
        for device in [room -->][?:Device] {
            del device;
        }
        del room;
    }
}

def _read_plan(level: Level) -> FloorPlan {
    projects = [root -->][?:Project];
    rooms: list[PlanElement] = [];
    devices: list[PlanElement] = [];
    for room in [level ->:HasRoom:->] {
        rooms.append(PlanElement(id=jid(room), kind=room.room_type, x=room.x, y=room.y, width=room.width, height=room.height, label=room.name));
        for device in [room -->][?:Device] {
            devices.append(PlanElement(id=jid(device), kind=device.kind, x=device.x, y=device.y, label=device.label));
        }
    }
    return FloorPlan(name=projects[0].name, level=level.name, rooms=rooms, devices=devices);
}

"""Load the current plan. A brand-new project starts empty so the welcome dialog shows."""
def:pub get_floor_plan() -> FloorPlan {
    return _read_plan(_get_level());
}

"""Wipe the current level and start from an empty canvas."""
def:pub start_blank_plan() -> FloorPlan {
    level = _get_level();
    _clear_level(level);
    return _read_plan(level);
}

"""Replace the current level with the sample flat."""
def:pub load_sample_flat() -> FloorPlan {
    level = _get_level();
    _clear_level(level);
    room_a = Room(name="Kitchen", x=120.0, y=90.0, width=270.0, height=190.0, room_type="kitchen");
    room_b = Room(name="Living", x=390.0, y=90.0, width=300.0, height=260.0, room_type="living");
    room_c = Room(name="Hall", x=120.0, y=280.0, width=160.0, height=130.0, room_type="hall");
    level +>:HasRoom:+> room_a;
    level +>:HasRoom:+> room_b;
    level +>:HasRoom:+> room_c;
    room_a ++> Device(kind="Socket 16A", x=160.0, y=270.0, label="S1");
    room_a ++> Device(kind="Lighting point", x=255.0, y=170.0, label="L1");
    room_b ++> Device(kind="Lighting point", x=535.0, y=210.0, label="L2");
    return _read_plan(level);
}

"""Add a rectangular room drawn on the canvas (canvas units: 1 = 1 cm)."""
def:pub add_room(x: float, y: float, width: float, height: float) -> FloorPlan {
    level = _get_level();
    count = len([level ->:HasRoom:->]) + 1;
    level +>:HasRoom:+> Room(name=f"Room {count}", x=x, y=y, width=width, height=height, room_type="room");
    return _read_plan(level);
}

def:pub add_plan_element(kind: str, x: float, y: float) -> FloorPlan {
    level = _get_level();
    rooms = [level ->:HasRoom:->];
    if len(rooms) == 0 {
        room = Room(name="Main room", x=120.0, y=100.0, width=420.0, height=300.0, room_type="room");
        level +>:HasRoom:+> room;
        rooms = [room];
    }
    target = rooms[0];
    for candidate in rooms {
        if x >= candidate.x and x <= candidate.x + candidate.width and y >= candidate.y and y <= candidate.y + candidate.height {
            target = candidate;
        }
    }
    label = f"{kind[:1]}{len([target -->][?:Device]) + 1}";
    target ++> Device(kind=kind, x=x, y=y, label=label);
    return _read_plan(level);
}

def _background(level: Level) -> Background | None {
    found = [level -->][?:Background];
    if len(found) == 0 { return None; }
    return found[0];
}

def _bg_info(bg: Background | None, ok: bool = True, message: str = "") -> BackgroundInfo {
    if bg == None {
        return BackgroundInfo(ok=ok, message=message);
    }
    return BackgroundInfo(ok=ok, message=message, image=bg.image, x=bg.x, y=bg.y, width=bg.width, height=bg.height, source=bg.source, scaled=bg.scaled);
}

"""Get the imported floor plan for the current level (empty image if none)."""
def:pub get_background() -> BackgroundInfo {
    return _bg_info(_background(_get_level()));
}

"""Import a floor plan file sent as a data URL. Supports images, SVG, PDF and DXF."""
def:pub import_background(filename: str, data_url: str) -> BackgroundInfo {
    level = _get_level();
    result = convert_plan(filename, data_url) as dict;
    if not result["ok"] {
        return _bg_info(_background(level), False, result["message"] as str);
    }
    bg = _background(level);
    if bg == None {
        bg = Background();
        level ++> bg;
    }
    bg.image = result["image"] as str;
    bg.x = 50.0;
    bg.y = 50.0;
    bg.width = result["width_cm"] as float;
    bg.height = result["height_cm"] as float;
    bg.source = result["source"] as str;
    bg.scaled = result["scaled"] as bool;
    return _bg_info(bg, True, result["message"] as str);
}

"""Resize the imported plan by a factor (from the Set scale tool), keeping its top-left corner."""
def:pub set_background_scale(factor: float) -> BackgroundInfo {
    bg = _background(_get_level());
    if bg == None or factor <= 0.0 {
        return _bg_info(bg, False, "Nothing to scale.");
    }
    bg.width = bg.width * factor;
    bg.height = bg.height * factor;
    bg.scaled = True;
    return _bg_info(bg, True, "Scale set.");
}

"""Remove the imported plan from the current level."""
def:pub clear_background() -> BackgroundInfo {
    bg = _background(_get_level());
    if bg != None {
        del bg;
    }
    return BackgroundInfo();
}

# ---- AI room identification ("Suggest wiring", step 1) ----

glob ASK_BELOW: float = 0.75;   # below this confidence the user is asked to pick the type

glob ROOM_NAMES: dict[str, str] = {
    "living": "Living room", "bedroom": "Bedroom", "kitchen": "Kitchen", "bathroom": "Bathroom",
    "wc": "WC", "dining": "Dining room", "hall": "Hall", "utility": "Utility",
    "office": "Office", "storage": "Storage", "garage": "Garage", "other": "Room", "not_a_room": "Not a room"
};

def _suggestions(level: Level) -> list[RoomSuggestion] {
    return [level -->][?:RoomSuggestion];
}

def _suggestion_info(s: RoomSuggestion) -> SuggestionInfo {
    return SuggestionInfo(
        id=jid(s), region=s.region, room_type=s.room_type, name=s.name, confidence=s.confidence,
        alternatives=s.alternatives, status=s.status, x=s.x, y=s.y, width=s.width, height=s.height,
        poly=s.poly, area_m2=s.area_m2, sized=s.sized, written_label=s.written_label, written_size=s.written_size
    );
}

def _scan_result(level: Level, ok: bool = True, message: str = "", ai: bool = True) -> ScanResult {
    items = [_suggestion_info(s) for s in _suggestions(level)];
    items.sort(key=lambda (i: SuggestionInfo) -> int { return i.region; });
    return ScanResult(ok=ok, message=message, ai=ai, suggestions=items);
}

"""Likely types from size alone, used when the AI is unavailable or unsure."""
def _size_guesses(area_m2: float, share: float, sized: bool) -> list[str] {
    small = area_m2 < 3.5 if sized else share < 0.04;
    medium = area_m2 < 7.0 if sized else share < 0.09;
    large = area_m2 < 16.0 if sized else share < 0.22;
    if small { return ["wc", "storage", "utility"]; }
    if medium { return ["bathroom", "utility", "hall"]; }
    if large { return ["bedroom", "kitchen", "office"]; }
    return ["living", "kitchen", "bedroom"];
}

def _region_notes(regions: list[dict[str, any]], total_px: float, cm_per_px: float, sized: bool) -> str {
    lines: list[str] = [];
    for r in regions {
        w = r["w"] as float;
        h = r["h"] as float;
        share = (r["area"] as float) / total_px * 100.0;
        line = f"Region {r['id']}: {share:.0f}% of floor area, proportions {max(w, h) / max(1.0, min(w, h)):.1f}:1";
        if sized {
            line += f", about {w * cm_per_px / 100.0:.1f} x {h * cm_per_px / 100.0:.1f} m";
        }
        near = r["near"] as list[int];
        if len(near) > 0 {
            line += ", next to regions " + ", ".join([str(n) for n in near]);
        }
        lines.append(line);
    }
    return "\n".join(lines);
}

def _ai_error_text(err: Exception) -> str {
    text = str(err);
    if "api_key" in text.lower() or "authentication" in text.lower() or "auth" in type(err).__name__.lower() {
        return "AI is not set up (no API key), so please pick each room's type.";
    }
    return "AI could not read the plan (" + text[:120] + "), so please pick each room's type.";
}

"""Rooms already found for this level's plan (survives page reloads)."""
def:pub get_suggestions() -> ScanResult {
    return _scan_result(_get_level());
}

"""Scan the imported plan: find rooms geometrically, then let the AI agent name them."""
def:pub scan_plan() -> ScanResult {
    level = _get_level();
    bg = _background(level);
    if bg == None {
        return ScanResult(ok=False, message="Import a floor plan first.");
    }
    for old in _suggestions(level) {
        del old;
    }
    scan = scan_start(bg.image) as dict[str, any];
    regions = scan["regions"] as list[dict[str, any]];
    if len(regions) == 0 {
        return ScanResult(ok=False, message="No enclosed rooms found on this plan. Draw them with the Room tool (R).");
    }
    # Working raster px -> canvas cm (1 canvas unit = 1 cm)
    kx = bg.width / (scan["width"] as float);
    ky = bg.height / (scan["height"] as float);
    total_px = 0.0;
    for r in regions {
        total_px += r["area"] as float;
    }
    # Rooms already on the plan (from an earlier scan or drawn by hand) are not suggested again
    existing = [level ->:HasRoom:->];
    fresh: list[dict[str, any]] = [];
    for r in regions {
        cx = bg.x + (r["cx"] as float) * kx;
        cy = bg.y + (r["cy"] as float) * ky;
        if not any([cx >= e.x and cx <= e.x + e.width and cy >= e.y and cy <= e.y + e.height for e in existing]) {
            fresh.append(r);
        }
    }
    skipped = len(regions) - len(fresh);
    if len(fresh) == 0 {
        return ScanResult(ok=True, message=f"All {len(regions)} rooms on this plan are already added.");
    }
    regions = fresh;
    guesses: dict[int, RoomGuess] = {};
    ai_ok = True;
    message = "";
    try {
        found = identify_rooms(
            Image(url=scan["marked"] as str), scan["scan_id"] as str,
            _region_notes(regions, total_px, kx, bg.scaled)
        );
        for g in found {
            guesses[g.region] = g;
        }
    } except Exception as err {
        ai_ok = False;
        message = _ai_error_text(err);
    }
    used: dict[str, int] = {};
    for r in regions {
        rid = r["id"] as int;
        area_m2 = (r["area"] as float) * kx * ky / 10000.0;
        share = (r["area"] as float) / total_px;
        poly: list[float] = [];
        for pt in r["poly"] as list[list[int]] {
            poly.append(bg.x + (pt[0] as float) * kx);
            poly.append(bg.y + (pt[1] as float) * ky);
        }
        doors: list[float] = [];
        for d in r["doors"] as list[list[float]] {
            doors.append(bg.x + d[0] * kx);
            doors.append(bg.y + d[1] * ky);
            doors.append(d[2] * (kx + ky) / 2.0);
        }
        room_type = "other";
        name = "";
        confidence = 0.0;
        alternatives = _size_guesses(area_m2, share, bg.scaled);
        written_label = "";
        written_size = "";
        status = "ask";
        if rid in guesses {
            g = guesses[rid];
            room_type = str(g.room_type.value);
            name = g.name.strip();
            confidence = max(0.0, min(1.0, g.confidence));
            written_label = g.written_label;
            written_size = g.written_size;
            ai_alts = [str(a.value) for a in g.alternatives if a != g.room_type];
            if len(ai_alts) > 0 {
                alternatives = ai_alts[:3];
            }
            if room_type == "not_a_room" {
                status = "rejected" if confidence >= ASK_BELOW else "ask";
            } elif confidence >= ASK_BELOW and room_type != "other" {
                status = "pending";
            }
        }
        if name == "" and room_type != "other" and room_type != "not_a_room" {
            used[room_type] = used.get(room_type, 0) + 1;
            name = ROOM_NAMES[room_type];
            if used[room_type] > 1 {
                name += f" {used[room_type]}";
            }
        }
        level ++> RoomSuggestion(
            region=rid, room_type=room_type, name=name, confidence=confidence,
            alternatives=alternatives, status=status,
            x=bg.x + (r["x"] as float) * kx, y=bg.y + (r["y"] as float) * ky,
            width=(r["w"] as float) * kx, height=(r["h"] as float) * ky,
            poly=poly, doors=doors, area_m2=area_m2, sized=bg.scaled,
            written_label=written_label, written_size=written_size
        );
    }
    if message == "" {
        asks = len([1 for s in _suggestions(level) if s.status == "ask"]);
        message = f"Found {len(regions)} rooms." + (f" {asks} need your answer." if asks > 0 else " Check and confirm them.");
    }
    if skipped > 0 {
        message += f" {skipped} already on the plan were skipped.";
    }
    return _scan_result(level, True, message, ai_ok);
}

"""First of "Bedroom", "Bedroom 2", ... not used by another suggestion or room on this level."""
def _free_name(level: Level, base: str, me: RoomSuggestion) -> str {
    taken = [s.name for s in _suggestions(level) if s != me and s.status != "rejected"] + [r.name for r in [level ->:HasRoom:->]];
    if base not in taken {
        return base;
    }
    n = 2;
    while f"{base} {n}" in taken {
        n += 1;
    }
    return f"{base} {n}";
}

"""Confirm, reject or reset one suggestion, optionally changing its type or name."""
def:pub review_suggestion(suggestion_id: str, action: str, room_type: str = "", name: str = "") -> ScanResult {
    level = _get_level();
    for s in _suggestions(level) {
        if jid(s) != suggestion_id {
            continue;
        }
        if room_type != "" and room_type != s.room_type {
            # Follow the new type unless the user (or the plan's own label) named the room
            if s.name == "" or s.name.startswith(ROOM_NAMES.get(s.room_type, "Room")) {
                s.name = _free_name(level, ROOM_NAMES.get(room_type, "Room"), s);
            }
            s.room_type = room_type;
        }
        if name.strip() != "" {
            s.name = name.strip();
        }
        if action == "confirm" {
            s.status = "rejected" if s.room_type == "not_a_room" else "confirmed";
        } elif action == "reject" {
            s.status = "rejected";
        } elif action == "reset" {
            s.status = "pending" if s.room_type != "other" else "ask";
        }
    }
    return _scan_result(level);
}

"""Confirm every suggestion the AI was sure about (rooms needing an answer are left alone)."""
def:pub confirm_all_suggestions() -> ScanResult {
    level = _get_level();
    for s in _suggestions(level) {
        if s.status == "pending" {
            s.status = "confirmed";
        }
    }
    return _scan_result(level);
}

"""Turn confirmed suggestions into rooms on the plan; unanswered ones stay for later."""
def:pub apply_suggestions() -> FloorPlan {
    level = _get_level();
    for s in _suggestions(level) {
        if s.status == "confirmed" {
            level +>:HasRoom:+> Room(
                name=s.name, x=s.x, y=s.y, width=s.width, height=s.height,
                room_type=s.room_type, poly=s.poly, doors=s.doors
            );
            del s;
        } elif s.status == "rejected" {
            del s;
        }
    }
    return _read_plan(level);
}

# ---- Lights, switches and sockets per room ("Suggest wiring", step 2) ----

obj LayoutCheck {
    has level: str;     # PASS | INFO | WARNING | ERROR
    has text: str;
    has rule: str;
    has trust: str;
}

obj LayoutPoint {
    has kind: str;
    has x: float;
    has y: float;
    has label: str;
    has spec: str = "";
    has watts: float = 0.0;
}

obj RoomLayout {
    has room_id: str;
    has name: str;
    has room_type: str;
    has area_m2: float;
    has lux: int;
    has lamp_watts: int;
    has lamp_lumens: int;
    has lumens_needed: float;
    has lights: int;
    has sockets: int;
    has points: list[LayoutPoint];
    has checks: list[LayoutCheck];
}

obj LayoutResult {
    has ok: bool = True;
    has message: str = "";
    has sized: bool = False;
    has placed: bool = False;       # True when the plan already holds this layout
    has rooms: list[RoomLayout] = [];
    has total_lights: int = 0;
    has total_sockets: int = 0;
    has total_switches: int = 0;
    has lighting_watts: float = 0.0;
}

glob LIGHT_KIND: str = "Lighting point";
glob SWITCH_KIND: str = "One-way switch";
glob SOCKET_KIND: str = "Socket 16A";

def _room_layout(room: Room, sized: bool) -> RoomLayout {
    d = design_room(room.room_type, room.poly, (room.x, room.y, room.width, room.height), room.doors, sized) as dict[str, any];
    spec = f"{d['lamp_watts']} W LED · {d['lamp_lumens']} lm";
    points: list[LayoutPoint] = [];
    n = 0;
    for p in d["lights"] as list[list[float]] {
        n += 1;
        points.append(LayoutPoint(kind=LIGHT_KIND, x=p[0], y=p[1], label=f"L{n}", spec=spec, watts=d["lamp_watts"] as float));
    }
    sw = d["switch"] as list[float];
    points.append(LayoutPoint(kind=SWITCH_KIND, x=sw[0], y=sw[1], label="SW", spec="1-gang 1-way"));
    n = 0;
    for p in d["sockets"] as list[list[float]] {
        n += 1;
        points.append(LayoutPoint(kind=SOCKET_KIND, x=p[0], y=p[1], label=f"S{n}", spec="Twin 13 A BS 1363"));
    }
    checks = [
        LayoutCheck(level=c["level"] as str, text=c["text"] as str, rule=c["rule"] as str, trust=c["trust"] as str)
        for c in d["checks"] as list[dict[str, str]]
    ];
    return RoomLayout(
        room_id=jid(room), name=room.name, room_type=room.room_type, area_m2=d["area_m2"] as float,
        lux=d["lux"] as int, lamp_watts=d["lamp_watts"] as int, lamp_lumens=d["lamp_lumens"] as int,
        lumens_needed=d["lumens_needed"] as float, lights=len(d["lights"] as list), sockets=len(d["sockets"] as list),
        points=points, checks=checks
    );
}

def _layout_result(level: Level, placed: bool, message: str = "") -> LayoutResult {
    bg = _background(level);
    sized = bg != None and bg.scaled;
    rooms = [_room_layout(r, sized) for r in [level ->:HasRoom:->]];
    if len(rooms) == 0 {
        return LayoutResult(ok=False, message="Add rooms first: scan the plan or draw rooms with the Room tool (R).");
    }
    watts = 0.0;
    for r in rooms {
        watts += (r.lights * r.lamp_watts) as float;
    }
    return LayoutResult(
        ok=True, message=message, sized=sized, placed=placed, rooms=rooms,
        total_lights=sum([r.lights for r in rooms]), total_sockets=sum([r.sockets for r in rooms]),
        total_switches=len(rooms), lighting_watts=watts
    );
}

"""Calculate lights (lumen method), a switch by the door and socket outlets for every room, without saving."""
def:pub preview_layout() -> LayoutResult {
    level = _get_level();
    placed = any([d.auto for r in [level ->:HasRoom:->] for d in [r -->][?:Device]]);
    return _layout_result(level, placed);
}

"""Place the calculated lights, switches and sockets on the plan (replaces an earlier automatic layout)."""
def:pub apply_layout() -> FloorPlan {
    level = _get_level();
    bg = _background(level);
    sized = bg != None and bg.scaled;
    for room in [level ->:HasRoom:->] {
        for old in [room -->][?:Device] {
            if old.auto {
                del old;
            }
        }
        for p in _room_layout(room, sized).points {
            room ++> Device(kind=p.kind, x=p.x, y=p.y, label=p.label, spec=p.spec, auto=True, load_w=p.watts);
        }
    }
    return _read_plan(level);
}

"""Remove every automatically placed device (hand-placed ones stay)."""
def:pub clear_layout() -> FloorPlan {
    level = _get_level();
    for room in [level ->:HasRoom:->] {
        for old in [room -->][?:Device] {
            if old.auto {
                del old;
            }
        }
    }
    return _read_plan(level);
}

# ---- Appliances: AC per room, water pump, hot water, washing machine, custom loads ----

glob APPLIANCE_KIND: str = "Appliance";
glob PLUG_KIND: str = "Plug base";

obj LoadInfo {
    has tag: str;
    has name: str;
    has item_id: str;
    has room_id: str;
    has room_name: str;
    has watts: float;
    has ib: float;
    has breaker: str;
    has cable: float;
    has outlet: str;
    has checks: list[LayoutCheck];
}

obj AcOption {
    has room_id: str;
    has name: str;
    has room_type: str;
    has area_m2: float;
    has need_btu: float;
    has btu_per_m2: float;
    has size_btu: int;
    has units: int;
    has watts: float;
    has trust: str;
    has tag: str = "";              # set when this room already has an AC
}

obj RoomRef {
    has room_id: str;
    has name: str;
    has room_type: str;
    has tag: str = "";              # existing water heater tag (bathrooms)
}

obj CatalogItem {
    has id: str;
    has name: str;
    has tag: str;
    has watts: float;
    has outlet: str;
    has trust: str;
}

obj CatalogGroup {
    has id: str;
    has name: str;
    has items: list[CatalogItem];
}

obj DemandRow {
    has name: str;
    has connected_w: float;
    has demand_w: float;
    has rule: str;
}

obj DemandInfo {
    has rows: list[DemandRow] = [];
    has total_w: float = 0.0;
    has ib_a: float = 0.0;
    has main_a: float = 0.0;
    has pct: float = 0.0;
    has level: str = "PASS";
    has fixes: list[str] = [];
    has trust: str = "";
    has main_trust: str = "";
}

obj LoadsResult {
    has ok: bool = True;
    has message: str = "";
    has sized: bool = False;
    has loads: list[LoadInfo] = [];
    has ac_rooms: list[AcOption] = [];
    has bathrooms: list[RoomRef] = [];
    has kitchen: RoomRef | None = None;
    has rooms: list[RoomRef] = [];
    has pump_tag: str = "";
    has wm_tag: str = "";
    has catalog: list[CatalogGroup] = [];
    has demand: DemandInfo = DemandInfo();
    has plan: FloorPlan | None = None;
}

def _room_area_m2(room: Room) -> float {
    pts: list[float] = room.poly if len(room.poly) >= 6 else [
        room.x, room.y, room.x + room.width, room.y, room.x + room.width, room.y + room.height, room.x, room.y + room.height
    ];
    acc = 0.0;
    n = len(pts) // 2;
    for i in range(n) {
        j = (i + 1) % n;
        acc += pts[2 * i] * pts[2 * j + 1] - pts[2 * j] * pts[2 * i + 1];
    }
    return abs(acc) / 2.0 / 10000.0;
}

def _room_tag(room: Room, prefix: str) -> str {
    for d in [room -->][?:Device] {
        if d.kind == APPLIANCE_KIND or d.kind == PLUG_KIND {
            if d.tag.startswith(prefix) {
                return d.tag;
            }
        }
    }
    return "";
}

def _next_tag(level: Level, prefix: str) -> str {
    used = [d.tag for r in [level ->:HasRoom:->] for d in [r -->][?:Device] if d.tag != ""];
    if prefix == "PUMP" and "PUMP" not in used {
        return "PUMP";
    }
    n = 1;
    while f"{prefix}{n}" in used {
        n += 1;
    }
    return f"{prefix}{n}";
}

def _loads_result(level: Level, ok: bool = True, message: str = "") -> LoadsResult {
    bg = _background(level);
    rooms = [level ->:HasRoom:->];
    excluded = ac_room_types_excluded() as list[str];
    loads: list[LoadInfo] = [];
    demand_loads: list[dict[str, any]] = [];
    lighting_w = 0.0;
    socket_rooms: list[list[any]] = [];
    for room in rooms {
        outlets = 0;
        for d in [room -->][?:Device] {
            if d.kind == LIGHT_KIND {
                w = d.load_w;
                if w == 0.0 and " W" in d.spec {
                    w = float(d.spec.split(" W")[0]);
                }
                lighting_w += w;
            } elif d.kind == SOCKET_KIND {
                outlets += 1;
            } elif d.kind == PLUG_KIND and d.load_w > 0.0 {
                demand_loads.append({"name": d.spec, "demand": d.demand, "watts": d.load_w});
                loads.append(LoadInfo(
                    tag=d.tag, name=d.spec, item_id=d.item_id, room_id=jid(room), room_name=room.name, watts=d.load_w,
                    ib=d.ib, breaker=d.breaker, cable=d.cable, outlet=d.outlet,
                    checks=[LayoutCheck(level=c["level"], text=c["text"], rule=c["rule"], trust=c["trust"]) for c in d.notes]
                ));
            }
        }
        socket_rooms.append([room.room_type, outlets]);
    }
    ac_rooms: list[AcOption] = [];
    baths: list[RoomRef] = [];
    kitchen: RoomRef | None = None;
    refs: list[RoomRef] = [];
    for room in rooms {
        refs.append(RoomRef(room_id=jid(room), name=room.name, room_type=room.room_type));
        if room.room_type == "bathroom" or room.room_type == "wc" {
            baths.append(RoomRef(room_id=jid(room), name=room.name, room_type=room.room_type, tag=_room_tag(room, "WH")));
        } elif room.room_type == "kitchen" and kitchen is None {
            kitchen = RoomRef(room_id=jid(room), name=room.name, room_type=room.room_type);
        }
        if room.room_type not in excluded {
            a = ac_sizing(_room_area_m2(room)) as dict[str, any];
            ac_rooms.append(AcOption(
                room_id=jid(room), name=room.name, room_type=room.room_type, area_m2=_room_area_m2(room),
                need_btu=a["need_btu"] as float, btu_per_m2=a["btu_per_m2"] as float, size_btu=a["size_btu"] as int,
                units=a["units"] as int, watts=(a["watts"] as float) * (a["units"] as float), trust=a["trust"] as str,
                tag=_room_tag(room, "AC")
            ));
        }
    }
    pump_tag = "";
    wm_tag = "";
    for l in loads {
        if l.item_id.startswith("pump") { pump_tag = l.tag; }
        if l.item_id == "washing_machine" { wm_tag = l.tag; }
    }
    catalog = [
        CatalogGroup(id=g["id"], name=g["name"], items=[
            CatalogItem(id=i["id"], name=i["name"], tag=i["tag"], watts=i["watts"], outlet=i["outlet"], trust=i["trust"])
            for i in g["items"] as list[dict[str, any]]
        ])
        for g in load_catalog() as list[dict[str, any]]
    ];
    md = max_demand(lighting_w, socket_rooms, demand_loads) as dict[str, any];
    demand = DemandInfo(
        rows=[DemandRow(name=r["name"], connected_w=r["connected_w"], demand_w=r["demand_w"], rule=r["rule"]) for r in md["rows"] as list[dict[str, any]]],
        total_w=md["total_w"] as float, ib_a=md["ib_a"] as float, main_a=md["main_a"] as float, pct=md["pct"] as float,
        level=md["level"] as str, fixes=md["fixes"] as list[str], trust=md["trust"] as str, main_trust=md["main_trust"] as str
    );
    return LoadsResult(
        ok=ok, message=message, sized=bg != None and bg.scaled, loads=loads, ac_rooms=ac_rooms, bathrooms=baths,
        kitchen=kitchen, rooms=refs, pump_tag=pump_tag, wm_tag=wm_tag, catalog=catalog, demand=demand, plan=_read_plan(level)
    );
}

def _find_room(level: Level, room_id: str) -> Room | None {
    for r in [level ->:HasRoom:->] {
        if jid(r) == room_id { return r; }
    }
    return None;
}

"""The room on the other side of one of this room's doorways, and that doorway (x, y, width)."""
def _room_through_door(level: Level, room: Room) -> tuple[Room | None, list[float]] {
    i = 0;
    while i + 2 < len(room.doors) {
        (dx, dy, dw) = (room.doors[i], room.doors[i + 1], room.doors[i + 2]);
        for other in [level ->:HasRoom:->] {
            if jid(other) == jid(room) { continue; }
            j = 0;
            while j + 2 < len(other.doors) {
                if abs(other.doors[j] - dx) < 30.0 and abs(other.doors[j + 1] - dy) < 30.0 {
                    return (other, [other.doors[j], other.doors[j + 1], other.doors[j + 2]]);
                }
                j += 3;
            }
        }
        i += 3;
    }
    return (None, []);
}

"""Appliance questions, loads added so far, the load catalog and the whole-house maximum demand."""
def:pub get_loads() -> LoadsResult {
    return _loads_result(_get_level());
}

"""Add one appliance load to a room: the appliance, its labelled plug base, breaker and cable from the rule profile."""
def:pub add_load(item_id: str, room_id: str, watts: float = 0.0, name: str = "") -> LoadsResult {
    level = _get_level();
    room = _find_room(level, room_id);
    item = find_item(item_id) as dict[str, any] | None;
    if room is None or item is None {
        return _loads_result(level, False, "Unknown room or load.");
    }
    # Optional args can arrive as "" from the HTTP bridge when omitted
    given_w = float(watts) if watts else 0.0;
    given_name = str(name).strip() if name else "";
    load_w = given_w if given_w > 0.0 else item["watts"] as float;
    label = given_name if given_name != "" else item["name"] as str;
    tag = _next_tag(level, item["tag"] as str);
    prot = protection(item, load_w) as dict[str, any];
    notes = prot["checks"] as list[dict[str, str]];
    # Every device on the level counts: a heater switch outside the bathroom lands in the next room
    taken = [[d.x, d.y] for r in [level ->:HasRoom:->] for d in [r -->][?:Device]];
    plug_xy: list[float] = [];
    app_xy: list[float] = [];
    where = "";
    if item_id.startswith("pump") {
        # The pump sits outside; only its switch and outlet go in the kitchen, by the door
        (plug_xy, found) = place_by_door(room.poly, (room.x, room.y, room.width, room.height), room.doors, taken, False);
        where = f"{room.name}, by the door" if found else f"{room.name} (door not found: move it next to the door)";
    } elif (item["demand"] as str).startswith("WATER_HEATER") {
        placed = place_appliance(room.poly, (room.x, room.y, room.width, room.height), room.doors, taken, item) as dict[str, list[float]];
        app_xy = placed["appliance"];
        # Switch goes in the room on the other side of the bathroom door (the room sharing that doorway)
        (neighbour, shared) = _room_through_door(level, room);
        found = False;
        if neighbour is not None {
            (plug_xy, found) = place_by_door(neighbour.poly, (neighbour.x, neighbour.y, neighbour.width, neighbour.height), shared, taken, False);
        }
        if found and neighbour is not None {
            where = f"{neighbour.name}, outside the {room.name} door";
        } else {
            plug_xy = placed["plug"];
            where = f"{room.name} (door not found)";
            notes = notes + [{"level": "WARNING", "text": "Door not found: move this switch outside the bathroom (Section 701 zones).", "rule": "Section 701", "trust": "design choice"}];
        }
    } else {
        placed = place_appliance(room.poly, (room.x, room.y, room.width, room.height), room.doors, taken, item) as dict[str, list[float]];
        app_xy = placed["appliance"];
        plug_xy = placed["plug"];
        where = f"{room.name}, beside the {label.lower()}";
    }
    common = {"tag": tag, "item_id": item_id, "load_w": load_w};
    if len(app_xy) == 2 {
        room ++> Device(kind=APPLIANCE_KIND, x=app_xy[0], y=app_xy[1], label=tag, spec=label, tag=tag, item_id=item_id);
    }
    room ++> Device(
        kind=PLUG_KIND, x=plug_xy[0], y=plug_xy[1], label=tag, spec=label, tag=tag, item_id=item_id, load_w=load_w,
        demand=item["demand"] as str, ib=prot["ib"] as float, breaker=prot["breaker"] as str, cable=prot["cable"] as float,
        outlet=f"{item['outlet']} · {where}", notes=notes
    );
    return _loads_result(level, True, f"{tag} added: {label} in {room.name}.");
}

"""Size an AC from the room's area (BTU) and add it with its high-level plug base."""
def:pub add_ac(room_id: str) -> LoadsResult {
    level = _get_level();
    room = _find_room(level, room_id);
    if room is None {
        return _loads_result(level, False, "Unknown room.");
    }
    a = ac_sizing(_room_area_m2(room)) as dict[str, any];
    units = a["units"] as int;
    result = _loads_result(level);
    for _ in range(units) {
        result = add_load(a["item_id"] as str, room_id);
    }
    return result;
}

"""Remove an appliance and its plug base."""
def:pub remove_load(tag: str) -> LoadsResult {
    level = _get_level();
    for room in [level ->:HasRoom:->] {
        for d in [room -->][?:Device] {
            if d.tag == tag {
                del d;
            }
        }
    }
    return _loads_result(level, True, f"{tag} removed.");
}
