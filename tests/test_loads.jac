"""Appliance loads: AC sizing, breakers from the rule profile's circuit templates, maximum demand."""

import from services.layoutDesigner { ac_sizing, find_item, protection, max_demand, place_by_door }

test "AC size comes from room area and the next standard unit" {
    s = ac_sizing(7.9) as dict[str, any];
    # 7.9 m2 x 700 BTU/m2 = 5530 BTU -> 9,000 BTU unit, 900 W from the profile's typical loads
    assert s["size_btu"] == 9000 and s["units"] == 1 and s["watts"] == 900.0;
    big = ac_sizing(40.0) as dict[str, any];
    assert big["size_btu"] == 24000 and big["units"] == 2;
}

test "template loads use the profile's breaker and cable" {
    wh = find_item("water_heater_instant") as dict[str, any];
    p = protection(wh, wh["watts"] as float) as dict[str, any];
    assert p["breaker"] == "B32" and p["cable"] == 6.0;
    assert abs((p["ib"] as float) - 4500.0 / 230.0) < 0.01;
}

test "a pump is a heavy motor load on a type C breaker" {
    pump = find_item("pump_1hp") as dict[str, any];
    p = protection(pump, pump["watts"] as float) as dict[str, any];
    assert (p["breaker"] as str).startswith("C");
    assert any([c["level"] == "INFO" and "motor" in c["text"] for c in p["checks"] as list[dict[str, str]]]);
}

test "maximum demand applies the profile diversity and flags an overloaded main switch" {
    small = max_demand(200.0, [["bedroom", 3]], []) as dict[str, any];
    assert small["level"] == "PASS";
    loads = [
        {"name": "WH", "demand": "WATER_HEATER_INSTANT", "watts": 4500.0},
        {"name": "WH", "demand": "WATER_HEATER_INSTANT", "watts": 4500.0},
        {"name": "AC", "demand": "AC", "watts": 1800.0}
    ];
    big = max_demand(300.0, [["kitchen", 6], ["living", 4]], loads) as dict[str, any];
    assert big["level"] == "ERROR" and len(big["fixes"] as list) > 0;
}

test "a switch outside the room lands outside, next to the door" {
    sq = [0.0, 0.0, 300.0, 0.0, 300.0, 300.0, 0.0, 300.0];
    (p, found) = place_by_door(sq, (0.0, 0.0, 300.0, 300.0), [150.0, 300.0, 90.0], [], True);
    assert found and p[1] > 300.0 and abs(p[0] - 150.0) < 120.0, f"not outside by the door: {p}";
}
