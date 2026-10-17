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

obj FloorPlan {
    has name: str;
    has level: str;
    has rooms: list[PlanElement];
    has devices: list[PlanElement];
}

def:pub get_floor_plan() -> FloorPlan {
    projects = [root -->][?:Project];
    if len(projects) == 0 {
        project = Project(name="WireWise Residence");
        root ++> project;
        level = Level(name="Ground", order=0);
        project +>:HasLevel:+> level;
        room_a = Room(name="Kitchen", x=120.0, y=90.0, width=270.0, height=190.0, room_type="kitchen");
        room_b = Room(name="Living", x=390.0, y=90.0, width=300.0, height=260.0, room_type="living");
        room_c = Room(name="Hall", x=120.0, y=280.0, width=160.0, height=130.0, room_type="hall");
        level +>:HasRoom:+> room_a;
        level +>:HasRoom:+> room_b;
        level +>:HasRoom:+> room_c;
        room_a ++> Device(kind="Socket 16A", x=160.0, y=270.0, label="S1");
        room_a ++> Device(kind="Lighting point", x=255.0, y=170.0, label="L1");
        room_b ++> Device(kind="Lighting point", x=535.0, y=210.0, label="L2");
    } else {
        project = projects[0];
    }
    levels = [project ->:HasLevel:->];
    if len(levels) == 0 {
        return FloorPlan(name=project.name, level="Ground", rooms=[], devices=[]);
    }
    level = levels[0];
    rooms: list[PlanElement] = [];
    devices: list[PlanElement] = [];
    for room in [level ->:HasRoom:->] {
        rooms.append(PlanElement(id=jid(room), kind=room.room_type, x=room.x, y=room.y, width=room.width, height=room.height, label=room.name));
        for device in [room -->][?:Device] {
            devices.append(PlanElement(id=jid(device), kind=device.kind, x=device.x, y=device.y, label=device.label));
        }
    }
    return FloorPlan(name=project.name, level=level.name, rooms=rooms, devices=devices);
}

def:pub add_plan_element(kind: str, x: float, y: float) -> FloorPlan {
    _ = get_floor_plan();
    projects = [root -->][?:Project];
    project = projects[0];
    levels = [project ->:HasLevel:->];
    level = levels[0];
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
    return get_floor_plan();
}
