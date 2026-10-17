import from services.planConvert { convert_plan }

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
}

node Device {
    has kind: str = "Socket 16A";
    has x: float = 0.0;
    has y: float = 0.0;
    has rotation: int = 0;
    has label: str = "";
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

obj FloorPlan {
    has name: str;
    has level: str;
    has rooms: list[PlanElement];
    has devices: list[PlanElement];
}

def _get_level() -> Level {
    projects = [root -->][?:Project];
    if len(projects) == 0 {
        project = Project(name="WireWise Residence");
        root ++> project;
    } else {
        project = projects[0];
    }
    levels = [project ->:HasLevel:->];
    if len(levels) == 0 {
        level = Level(name="Ground", order=0);
        project +>:HasLevel:+> level;
        return level;
    }
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
