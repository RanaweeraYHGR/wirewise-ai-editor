import hashlib;
import from datetime { datetime }
import from services.planConvert { convert_plan }
import from services.planVision { scan_start }
import from services.layoutDesigner {
    design_room, load_catalog, find_item, ac_sizing, ac_room_types_excluded,
    protection, place_appliance, place_by_door, max_demand,
    wiring_options, suggest_cu, design_wiring, booklet_meta, bill_of_materials
}
import from services.roomAgent { identify_rooms, RoomGuess }
import from jaclang.byllm.lib { Image }

node Project {
    has name: str = "LUMIRA Residence";
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

"""Consumer unit for a level: its position and, once wired, the circuit design."""
node ConsumerUnit {
    has x: float = 0.0;
    has y: float = 0.0;
    has room_name: str = "";
    has confirmed: bool = False;
    has design: dict[str, any] = {};
    has opts: dict[str, any] = {};
    has signature: str = "";        # devices the design was made for; differs => plan changed since wiring
    has finalized: bool = False;
    has finalized_at: str = "";
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
        project = Project(name="LUMIRA Residence");
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
    if project.name == "WireWise Residence" {
        project.name = "LUMIRA Residence";   # default from before the LUMIRA rename
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
    for cu in [level -->][?:ConsumerUnit] {
        del cu;
    }
    for sug in [level -->][?:RoomSuggestion] {
        del sug;
    }
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

"""Rename the project (shown in the header and on the wiring booklet)."""
def:pub rename_project(name: str) -> FloorPlan {
    level = _get_level();
    clean = str(name).strip() if name else "";
    if clean != "" {
        for p in [root -->][?:Project] {
            p.name = clean[:80];
        }
    }
    return _read_plan(level);
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

obj LoadPreview {
    has ok: bool = True;
    has message: str = "";
    has item_id: str = "";
    has room_id: str = "";
    has room_name: str = "";
    has tag: str = "";
    has name: str = "";
    has has_appliance: bool = False;
    has app_x: float = 0.0;
    has app_y: float = 0.0;
    has plug_x: float = 0.0;
    has plug_y: float = 0.0;
    has where: str = "";
    has poly: list[float] = [];     # target room outline, flattened x,y in canvas cm
}

obj _Spot {
    has app: list[float];
    has plug: list[float];
    has where: str;
    has notes: list[dict[str, str]];
}

"""Where an appliance and its plug base go in a room (nothing is saved)."""
def _plan_spot(level: Level, room: Room, item: dict[str, any], item_id: str, label: str) -> _Spot {
    # Every device on the level counts: a heater switch outside the bathroom lands in the next room
    taken = [[d.x, d.y] for r in [level ->:HasRoom:->] for d in [r -->][?:Device]];
    rect = (room.x, room.y, room.width, room.height);
    if item_id.startswith("pump") {
        # The pump sits outside; only its switch and outlet go in the kitchen, by the door
        (plug_xy, found) = place_by_door(room.poly, rect, room.doors, taken, False);
        where = f"{room.name}, by the door" if found else f"{room.name} (door not found: move it next to the door)";
        return _Spot(app=[], plug=plug_xy, where=where, notes=[]);
    }
    placed = place_appliance(room.poly, rect, room.doors, taken, item) as dict[str, list[float]];
    if (item["demand"] as str).startswith("WATER_HEATER") {
        # Switch goes in the room on the other side of the bathroom door (the room sharing that doorway)
        (neighbour, shared) = _room_through_door(level, room);
        found = False;
        plug_xy: list[float] = [];
        if neighbour is not None {
            (plug_xy, found) = place_by_door(neighbour.poly, (neighbour.x, neighbour.y, neighbour.width, neighbour.height), shared, taken, False);
        }
        if found and neighbour is not None {
            return _Spot(app=placed["appliance"], plug=plug_xy, where=f"{neighbour.name}, outside the {room.name} door", notes=[]);
        }
        return _Spot(app=placed["appliance"], plug=placed["plug"], where=f"{room.name} (door not found)", notes=[
            {"level": "WARNING", "text": "Door not found: move this switch outside the bathroom (Section 701 zones).", "rule": "Section 701", "trust": "design choice"}
        ]);
    }
    return _Spot(app=placed["appliance"], plug=placed["plug"], where=f"{room.name}, beside the {label.lower()}", notes=[]);
}

def _outline(room: Room) -> list[float] {
    if len(room.poly) >= 6 { return room.poly; }
    return [room.x, room.y, room.x + room.width, room.y, room.x + room.width, room.y + room.height, room.x, room.y + room.height];
}

"""Suggested position for an appliance and its plug base, shown on the plan before the user adds it."""
def:pub preview_load(item_id: str, room_id: str) -> LoadPreview {
    level = _get_level();
    room = _find_room(level, room_id);
    item = find_item(item_id) as dict[str, any] | None;
    if room is None or item is None {
        return LoadPreview(ok=False, message="Unknown room or load.");
    }
    label = item["name"] as str;
    spot = _plan_spot(level, room, item, item_id, label);
    return LoadPreview(
        ok=True, item_id=item_id, room_id=room_id, room_name=room.name, tag=_next_tag(level, item["tag"] as str), name=label,
        has_appliance=len(spot.app) == 2, app_x=spot.app[0] if len(spot.app) == 2 else 0.0, app_y=spot.app[1] if len(spot.app) == 2 else 0.0,
        plug_x=spot.plug[0], plug_y=spot.plug[1], where=spot.where, poly=_outline(room)
    );
}

def _num(v: any) -> float {
    # Optional args can arrive as "" from the HTTP bridge when omitted
    return float(v) if v else 0.0;
}

"""Add one appliance load to a room: the appliance, its labelled plug base, breaker and cable from the rule profile.
app_x/app_y and plug_x/plug_y (canvas cm) override the suggested positions when the user moved them."""
def:pub add_load(
    item_id: str, room_id: str, watts: float = 0.0, name: str = "",
    app_x: float = 0.0, app_y: float = 0.0, plug_x: float = 0.0, plug_y: float = 0.0
) -> LoadsResult {
    level = _get_level();
    room = _find_room(level, room_id);
    item = find_item(item_id) as dict[str, any] | None;
    if room is None or item is None {
        return _loads_result(level, False, "Unknown room or load.");
    }
    given_w = _num(watts);
    given_name = str(name).strip() if name else "";
    load_w = given_w if given_w > 0.0 else item["watts"] as float;
    label = given_name if given_name != "" else item["name"] as str;
    tag = _next_tag(level, item["tag"] as str);
    prot = protection(item, load_w) as dict[str, any];
    spot = _plan_spot(level, room, item, item_id, label);
    app_xy = spot.app;
    plug_xy = spot.plug;
    where = spot.where;
    if _num(app_x) > 0.0 and _num(app_y) > 0.0 and len(app_xy) == 2 {
        app_xy = [_num(app_x), _num(app_y)];
    }
    if _num(plug_x) > 0.0 and _num(plug_y) > 0.0 {
        plug_xy = [_num(plug_x), _num(plug_y)];
        where = "your position on the plan";
    }
    if len(app_xy) == 2 {
        room ++> Device(kind=APPLIANCE_KIND, x=app_xy[0], y=app_xy[1], label=tag, spec=label, tag=tag, item_id=item_id);
    }
    room ++> Device(
        kind=PLUG_KIND, x=plug_xy[0], y=plug_xy[1], label=tag, spec=label, tag=tag, item_id=item_id, load_w=load_w,
        demand=item["demand"] as str, ib=prot["ib"] as float, breaker=prot["breaker"] as str, cable=prot["cable"] as float,
        outlet=f"{item['outlet']} · {where}", notes=(prot["checks"] as list[dict[str, str]]) + spot.notes
    );
    return _loads_result(level, True, f"{tag} added: {label} in {room.name}.");
}

"""Size an AC from the room's area (BTU) and add it with its high-level plug base (first unit at the given positions)."""
def:pub add_ac(room_id: str, app_x: float = 0.0, app_y: float = 0.0, plug_x: float = 0.0, plug_y: float = 0.0) -> LoadsResult {
    level = _get_level();
    room = _find_room(level, room_id);
    if room is None {
        return _loads_result(level, False, "Unknown room.");
    }
    a = ac_sizing(_room_area_m2(room)) as dict[str, any];
    result = add_load(a["item_id"] as str, room_id, 0.0, "", app_x, app_y, plug_x, plug_y);
    for _ in range((a["units"] as int) - 1) {
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

# ---- Consumer unit and wiring ("Start wire", step 4) ----

obj MethodOption {
    has id: str;
    has label: str;
}

obj CircuitInfo {
    has id: str;
    has name: str;
    has kind: str;              # lighting | sockets | dedicated
    has rooms: list[str];
    has rcd: str;
    has breaker: str;
    has cable: float;
    has cpc: float;
    has length_m: float;
    has ib: float;
    has iz: float;
    has vd_pct: float;
    has vd_limit: float;
    has status: str;
    has spd: bool;
    has tag: str;
    has path: list[float];      # flattened x,y in canvas cm, from the consumer unit
    has checks: list[LayoutCheck];
}

obj BoardInfo {
    has main_a: int = 0;
    has spd: bool = False;
    has rccb_a: int = 0;
    has rccb_ma: int = 30;
    has rccb_type: str = "A";
    has rows: int = 1;
    has row_modules: int = 13;
    has used_modules: int = 0;
    has spare_pct: float = 0.0;
    has rcd1_a: float = 0.0;
    has rcd2_a: float = 0.0;
    has trust: str = "";
}

obj CuInfo {
    has ok: bool = True;
    has message: str = "";
    has has_rooms: bool = False;
    has saved: bool = False;            # a position is stored (else x,y is only a suggestion)
    has confirmed: bool = False;
    has x: float = 0.0;
    has y: float = 0.0;
    has room_name: str = "";
    has reason: str = "";
    has trust: str = "";
    has methods: list[MethodOption] = [];
    has methods_trust: str = "";
    has ambients: list[int] = [];
    has groupings: list[int] = [];
    has main_switch_a: int = 30;
    has wired: bool = False;
    has stale: bool = False;
    has finalized: bool = False;
    has finalized_at: str = "";
    has method: str = "";
    has ambient_c: int = 30;
    has grouped: int = 1;
    has ra_ohm: float = 0.0;
    has spd: bool = False;
    has circuits: list[CircuitInfo] = [];
    has board: BoardInfo = BoardInfo();
    has checks: list[LayoutCheck] = [];
    has summary: str = "";
}

def _cu(level: Level) -> ConsumerUnit | None {
    found = [level -->][?:ConsumerUnit];
    return found[0] if len(found) > 0 else None;
}

"""Rooms and their devices in the shape the wiring engine reads."""
def _wiring_rooms(level: Level) -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    for room in [level ->:HasRoom:->] {
        pts = _outline(room);
        n = len(pts) // 2;
        cx = sum([pts[2 * i] for i in range(n)]) / n;
        cy = sum([pts[2 * i + 1] for i in range(n)]) / n;
        lights: list[list[float]] = [];
        switches: list[list[float]] = [];
        sockets: list[list[float]] = [];
        loads: list[dict[str, any]] = [];
        for d in [room -->][?:Device] {
            if d.kind == LIGHT_KIND {
                w = d.load_w;
                if w == 0.0 and " W" in d.spec { w = float(d.spec.split(" W")[0]); }
                lights.append([d.x, d.y, w]);
            } elif d.kind == SWITCH_KIND {
                switches.append([d.x, d.y]);
            } elif d.kind == SOCKET_KIND {
                sockets.append([d.x, d.y]);
            } elif d.kind == PLUG_KIND and d.load_w > 0.0 {
                loads.append({"tag": d.tag, "name": d.spec, "item_id": d.item_id, "watts": d.load_w, "x": d.x, "y": d.y});
            }
        }
        weights = [[l[0], l[1], l[2]] for l in lights] + [[p[0], p[1], 200.0] for p in sockets] + [[l["x"], l["y"], l["watts"]] for l in loads];
        out.append({
            "id": jid(room), "name": room.name, "type": room.room_type, "poly": room.poly,
            "rect": (room.x, room.y, room.width, room.height), "doors": room.doors, "area_m2": _room_area_m2(room),
            "centroid": [cx, cy], "lights": lights, "switches": switches, "sockets": sockets, "loads": loads, "weights": weights
        });
    }
    return out;
}

def _device_signature(level: Level) -> str {
    parts = sorted([f"{d.kind}:{round(d.x)}:{round(d.y)}:{d.load_w}" for r in [level ->:HasRoom:->] for d in [r -->][?:Device]]);
    # md5 rather than hash(): Python's string hash changes on every server restart
    return str(len(parts)) + ":" + hashlib.md5("|".join(parts).encode("utf-8")).hexdigest();
}

def _cu_info(level: Level, ok: bool = True, message: str = "") -> CuInfo {
    o = wiring_options() as dict[str, any];
    info = CuInfo(
        ok=ok, message=message, has_rooms=len([level ->:HasRoom:->]) > 0,
        methods=[MethodOption(id=m["id"], label=m["label"]) for m in o["methods"] as list[dict[str, str]]],
        methods_trust=o["methods_trust"] as str, ambients=o["ambients"] as list[int], groupings=o["groupings"] as list[int],
        main_switch_a=o["main_switch_a"] as int
    );
    cu = _cu(level);
    if cu is None {
        rooms = _wiring_rooms(level);
        spot = suggest_cu([{**r, "loads": r["weights"]} for r in rooms], []) as dict[str, any] | None;
        if spot is not None {
            info.x = spot["x"] as float;
            info.y = spot["y"] as float;
            info.room_name = spot["room_name"] as str;
            info.reason = spot["reason"] as str;
            info.trust = spot["trust"] as str;
        }
        return info;
    }
    info.saved = True;
    info.confirmed = cu.confirmed;
    info.finalized = cu.finalized and len(cu.design) > 0;
    info.finalized_at = cu.finalized_at;
    info.x = cu.x;
    info.y = cu.y;
    info.room_name = cu.room_name;
    info.reason = "Your consumer unit position" if cu.confirmed else "";
    if len(cu.opts) > 0 {
        info.method = cu.opts["method"] as str;
        info.ambient_c = cu.opts["ambient_c"] as int;
        info.grouped = cu.opts["grouped"] as int;
        info.ra_ohm = cu.opts["ra_ohm"] as float;
        info.main_switch_a = cu.opts["main_a"] as int;
        info.spd = cu.opts["spd"] as bool;
    }
    if len(cu.design) > 0 {
        d = cu.design;
        info.wired = True;
        info.stale = cu.signature != _device_signature(level);
        info.circuits = [
            CircuitInfo(
                id=c["id"], name=c["name"], kind=c["kind"], rooms=c["rooms"], rcd=c["rcd"], breaker=c["breaker"],
                cable=c["cable"], cpc=c["cpc"], length_m=c["length_m"], ib=c["ib"], iz=c["iz"], vd_pct=c["vd_pct"],
                vd_limit=c["vd_limit"], status=c["status"], spd=c["spd"], tag=c.get("tag", ""),
                path=[v for pt in c["path"] for v in pt],
                checks=[LayoutCheck(level=k["level"], text=k["text"], rule=k["rule"], trust=k["trust"]) for k in c["checks"]]
            )
            for c in d["circuits"] as list[dict[str, any]]
        ];
        b = d["board"] as dict[str, any];
        loads = b["rcd_load_a"] as dict[str, float];
        info.board = BoardInfo(
            main_a=b["main_a"], spd=b["spd"], rccb_a=b["rccb_a"], rccb_ma=b["rccb_ma"], rccb_type=b["rccb_type"], rows=b["rows"],
            row_modules=b["row_modules"], used_modules=b["used_modules"], spare_pct=b["spare_pct"],
            rcd1_a=loads.get("RCD1", 0.0), rcd2_a=loads.get("RCD2", 0.0), trust=b["trust"]
        );
        info.checks = [LayoutCheck(level=k["level"], text=k["text"], rule=k["rule"], trust=k["trust"]) for k in d["checks"] as list[dict[str, str]]];
        # Recomputed so designs saved before this rule also count whole-installation errors
        levels = [c.status for c in info.circuits] + [k.level for k in info.checks];
        info.summary = "Errors found under selected rule profile — fix the open issues, review required" if "ERROR" in levels else "Passed under selected rule profile — review required";
    }
    return info;
}

"""Consumer unit position (a suggestion until confirmed), the Start wire options and the wiring design."""
def:pub get_cu() -> CuInfo {
    return _cu_info(_get_level());
}

"""Fix the consumer unit at this position (canvas cm). Moving it clears an existing wiring design."""
def:pub confirm_cu(x: float, y: float) -> CuInfo {
    level = _get_level();
    cu = _cu(level);
    if cu is None {
        cu = ConsumerUnit();
        level ++> cu;
    }
    if abs(cu.x - float(x)) > 1.0 or abs(cu.y - float(y)) > 1.0 {
        cu.design = {};
        cu.finalized = False;
    }
    cu.x = float(x);
    cu.y = float(y);
    cu.room_name = "";
    for room in [level ->:HasRoom:->] {
        pts = _outline(room);
        xs = [pts[i] for i in range(0, len(pts), 2)];
        ys = [pts[i] for i in range(1, len(pts), 2)];
        if cu.x >= min(xs) and cu.x <= max(xs) and cu.y >= min(ys) and cu.y <= max(ys) {
            cu.room_name = room.name;
        }
    }
    cu.confirmed = True;
    return _cu_info(level, True, "Consumer unit position confirmed.");
}

"""Unlock the consumer unit so it can be moved (keeps the design until it is moved)."""
def:pub move_cu() -> CuInfo {
    level = _get_level();
    cu = _cu(level);
    if cu is not None {
        cu.confirmed = False;
    }
    return _cu_info(level);
}

"""Design every circuit from the consumer unit: grouping, breakers, cables (Iz, voltage drop, cpc), RCCB split and board."""
def:pub start_wiring(method: str, ambient_c: int, grouped: int, ra_ohm: float, main_a: int, spd: bool) -> CuInfo {
    level = _get_level();
    cu = _cu(level);
    if cu is None or not cu.confirmed {
        return _cu_info(level, False, "Confirm the consumer unit position first.");
    }
    if not method {
        return _cu_info(level, False, "Choose the installation method first: cable sizes depend on it.");
    }
    rooms = _wiring_rooms(level);
    if len(rooms) == 0 {
        return _cu_info(level, False, "Add rooms first.");
    }
    opts = {
        "method": str(method), "ambient_c": int(ambient_c) if ambient_c else 30, "grouped": int(grouped) if grouped else 1,
        "ra_ohm": float(ra_ohm) if ra_ohm else 0.0, "main_a": int(main_a) if main_a else 30, "spd": bool(spd) and str(spd) != "false"
    };
    cu.opts = opts;
    cu.design = design_wiring([cu.x, cu.y], rooms, opts) as dict[str, any];
    cu.finalized = False;
    cu.signature = _device_signature(level);
    return _cu_info(level, True, "Wiring designed.");
}

"""Remove the wiring design (the consumer unit stays)."""
def:pub clear_wiring() -> CuInfo {
    level = _get_level();
    cu = _cu(level);
    if cu is not None {
        cu.design = {};
        cu.finalized = False;
    }
    return _cu_info(level);
}

# ---- Wiring booklet ("Finalize wiring") ----

obj KeyValue {
    has key: str;
    has value: str;
}

obj BookletRoom {
    has name: str;
    has room_type: str;
    has area_m2: float;
    has lux: int;
    has lamp: str;
    has lights: int;
    has lumens: float;
    has lumens_needed: float;
    has achieved_lux: float;
    has w_per_m2: float;
    has switches: int;
    has sockets: int;
    has appliances: list[str];
}

obj BomLine {
    has group: str;
    has item: str;
    has spec: str;
    has qty: float;
    has unit: str;
    has note: str;
    has trust: str;
}

obj Booklet {
    has ok: bool = True;
    has message: str = "";
    has project: str = "";
    has level: str = "";
    has date: str = "";
    has standard: str = "";
    has profile_id: str = "";
    has profile_status: str = "";
    has summary: str = "";
    has inputs: list[KeyValue] = [];
    has totals: list[KeyValue] = [];
    has rooms: list[BookletRoom] = [];
    has circuits: list[CircuitInfo] = [];
    has board: BoardInfo = BoardInfo();
    has bom: list[BomLine] = [];
    has checks: list[LayoutCheck] = [];
    has issues: list[LayoutCheck] = [];
    has plan: FloorPlan | None = None;
    has bg_image: str = "";
    has bg_x: float = 0.0;
    has bg_y: float = 0.0;
    has bg_w: float = 0.0;
    has bg_h: float = 0.0;
    has cu_x: float = 0.0;
    has cu_y: float = 0.0;
    has earthing: str = "";
    has supply: str = "";
    has ra_ohm: float = 0.0;
}

def _spec_num(spec: str, unit: str) -> float {
    # "18 W LED · 1600 lm" -> 18 (unit "W") or 1600 (unit "lm")
    parts = spec.replace("·", " ").split();
    for i in range(1, len(parts)) {
        if parts[i] == unit {
            try { return float(parts[i - 1]); } except Exception { return 0.0; }
        }
    }
    return 0.0;
}

def _booklet(level: Level) -> Booklet {
    cu = _cu(level);
    if cu is None or len(cu.design) == 0 {
        return Booklet(ok=False, message="Start wire first: the booklet is made from the wiring design.");
    }
    info = _cu_info(level);
    meta = booklet_meta() as dict[str, any];
    bg = _background(level);
    sized = bg != None and bg.scaled;
    projects = [root -->][?:Project];
    rooms_out: list[BookletRoom] = [];
    device_rows: list[dict[str, str]] = [];
    for room in [level ->:HasRoom:->] {
        d = design_room(room.room_type, room.poly, (room.x, room.y, room.width, room.height), room.doors, sized) as dict[str, any];
        lights = 0;
        switches = 0;
        sockets = 0;
        lumens = 0.0;
        watts = 0.0;
        lamp = "";
        apps: list[str] = [];
        for dev in [room -->][?:Device] {
            device_rows.append({"kind": dev.kind, "spec": dev.spec, "outlet": dev.outlet});
            if dev.kind == LIGHT_KIND {
                lights += 1;
                lm = _spec_num(dev.spec, "lm");
                lumens += lm if lm > 0.0 else d["lamp_lumens"] as float;
                watts += dev.load_w if dev.load_w > 0.0 else _spec_num(dev.spec, "W");
                lamp = dev.spec if dev.spec != "" else lamp;
            } elif dev.kind == SWITCH_KIND {
                switches += 1;
            } elif dev.kind == SOCKET_KIND {
                sockets += 1;
            } elif dev.kind == PLUG_KIND {
                apps.append(f"{dev.tag} {dev.spec}");
            }
        }
        area = d["area_m2"] as float;
        rooms_out.append(BookletRoom(
            name=room.name, room_type=room.room_type, area_m2=area, lux=d["lux"] as int, lamp=lamp, lights=lights,
            lumens=lumens, lumens_needed=d["lumens_needed"] as float,
            achieved_lux=(lumens * (d["uf"] as float) * (d["mf"] as float) / area) if area > 0.0 else 0.0,
            w_per_m2=(watts / area) if area > 0.0 else 0.0, switches=switches, sockets=sockets, appliances=apps
        ));
    }
    circ_rows = [{"id": c.id, "cable": c.cable, "cpc": c.cpc, "length_m": c.length_m, "breaker": c.breaker} for c in info.circuits];
    b = info.board;
    board_row = {"main_a": b.main_a, "spd": b.spd, "rccb_a": b.rccb_a, "rccb_ma": b.rccb_ma, "rccb_type": b.rccb_type,
                 "rows": b.rows, "row_modules": b.row_modules, "used_modules": b.used_modules};
    bom = [
        BomLine(group=l["group"], item=l["item"], spec=l["spec"], qty=l["qty"], unit=l["unit"], note=l["note"], trust=l["trust"])
        for l in bill_of_materials(circ_rows, board_row, device_rows) as list[dict[str, any]]
    ];
    methods = meta["methods"] as dict[str, str];
    opts = cu.opts;
    inputs = [
        KeyValue(key="Supply", value=f"{meta['voltage_v']} V, {meta['phases']}-phase, {meta['frequency_hz']} Hz"),
        KeyValue(key="Earthing", value=f"{meta['earthing']} (earth electrode)"),
        KeyValue(key="Earth electrode RA", value=(f"{opts['ra_ohm']} Ω" if (opts["ra_ohm"] as float) > 0.0 else "not entered")),
        KeyValue(key="Main switch", value=f"{opts['main_a']} A"),
        KeyValue(key="Installation method", value=methods.get(opts["method"] as str, opts["method"] as str)),
        KeyValue(key="Ambient temperature", value=f"{opts['ambient_c']} °C"),
        KeyValue(key="Cables grouped", value=str(opts["grouped"])),
        KeyValue(key="Surge protection", value="Type 2 SPD" if opts["spd"] else "none"),
        KeyValue(key="Plan scale", value="set by the user" if sized else "NOT SET: areas and lengths are assumed")
    ];
    total_len = sum([c.length_m for c in info.circuits]);
    n_light = sum([r.lights for r in rooms_out]);
    totals = [
        KeyValue(key="Rooms", value=str(len(rooms_out))),
        KeyValue(key="Circuits", value=str(len(info.circuits))),
        KeyValue(key="Light points", value=str(n_light)),
        KeyValue(key="Switches", value=str(sum([r.switches for r in rooms_out]))),
        KeyValue(key="Socket outlets", value=str(sum([r.sockets for r in rooms_out]))),
        KeyValue(key="Appliance outlets", value=str(sum([len(r.appliances) for r in rooms_out]))),
        KeyValue(key="Cable (estimated)", value=f"{total_len:.0f} m")
    ];
    issues: list[LayoutCheck] = [k for k in info.checks if k.level == "ERROR" or k.level == "WARNING"];
    for c in info.circuits {
        for k in c.checks {
            if k.level == "ERROR" or k.level == "WARNING" {
                issues.append(LayoutCheck(level=k.level, text=f"{c.id}: {k.text}", rule=k.rule, trust=k.trust));
            }
        }
    }
    return Booklet(
        ok=True, project=projects[0].name if len(projects) > 0 else "Project", level=level.name,
        date=cu.finalized_at if cu.finalized_at != "" else datetime.now().strftime("%Y-%m-%d %H:%M"),
        standard=meta["standard"] as str, profile_id=meta["profile_id"] as str, profile_status=meta["status"] as str,
        summary=info.summary, inputs=inputs, totals=totals, rooms=rooms_out, circuits=info.circuits, board=info.board,
        bom=bom, checks=info.checks, issues=issues, plan=_read_plan(level),
        bg_image=bg.image if bg != None else "", bg_x=bg.x if bg != None else 0.0, bg_y=bg.y if bg != None else 0.0,
        bg_w=bg.width if bg != None else 0.0, bg_h=bg.height if bg != None else 0.0,
        cu_x=cu.x, cu_y=cu.y, earthing=meta["earthing"] as str,
        supply=f"{meta['voltage_v']} V {meta['phases']}-ph {meta['frequency_hz']} Hz", ra_ohm=opts["ra_ohm"] as float
    );
}

"""Lock the wiring design and produce the wiring booklet (refused while the plan has changed since wiring)."""
def:pub finalize_wiring() -> Booklet {
    level = _get_level();
    cu = _cu(level);
    if cu is None or len(cu.design) == 0 {
        return Booklet(ok=False, message="Start wire first.");
    }
    if cu.signature != _device_signature(level) {
        return Booklet(ok=False, message="The plan changed after wiring: Start wire again before finalizing.");
    }
    cu.finalized = True;
    cu.finalized_at = datetime.now().strftime("%Y-%m-%d %H:%M");
    return _booklet(level);
}

"""The wiring booklet for the current design."""
def:pub get_booklet() -> Booklet {
    return _booklet(_get_level());
}
