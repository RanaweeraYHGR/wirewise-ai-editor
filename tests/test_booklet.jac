"""Wiring booklet: bill of materials and the overall verdict."""

import from services.layoutDesigner { bill_of_materials, design_wiring }

test "cables are totalled per size and MCBs counted per rating" {
    circuits = [
        {"id": "C1", "cable": 1.5, "cpc": 1.0, "length_m": 20.0, "breaker": "B6"},
        {"id": "C2", "cable": 1.5, "cpc": 1.0, "length_m": 12.5, "breaker": "B6"},
        {"id": "C3", "cable": 2.5, "cpc": 1.5, "length_m": 30.0, "breaker": "B20"}
    ];
    board = {"main_a": 30, "spd": False, "rccb_a": 40, "rccb_ma": 30, "rccb_type": "A", "rows": 1, "row_modules": 13, "used_modules": 9};
    devices = [{"kind": "Lighting point", "spec": "18 W LED · 1600 lm", "outlet": ""}, {"kind": "Socket 16A", "spec": "Twin 13 A BS 1363", "outlet": ""}];
    lines = bill_of_materials(circuits, board, devices) as list[dict[str, any]];
    t15 = [l for l in lines if l["item"] == "Twin & earth 1.5/1 mm²"][0];
    assert abs((t15["qty"] as float) - 32.5) < 0.01;
    b6 = [l for l in lines if l["item"] == "MCB" and "B 6 A" in str(l["spec"])][0];
    assert b6["qty"] == 2.0;
    assert len([l for l in lines if l["item"] == "RCCB" and l["qty"] == 2.0]) == 1;
    assert len([l for l in lines if l["item"] == "Surge protective device"]) == 0, "no SPD when not ticked";
}

test "a whole-installation error changes the verdict" {
    rooms = [{
        "id": "K", "name": "Kitchen", "type": "kitchen", "area_m2": 12.0, "centroid": [150.0, 150.0],
        "poly": [0.0, 0.0, 300.0, 0.0, 300.0, 400.0, 0.0, 400.0], "rect": (0.0, 0.0, 300.0, 400.0), "doors": [],
        "lights": [[150.0, 200.0, 18.0]], "switches": [[20.0, 380.0]], "sockets": [[15.0, 50.0]],
        "loads": [
            {"tag": "WH1", "name": "Instant water heater", "item_id": "water_heater_instant", "watts": 4500.0, "x": 200.0, "y": 50.0},
            {"tag": "WH2", "name": "Instant water heater", "item_id": "water_heater_instant", "watts": 4500.0, "x": 250.0, "y": 50.0}
        ]
    }];
    d = design_wiring([10.0, 10.0], rooms, {"method": "C", "ambient_c": 30, "grouped": 1, "ra_ohm": 100.0, "main_a": 30, "spd": False}) as dict[str, any];
    assert (d["summary"] as str).startswith("Errors"), "maximum demand over the main switch must not read as passed";
}
