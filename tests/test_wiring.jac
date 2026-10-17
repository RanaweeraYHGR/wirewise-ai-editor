"""Wiring: circuit split, breakers and cable sizing from the rule profile, consumer unit board."""

import from services.layoutDesigner { design_wiring, suggest_cu }

def _room(name: str, kind: str, x: float, sockets: int, lights: int) -> dict[str, any] {
    return {
        "id": name, "name": name, "type": kind, "area_m2": 12.0, "centroid": [x + 150.0, 150.0],
        "poly": [x, 0.0, x + 300.0, 0.0, x + 300.0, 400.0, x, 400.0], "rect": (x, 0.0, 300.0, 400.0), "doors": [],
        "lights": [[x + 100.0, 200.0, 18.0] for _ in range(lights)], "switches": [[x + 20.0, 380.0]],
        "sockets": [[x + 15.0, 50.0 + 60.0 * i] for i in range(sockets)], "loads": []
    };
}

def _house() -> list[dict[str, any]] {
    rooms = [_room("Bedroom", "bedroom", 0.0, 3, 2), _room("Kitchen", "kitchen", 300.0, 6, 2), _room("Bath", "bathroom", 600.0, 0, 1)];
    rooms[2]["loads"] = [{"tag": "WH1", "name": "Instant water heater", "item_id": "water_heater_instant", "watts": 4500.0, "x": 700.0, "y": 50.0}];
    return rooms;
}

test "circuits follow 314.1 and sizes come from the rule profile" {
    d = design_wiring([450.0, 20.0], _house(), {"method": "C", "ambient_c": 30, "grouped": 1, "ra_ohm": 100.0, "main_a": 30, "spd": True}) as dict[str, any];
    cs = d["circuits"] as list[dict[str, any]];
    kinds = [c["kind"] for c in cs];
    assert kinds.count("lighting") >= 2, "at least two lighting circuits";
    kitchen = [c for c in cs if c["kind"] == "sockets" and c["rooms"] == ["Kitchen"]];
    assert len(kitchen) == 1, "kitchen sockets on their own circuit";
    wh = [c for c in cs if c.get("tag", "") == "WH1"][0];
    assert wh["breaker"] == "B32" and wh["cable"] == 6.0;
    for c in cs {
        if c["kind"] == "lighting" { assert c["breaker"] == "B6" and c["cable"] == 1.5; }
        assert c["rcd"] in ["RCD1", "RCD2"];
    }
    assert (d["board"] as dict[str, any])["spd"];
}

test "the bathroom never gets a lighting circuit of its own" {
    d = design_wiring([450.0, 20.0], _house(), {"method": "C", "ambient_c": 30, "grouped": 1, "ra_ohm": 0.0, "main_a": 30, "spd": False}) as dict[str, any];
    for c in d["circuits"] as list[dict[str, any]] {
        if c["kind"] == "lighting" { assert c["rooms"] != ["Bath"]; }
    }
    texts = " ".join([k["text"] for k in d["checks"] as list[dict[str, str]]]);
    assert "RA not entered" in texts, "missing RA must be a warning, not an assumption";
}

test "hot, grouped, insulated runs upsize the cable instead of failing silently" {
    rooms = [_room("Hall", "hall", 0.0, 6, 1)];
    rooms[0]["sockets"] = [[4000.0 + 10.0 * i, 2500.0] for i in range(6)];   # far from the consumer unit
    d = design_wiring([0.0, 0.0], rooms, {"method": "A", "ambient_c": 45, "grouped": 4, "ra_ohm": 50.0, "main_a": 30, "spd": False}) as dict[str, any];
    skt = [c for c in d["circuits"] as list[dict[str, any]] if c["kind"] == "sockets"][0];
    assert skt["cable"] > 2.5 or skt["status"] == "ERROR";
    assert any([k["level"] in ["WARNING", "ERROR"] for k in skt["checks"] as list[dict[str, str]]]);
}

test "the consumer unit is never suggested in a bathroom" {
    spot = suggest_cu([{**r, "loads": [[r["centroid"][0], r["centroid"][1], 100.0]]} for r in _house()], []) as dict[str, any];
    assert spot["room_name"] != "Bath";
}
