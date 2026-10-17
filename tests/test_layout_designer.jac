"""Layout designer: counts follow the rule profile's lumen method and the Section 701 socket rule."""

import from services.layoutDesigner { design_room }

# 3 m x 3 m room (canvas cm) with a 90 cm doorway in the middle of the bottom wall
glob SQUARE: list[float] = [0.0, 0.0, 300.0, 0.0, 300.0, 300.0, 0.0, 300.0];
glob DOOR: list[float] = [150.0, 300.0, 90.0];

def _design(room_type: str) -> dict[str, any] {
    return design_room(room_type, SQUARE, (0.0, 0.0, 300.0, 300.0), DOOR, True) as dict[str, any];
}

test "bedroom uses the lumen method from the rule profile" {
    d = _design("bedroom");
    # 150 lx x 9 m2 / (0.6 x 0.8) = 2812.5 lm; N = round(9 / 6) = 2; smallest lamp >= 1406 lm is 1600 lm / 18 W
    assert len(d["lights"] as list) == 2;
    assert d["lamp_lumens"] == 1600 and d["lamp_watts"] == 18;
    assert abs((d["lumens_needed"] as float) - 2812.5) < 0.01;
    assert len(d["sockets"] as list) == 3;
}

test "bathroom gets no sockets and Section 701 notes" {
    d = _design("bathroom");
    assert len(d["sockets"] as list) == 0;
    rules = " ".join([c["rule"] for c in d["checks"] as list[dict[str, str]]]);
    assert "701" in rules;
}

test "room type without a lux target warns instead of inventing one" {
    d = _design("utility");
    assert len(d["lights"] as list) == 1;
    texts = " ".join([c["text"] for c in d["checks"] as list[dict[str, str]]]);
    assert "not in rule profile" in texts;
}

test "everything is placed inside the room and the switch sits by the door" {
    d = _design("living");
    for p in (d["lights"] as list[list[float]]) + (d["sockets"] as list[list[float]]) {
        assert p[0] > 0.0 and p[0] < 300.0 and p[1] > 0.0 and p[1] < 300.0, f"outside the room: {p}";
    }
    sw = d["switch"] as list[float];
    assert abs(sw[1] - 300.0) < 30.0 and abs(sw[0] - 150.0) < 100.0, f"switch not by the door: {sw}";
}
