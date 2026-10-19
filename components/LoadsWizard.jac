sv import from ..services.floorPlanService { LoadsResult, LoadInfo, AcOption, RoomRef, CatalogGroup, CatalogItem, DemandInfo, LoadPreview }

# One question in the appliance sequence: kind is "ac" | "pump" | "wh" | "wm" | "custom"
obj Question {
    has kind: str;
    has room_id: str = "";
}

def build_questions(data: LoadsResult) -> list[Question] {
    qs: list[Question] = [];
    for a in data.ac_rooms {
        qs.append(Question(kind="ac", room_id=a.room_id));
    }
    qs.append(Question(kind="pump"));
    for b in data.bathrooms {
        qs.append(Question(kind="wh", room_id=b.room_id));
    }
    if data.kitchen is not None {
        qs.append(Question(kind="wm"));
    }
    qs.append(Question(kind="custom"));
    return qs;
}

def find_ac(options: list[AcOption], room_id: str) -> AcOption | None {
    for a in options { if a.room_id == room_id { return a; } }
    return None;
}

def find_room(rooms: list[RoomRef], room_id: str) -> RoomRef | None {
    for r in rooms { if r.room_id == room_id { return r; } }
    return None;
}

def fmt_w(w: float) -> str {
    if w >= 1000.0 { return f"{w / 1000.0:.1f} kW"; }
    return f"{w:.0f} W";
}

def fmt_btu(b: float) -> str {
    return f"{round(b):,} BTU";
}

"""Step 3 of Suggest wiring: ACs room by room, water pump, hot water, washing machine, then custom loads."""
def:pub LoadsWizard(
    data: LoadsResult | None,
    busy: bool,
    onAddAc: Callable[[str], None],
    onAddLoad: Callable[[str, str, float, str], None],
    onRemove: Callable[[str], None],
    onHover: Callable[[str], None],
    preview: LoadPreview | None,
    moved: bool,
    onPreview: Callable[[str, str], None],
    onReset: Callable[[], None],
    onNext: Callable[[], None]
) -> JsxElement {
    has step: int = 0;
    has cat_id: str = "";
    has pick_id: str = "";
    has pick_room: str = "";
    has pick_watts: str = "";
    has pick_name: str = "";

    questions: list[Question] = build_questions(data) if data is not None else [];
    total_q = len(questions);
    q: Question | None = questions[step] if data is not None and step < total_q else None;
    loads: list[LoadInfo] = data.loads if data is not None else [];
    ac_rooms: list[AcOption] = data.ac_rooms if data is not None else [];
    baths: list[RoomRef] = data.bathrooms if data is not None else [];
    rooms: list[RoomRef] = data.rooms if data is not None else [];
    groups: list[CatalogGroup] = data.catalog if data is not None else [];
    kitchen: RoomRef | None = data.kitchen if data is not None else None;
    demand: DemandInfo | None = data.demand if data is not None else None;
    demand_rows = demand.rows if demand is not None else [];
    demand_fixes: list[str] = demand.fixes if demand is not None else [];
    active_cat = cat_id if cat_id != "" else (groups[0].id if len(groups) > 0 else "");

    q_room = q.room_id if q is not None else "";
    q_kind = q.kind if q is not None else "";
    ac: AcOption | None = find_ac(ac_rooms, q_room);
    bath: RoomRef | None = find_room(baths, q_room);
    picked: CatalogItem | None = None;
    active_items: list[CatalogItem] = [];
    for g in groups {
        for it in g.items { if it.id == pick_id { picked = it; } }
        if g.id == active_cat { active_items = g.items; }
    }

    ac_id = ac.room_id if ac is not None else "";
    bath_id = bath.room_id if bath is not None else "";
    kitchen_id = kitchen.room_id if kitchen is not None else "";

    # What the current question would add, so the plan can show where it goes before the user says yes
    preview_item = "";
    preview_room = "";
    pump_tag = data.pump_tag if data is not None else "x";
    wm_tag = data.wm_tag if data is not None else "x";
    ac_free = ac.tag == "" if ac is not None else False;
    ac_size = ac.size_btu if ac is not None else 0;
    bath_free = bath.tag == "" if bath is not None else False;
    if data is not None {
        if q_kind == "ac" and ac_free {
            preview_item = f"ac_{ac_size}";
            preview_room = ac_id;
        } elif q_kind == "pump" and pump_tag == "" and kitchen_id != "" {
            preview_item = "pump_1hp";
            preview_room = kitchen_id;
        } elif q_kind == "wh" and bath_free {
            preview_item = "water_heater_instant";
            preview_room = bath_id;
        } elif q_kind == "wm" and wm_tag == "" and kitchen_id != "" {
            preview_item = "washing_machine";
            preview_room = kitchen_id;
        } elif q_kind == "custom" and pick_id != "" and pick_room != "" {
            preview_item = pick_id;
            preview_room = pick_room;
        }
    }
    preview_key = preview_item + "|" + preview_room;
    can with [preview_key] entry {
        onPreview(preview_item, preview_room);
    }
    shown: LoadPreview | None = preview if preview is not None and preview.ok and preview.room_id == preview_room and preview_room != "" else None;
    where_text = shown.where if shown is not None else "";
    where_tag = shown.tag if shown is not None else "";

    def next_q() { step = step + 1; }
    def back_q() { if step > 0 { step = step - 1; } }

    def add_custom() {
        if picked is None or pick_room == "" { return; }
        watts = float(pick_watts) if pick_watts != "" else 0.0;
        onAddLoad(pick_id, pick_room, watts, pick_name);
        pick_id = "";
        pick_watts = "";
        pick_name = "";
    }

    def choose_item(it: CatalogItem) {
        pick_id = it.id;
        pick_watts = str(round(it.watts));
        pick_name = "";
        if pick_room == "" and len(rooms) > 0 { pick_room = rooms[0].room_id; }
    }

    return <div className="ld">
        <div className="rr-head">
            <div><div className="rr-kicker">STEP 3 OF 3 · APPLIANCES</div><div className="rr-title">AC, water and other loads</div></div>
        </div>
        {data is None and <div className="rr-note rr-scanning"><span className="rr-dot" />Loading rooms…</div>}
        {data is not None and not data.sized and <div className="rr-warn">Plan is not to scale: AC sizes use an assumed room area. Use <strong>Set scale</strong> first.</div>}

        {q is not None and <div className="ld-progress"><div className="ld-bar" style={{"width": str(round((step + 1) * 100 / total_q)) + "%"}} /><span>{"QUESTION " + str(step + 1) + " OF " + str(total_q)}</span></div>}

        {q is not None and q.kind == "ac" and ac is not None and <div className="rr-card rr-ask ld-q">
            <div className="rr-row"><span className="rr-num rr-num-ask">AC</span><span className="rr-q">{"Add an air conditioner to " + ac.name + "?"}</span></div>
            <div className="ld-calc">
                <div>{f"Area {ac.area_m2:.1f} m² × {ac.btu_per_m2:.0f} BTU/m² = {fmt_btu(ac.need_btu)}"}</div>
                <div><strong>{(str(ac.units) + " × " if ac.units > 1 else "") + fmt_btu(ac.size_btu) + " unit · " + fmt_w(ac.watts)}</strong></div>
                <div className="wl-rule">{"BTU rule · Trust: " + ac.trust}</div>
            </div>
            {ac.tag != "" and <div className="ld-done">{ac.tag + " added with its plug base ✓"}</div>}
{where_text != "" and <div className="ld-where"><span className="ld-where-pin">{where_tag}</span><div><div>{(("Your position in " + shown.room_name) if moved else where_text) if shown is not None else ""}</div><div className="wl-rule">{"Shown on the plan. Drag " + where_tag + " or its plug to move it" + ("" if not moved else ", or ")}{moved and <button className="rr-link" onClick={lambda { onReset(); }}>reset to suggestion</button>}</div></div></div>}
            <div className="rr-chips">
                {ac.tag == "" and <button className="rr-chip" disabled={busy} onClick={lambda { onAddAc(ac_id); next_q(); }}>{"Yes, add " + fmt_btu(ac.size_btu)}</button>}
                <button className={"rr-chip" + (" rr-chip-muted" if ac.tag == "" else "")} onClick={lambda { next_q(); }}>{"No AC" if ac.tag == "" else "Next"}</button>
            </div>
        </div>}

        {q is not None and q.kind == "pump" and <div className="rr-card rr-ask ld-q">
            <div className="rr-row"><span className="rr-num rr-num-ask">P</span><span className="rr-q">Does the house need a water pump motor?</span></div>
            <div className="ld-calc">{"Its switch and outlet go in the " + (kitchen.name if kitchen is not None else "kitchen") + " by the door, labelled PUMP. A pump is a heavy motor load: it gets its own circuit and a type C breaker for the starting current."}</div>
            {kitchen is None and <div className="rr-warn">No kitchen on the plan. Add or rename a room as Kitchen first.</div>}
            {data is not None and data.pump_tag != "" and <div className="ld-done">PUMP added ✓</div>}
{where_text != "" and <div className="ld-where"><span className="ld-where-pin">{where_tag}</span><div><div>{(("Your position in " + shown.room_name) if moved else where_text) if shown is not None else ""}</div><div className="wl-rule">{"Shown on the plan. Drag " + where_tag + " or its plug to move it" + ("" if not moved else ", or ")}{moved and <button className="rr-link" onClick={lambda { onReset(); }}>reset to suggestion</button>}</div></div></div>}
            <div className="rr-chips">
                {kitchen is not None and data is not None and data.pump_tag == "" and <span className="ld-chips">
                    <button className="rr-chip" disabled={busy} onClick={lambda { onAddLoad("pump_0_5hp", kitchen_id, 0.0, ""); next_q(); }}>0.5 HP</button>
                    <button className="rr-chip" disabled={busy} onClick={lambda { onAddLoad("pump_1hp", kitchen_id, 0.0, ""); next_q(); }}>1 HP</button>
                    <button className="rr-chip" disabled={busy} onClick={lambda { onAddLoad("pump_1_5hp", kitchen_id, 0.0, ""); next_q(); }}>1.5 HP</button>
                </span>}
                <button className="rr-chip rr-chip-muted" onClick={lambda { next_q(); }}>{"No pump" if data is not None and data.pump_tag == "" else "Next"}</button>
            </div>
        </div>}

        {q is not None and q.kind == "wh" and bath is not None and <div className="rr-card rr-ask ld-q">
            <div className="rr-row"><span className="rr-num rr-num-ask">WH</span><span className="rr-q">{"Hot water in " + bath.name + "?"}</span></div>
            <div className="ld-calc">The heater goes in the bathroom; its double-pole switch goes just outside the door (Section 701). Instant: 4.5 kW on a B32, 6 mm². Storage: 3 kW on a B16, 2.5 mm² (rule profile templates).</div>
            {bath.tag != "" and <div className="ld-done">{bath.tag + " added ✓"}</div>}
{where_text != "" and <div className="ld-where"><span className="ld-where-pin">{where_tag}</span><div><div>{(("Your position in " + shown.room_name) if moved else where_text) if shown is not None else ""}</div><div className="wl-rule">{"Shown on the plan. Drag " + where_tag + " or its plug to move it" + ("" if not moved else ", or ")}{moved and <button className="rr-link" onClick={lambda { onReset(); }}>reset to suggestion</button>}</div></div></div>}
            <div className="rr-chips">
                {bath.tag == "" and <span className="ld-chips">
                    <button className="rr-chip" disabled={busy} onClick={lambda { onAddLoad("water_heater_instant", bath_id, 0.0, ""); next_q(); }}>Instant 4.5 kW</button>
                    <button className="rr-chip" disabled={busy} onClick={lambda { onAddLoad("water_heater_storage", bath_id, 0.0, ""); next_q(); }}>Storage 3 kW</button>
                </span>}
                <button className="rr-chip rr-chip-muted" onClick={lambda { next_q(); }}>{"No hot water" if bath.tag == "" else "Next"}</button>
            </div>
        </div>}

        {q is not None and q.kind == "wm" and kitchen is not None and <div className="rr-card rr-ask ld-q">
            <div className="rr-row"><span className="rr-num rr-num-ask">WM</span><span className="rr-q">{"Washing machine in the " + kitchen.name + "?"}</span></div>
            <div className="ld-calc">Adds the washing machine and its own 13 A switched socket (plug base) beside it, on a B20 radial, 2.5 mm².</div>
            {data is not None and data.wm_tag != "" and <div className="ld-done">{data.wm_tag + " added ✓"}</div>}
{where_text != "" and <div className="ld-where"><span className="ld-where-pin">{where_tag}</span><div><div>{(("Your position in " + shown.room_name) if moved else where_text) if shown is not None else ""}</div><div className="wl-rule">{"Shown on the plan. Drag " + where_tag + " or its plug to move it" + ("" if not moved else ", or ")}{moved and <button className="rr-link" onClick={lambda { onReset(); }}>reset to suggestion</button>}</div></div></div>}
            <div className="rr-chips">
                {data is not None and data.wm_tag == "" and <button className="rr-chip" disabled={busy} onClick={lambda { onAddLoad("washing_machine", kitchen_id, 0.0, ""); next_q(); }}>Yes, add it</button>}
                <button className="rr-chip rr-chip-muted" onClick={lambda { next_q(); }}>{"No" if data is not None and data.wm_tag == "" else "Next"}</button>
            </div>
        </div>}

        {q is not None and q.kind == "custom" and <div className="rr-card ld-q ld-custom">
            <div className="rr-row"><span className="rr-num rr-num-ask">+</span><span className="rr-q">Any other loads to add?</span></div>
            <div className="ld-tabs">{for g in groups {<button key={g.id} className={"ld-tab" + (" ld-tab-on" if g.id == active_cat else "")} onClick={lambda { cat_id = g.id; }}>{g.name}</button>}}</div>
            <div className="ld-grid">
                {for it in active_items {
                    <button key={it.id} className={"ld-item" + (" ld-item-on" if it.id == pick_id else "")} onClick={lambda { choose_item(it); }}>
                        <span className="ld-item-tag">{it.tag}</span>
                        <span className="ld-item-name">{it.name}</span>
                        <span className="ld-item-w">{fmt_w(it.watts)}</span>
                    </button>
                }}
            </div>
            {picked is not None and <div className="ld-form">
                <div className="ld-form-title">{picked.name}</div>
                <div className="wl-rule">{picked.outlet + " · Trust: " + picked.trust}</div>
                <label className="ld-field"><span>Room</span><select className="rr-select" value={pick_room} onChange={lambda (e: ChangeEvent) { pick_room = e.target.value; }}>{for r in rooms {<option key={r.room_id} value={r.room_id}>{r.name}</option>}}</select></label>
                <label className="ld-field"><span>Watts</span><input className="rr-select" type="number" min="1" value={pick_watts} onChange={lambda (e: ChangeEvent) { pick_watts = e.target.value; }} /></label>
                <label className="ld-field"><span>Name</span><input className="rr-select" placeholder={picked.name} value={pick_name} onChange={lambda (e: ChangeEvent) { pick_name = e.target.value; }} /></label>
                {where_text != "" and <div className="ld-where"><span className="ld-where-pin">{where_tag}</span><div><div>{(("Your position in " + shown.room_name) if moved else where_text) if shown is not None else ""}</div><div className="wl-rule">{"Shown on the plan. Drag it to move."}</div></div></div>}
                <button className="rr-primary" disabled={busy or pick_room == ""} onClick={lambda { add_custom(); }}>{"Add " + picked.tag + " with its plug base"}</button>
            </div>}
<div className="rr-chips"><button className="rr-chip rr-chip-muted" onClick={lambda { next_q(); }}>Done, no more loads</button></div>
        </div>}

        {q is not None and step > 0 and <button className="rr-link ld-back" onClick={lambda { back_q(); }}>← Previous question</button>}
        {q is None and data is not None and <div className="rr-note">All questions answered. Review the loads below, or <button className="rr-link" onClick={lambda { step = 0; }}>start the questions again</button>.</div>}

        {len(loads) > 0 and <div className="rr-section">LOADS AND THEIR PLUG BASES</div>}
        {for l in loads {
            <div key={l.tag} className="ld-load" onMouseEnter={lambda { onHover(l.tag); }} onMouseLeave={lambda { onHover(""); }}>
                <div className="rr-row">
                    <span className="ld-tag">{l.tag}</span>
                    <span className="ld-load-name">{l.name}</span>
                    <span className="rr-conf">{fmt_w(l.watts)}</span>
                    <button className="rr-cross" title="Remove" aria-label={"Remove " + l.tag} onClick={lambda { onRemove(l.tag); }}>✕</button>
                </div>
                <div className="ld-plug"><span className="ld-plug-dot" />{"Plug base: " + l.outlet}</div>
                <div className="rr-meta">{f"Ib {l.ib:.1f} A · breaker {l.breaker}" + (f" · {l.cable:g} mm² T&E" if l.cable > 0.0 else " · cable in circuit step")}</div>
            </div>
        }}

        {demand is not None and len(demand_rows) > 0 and <div className={"ld-demand ld-demand-" + demand.level.lower()}>
            <div className="rr-row"><span className="rr-kicker">MAXIMUM DEMAND · WHOLE HOUSE</span><span className={"wl-lvl wl-lvl-" + demand.level.lower()}>{demand.level}</span></div>
            <div className="ld-meter"><div className="ld-meter-fill" style={{"width": str(min(100, round(demand.pct))) + "%"}} /></div>
            <div className="ld-demand-big">{f"{demand.ib_a:.1f} A of {demand.main_a:.0f} A main switch ({demand.pct:.0f}%)"}</div>
            {for (i, r) in enumerate(demand_rows) {
                <div key={str(i)} className="ld-drow"><span>{r.name}</span><span>{fmt_w(r.demand_w)}</span></div>
            }}
            <div className="wl-rule">{"Diversity (311.1) · Trust: " + demand.trust + " · Main switch: " + demand.main_trust}</div>
            {len(demand_fixes) > 0 and <div className="ld-fixes">{for (i, f) in enumerate(demand_fixes) {<div key={str(i)}>{"→ " + f}</div>}}</div>}
        </div>}

        {data is not None and <button className={"rr-primary" if q is None else "rr-outline"} onClick={lambda { onNext(); }}>Next: consumer unit and wiring →</button>}

        <style>{".ld{display:flex;flex-direction:column;gap:10px;font-size:11px}.ld-progress{position:relative;height:18px;border:1px solid #111;background:#fff}.ld-bar{position:absolute;left:0;top:0;bottom:0;background:#FFD600}.ld-progress span{position:relative;display:block;text-align:center;font-size:9px;font-weight:700;letter-spacing:.12em;line-height:16px}.ld-q{cursor:default}.ld-calc{display:flex;flex-direction:column;gap:2px;font-size:11px;color:#444;line-height:1.5}.ld-done{font-weight:700;color:#111;background:#fff;border:1px solid #111;padding:4px 8px;align-self:flex-start}.ld-chips{display:contents}.ld-where{display:flex;gap:8px;align-items:flex-start;border:1px dashed #b45309;background:#fff;padding:7px 8px;font-size:11px;line-height:1.4}.ld-where-pin{flex:none;background:#111;color:#FFD600;font-weight:700;font-size:10px;padding:2px 6px}.ld-back{align-self:flex-start}.ld-tabs{display:flex;flex-wrap:wrap;gap:4px}.ld-tab{border:1px solid #d4d4cf;background:#fff;padding:4px 7px;font-size:10px;cursor:pointer;font-family:inherit}.ld-tab-on{background:#111;color:#FFD600;border-color:#111;font-weight:700}.ld-grid{display:grid;grid-template-columns:1fr 1fr;gap:6px}.ld-item{display:flex;flex-direction:column;align-items:flex-start;gap:2px;border:1px solid #d4d4cf;background:#fff;padding:7px;text-align:left;cursor:pointer;font-family:inherit}.ld-item:hover{border-color:#111}.ld-item-on{border-color:#111;box-shadow:2px 2px 0 #111;background:#fffbe6}.ld-item-tag{font-size:9px;font-weight:700;background:#2563eb;color:#fff;padding:0 4px}.ld-item-name{font-size:11px;font-weight:700;line-height:1.3}.ld-item-w{font-size:10px;color:#777}.ld-form{display:flex;flex-direction:column;gap:6px;border-top:1px dashed #d4d4cf;padding-top:8px}.ld-form-title{font-weight:700;font-size:12px}.ld-field{display:grid;grid-template-columns:52px 1fr;align-items:center;gap:6px;font-size:10px;color:#777}.ld-load{border:1px solid #d4d4cf;background:#fff;padding:8px 10px;display:flex;flex-direction:column;gap:5px}.ld-load:hover{border-color:#2563eb;box-shadow:3px 3px 0 #2563eb}.ld-tag{flex:none;background:#2563eb;color:#fff;font-weight:700;font-size:10px;padding:2px 6px}.ld-load-name{flex:1;min-width:0;font-weight:700;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.ld-plug{display:flex;align-items:flex-start;gap:6px;font-size:10px;color:#1e3a8a;line-height:1.4}.ld-plug-dot{flex:none;width:10px;height:7px;margin-top:3px;background:#2563eb;border:1px solid #111}.ld-demand{border:1px solid #111;background:#fff;padding:10px;display:flex;flex-direction:column;gap:6px}.ld-demand-warning{border-left:4px solid #e2c300}.ld-demand-error{border-left:4px solid #e00}.ld-meter{height:8px;border:1px solid #111;background:#f3f3f0}.ld-meter-fill{height:100%;background:#111}.ld-demand-warning .ld-meter-fill{background:#e2c300}.ld-demand-error .ld-meter-fill{background:#e00}.ld-demand-big{font-size:13px;font-weight:700}.ld-drow{display:flex;justify-content:space-between;gap:8px;font-size:10px;color:#555}.ld-fixes{display:flex;flex-direction:column;gap:3px;font-size:10px;color:#7a1d1d}.is-dark .ld-load,.is-dark .ld-demand,.is-dark .ld-item,.is-dark .ld-tab,.is-dark .ld-progress{background:#2a2a2a;border-color:#555;color:#eee}.is-dark .ld-calc{color:#ccc}"}</style>
    </div>;
}
