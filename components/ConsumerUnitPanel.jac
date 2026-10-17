import from ..services.floorPlanService { CuInfo, CircuitInfo, BoardInfo, LayoutCheck }

# One DIN-rail module on the drawn board
obj Module {
    has kind: str;          # main | spd | rcd | mcb | spare
    has width: int;         # in modules
    has top: str;
    has big: str;
    has small: str;
    has label: str;
    has circuit: str = "";
    has status: str = "";
}

def board_modules(board: BoardInfo, circuits: list[CircuitInfo]) -> list[Module] {
    mods: list[Module] = [Module(kind="main", width=2, top="MAIN", big=f"{board.main_a}A", small="2P", label="MAIN SWITCH")];
    if board.spd {
        mods.append(Module(kind="spd", width=2, top="SPD", big="T2", small="1P+N", label="SURGE PROT."));
    }
    for rcd in ["RCD1", "RCD2"] {
        mods.append(Module(kind="rcd", width=2, top=rcd, big=f"{board.rccb_a}A", small=f"{board.rccb_ma}mA {board.rccb_type}", label=f"{rcd} {board.rccb_a}A"));
        for c in circuits {
            if c.rcd == rcd {
                mods.append(Module(kind="mcb", width=1, top=c.id, big=c.breaker, small=f"{c.cable:g}", label=short_name(c), circuit=c.id, status=c.status));
            }
        }
    }
    used = sum([m.width for m in mods]);
    for _ in range(board.rows * board.row_modules - used) {
        mods.append(Module(kind="spare", width=1, top="", big="", small="", label=""));
    }
    return mods;
}

def short_name(c: CircuitInfo) -> str {
    if c.kind == "dedicated" { return c.tag if c.tag != "" else c.name; }
    prefix = "LTG " if c.kind == "lighting" else "SKT ";
    return prefix + " ".join([r[:3].upper() for r in c.rooms]);
}

def kind_label(kind: str) -> str {
    if kind == "lighting" { return "Lighting"; }
    if kind == "sockets" { return "Sockets"; }
    return "Dedicated";
}

"""Step 4 of Suggest wiring: place the consumer unit, then design and draw every circuit."""
def:pub ConsumerUnitPanel(
    cu: CuInfo | None,
    busy: bool,
    moved: bool,
    onConfirm: Callable[[], None],
    onMove: Callable[[], None],
    onReset: Callable[[], None],
    onWire: Callable[[str, int, int, float, int, bool], None],
    onClear: Callable[[], None],
    onHover: Callable[[str], None],
    onFinalize: Callable[[], None],
    onOpenBooklet: Callable[[], None]
) -> JsxElement {
    has method: str = "";
    has ambient: str = "";
    has grouped: str = "";
    has ra: str = "";
    has main_a: str = "";
    has spd: bool = False;
    has spd_set: bool = False;
    has open_c: str = "";
    has form_open: bool = False;

    circuits: list[CircuitInfo] = cu.circuits if cu is not None else [];
    checks: list[LayoutCheck] = cu.checks if cu is not None else [];
    board: BoardInfo | None = cu.board if cu is not None and cu.wired else None;
    mods: list[Module] = board_modules(board, circuits) if board is not None else [];
    row_len = board.row_modules if board is not None else 13;
    rows: list[list[Module]] = [];
    cur: list[Module] = [];
    width = 0;
    for m in mods {
        if width + m.width > row_len {
            rows.append(cur);
            cur = [];
            width = 0;
        }
        cur.append(m);
        width += m.width;
    }
    if len(cur) > 0 { rows.append(cur); }
    rcd_count = 2 if board is not None else 0;
    methods = cu.methods if cu is not None else [];
    ambients = cu.ambients if cu is not None else [];
    groupings = cu.groupings if cu is not None else [];
    # Form values: what the user typed, else what the last design used, else the profile default
    v_method = method if method != "" else (cu.method if cu is not None else "");
    v_ambient = ambient if ambient != "" else str(cu.ambient_c if cu is not None else 30);
    v_grouped = grouped if grouped != "" else str(cu.grouped if cu is not None else 1);
    v_ra = ra if ra != "" else (str(cu.ra_ohm) if cu is not None and cu.ra_ohm > 0.0 else "");
    v_main = main_a if main_a != "" else str(cu.main_switch_a if cu is not None else 30);
    v_spd = spd if spd_set else (cu is not None and cu.spd);
    opened: CircuitInfo | None = None;
    for c in circuits {
        if c.id == open_c { opened = c; }
    }
    opened_title = (opened.id + " · " + opened.name) if opened is not None else "";
    opened_checks: list[LayoutCheck] = opened.checks if opened is not None else [];
    show_form = cu is not None and cu.confirmed and (not cu.wired or form_open or cu.stale);

    def wire() {
        onWire(v_method, int(v_ambient), int(v_grouped), float(v_ra) if v_ra != "" else 0.0, int(v_main), v_spd);
        form_open = False;
    }

    return <div className="cu">
        <div className="rr-head">
            <div><div className="rr-kicker">STEP 4 OF 4 · CONSUMER UNIT</div><div className="rr-title">Consumer unit and wiring</div></div>
        </div>
        {cu is None and <div className="rr-note rr-scanning"><span className="rr-dot" />Loading…</div>}
        {cu is not None and not cu.ok and cu.message != "" and <div className="rr-warn">{cu.message}</div>}
        {cu is not None and not cu.has_rooms and <div className="rr-warn">Add rooms first.</div>}

        {cu is not None and cu.has_rooms and not cu.confirmed and <div className="rr-card rr-ask ld-q">
            <div className="rr-row"><span className="rr-num rr-num-ask">CU</span><span className="rr-q">Where should the consumer unit go?</span></div>
            <div className="ld-where"><span className="ld-where-pin">CU</span><div>
                <div>{("Your position" + (" in " + cu.room_name if cu.room_name != "" else "")) if moved else (cu.reason if cu.reason != "" else "Suggested position")}</div>
                <div className="wl-rule">{"Shown on the plan. Drag it to move" + ("" if moved else (" · Trust: " + cu.trust if cu.trust != "" else ""))}{moved and <span>{", or "}<button className="rr-link" onClick={lambda { onReset(); }}>reset to suggestion</button></span>}</div>
            </div></div>
            <div className="rr-chips"><button className="rr-chip" disabled={busy} onClick={lambda { onConfirm(); }}>Confirm location</button></div>
        </div>}

        {cu is not None and cu.confirmed and <div className="cu-loc">
            <span className="ld-where-pin">CU</span>
            <span>{"Consumer unit" + (" · " + cu.room_name if cu.room_name != "" else "")}</span>
            <button className="rr-link" onClick={lambda { onMove(); }}>Move</button>
        </div>}

        {cu is not None and cu.stale and <div className="rr-warn">The plan changed after wiring (devices added, moved or removed). Start wire again to update the circuits.</div>}

        {show_form and <div className="rr-card ld-q">
            <div className="rr-q">Start wire</div>
            <label className="ld-field cu-field"><span>Install method</span>
                <select className="rr-select" value={v_method} onChange={lambda (e: ChangeEvent) { method = e.target.value; }}>
                    <option value="">Choose (required)…</option>
                    {for m in methods { <option key={m.id} value={m.id}>{m.label}</option> }}
                </select>
            </label>
            <label className="ld-field cu-field"><span>Ambient °C</span>
                <select className="rr-select" value={v_ambient} onChange={lambda (e: ChangeEvent) { ambient = e.target.value; }}>{for a in ambients { <option key={str(a)} value={str(a)}>{str(a) + " °C"}</option> }}</select>
            </label>
            <label className="ld-field cu-field"><span>Cables grouped</span>
                <select className="rr-select" value={v_grouped} onChange={lambda (e: ChangeEvent) { grouped = e.target.value; }}>{for g in groupings { <option key={str(g)} value={str(g)}>{("1 (not grouped)" if g == 1 else str(g) + " circuits together")}</option> }}</select>
            </label>
            <label className="ld-field cu-field"><span>Earth RA Ω</span><input className="rr-select" type="number" min="0" placeholder="measured electrode resistance" value={v_ra} onChange={lambda (e: ChangeEvent) { ra = e.target.value; }} /></label>
            <label className="ld-field cu-field"><span>Main switch A</span><input className="rr-select" type="number" min="1" value={v_main} onChange={lambda (e: ChangeEvent) { main_a = e.target.value; }} /></label>
            <label className="cu-check"><input type="checkbox" checked={v_spd} onChange={lambda (e: ChangeEvent) { spd = not v_spd; spd_set = True; }} />Surge protector (Type 2 SPD)</label>
            <div className="wl-rule">{"Methods · Trust: " + (cu.methods_trust if cu is not None else "")}</div>
            <button className="rr-primary" disabled={busy or v_method == ""} onClick={lambda { wire(); }}>{"Calculating…" if busy else "Start wire"}</button>
            {v_method == "" and <div className="rr-hint">Pick the installation method: cable ratings depend on it.</div>}
        </div>}

        {board is not None and <div className="cu-body">
            <div className="cu-tiles">
                <div><span className="wl-big">{str(len(circuits))}</span><span>CIRCUITS</span></div>
                <div><span className="wl-big">{str(rcd_count)}</span><span>RCDS</span></div>
                <div><span className="wl-big">{str(board.rows) + " × " + str(board.row_modules)}</span><span>ROWS</span></div>
            </div>
            <div className={"cu-spare" + (" cu-spare-low" if board.spare_pct < 20.0 else "")}><span className="cu-sq" />{f"Spare capacity: {board.rows * board.row_modules - board.used_modules} modules ({board.spare_pct:.0f}%) — ≥ 20% required"}</div>
            <div className="cu-board">
                {for (ri, row) in enumerate(rows) {
                    <div key={str(ri)} className="cu-row">
                        <div className="cu-row-tag">{"ROW " + str(ri + 1)}</div>
                        <div className="cu-rail">
                            {for (mi, m) in enumerate(row) {
                                <div key={str(mi)} className={"cu-mod cu-" + m.kind + (" cu-bad" if m.status == "ERROR" else "")} style={{"flex": str(m.width)}} onMouseEnter={lambda { onHover(m.circuit); }} onMouseLeave={lambda { onHover(""); }} onClick={lambda { if m.circuit != "" { open_c = "" if open_c == m.circuit else m.circuit; } }}>
                                    <div className="cu-face"><span className="cu-top">{m.top}</span><span className="cu-big">{m.big}</span>{m.kind == "mcb" and <span className="cu-toggle" />}<span className="cu-small">{m.small}</span></div>
                                    <div className="cu-label"><span>{m.label}</span></div>
                                </div>
                            }}
                        </div>
                    </div>
                }}
            </div>
            <div className="rr-hint">Tap a breaker to see its checks.</div>

            <div className="rr-section">CIRCUIT SCHEDULE</div>
            <div className="cu-table">
                <div className="cu-tr cu-th"><span>NO</span><span>CIRCUIT</span><span>PROT.</span><span>CABLE</span><span>VD</span></div>
                {for c in circuits {
                    <div key={c.id} className={"cu-tr" + (" cu-tr-on" if open_c == c.id else "")} onMouseEnter={lambda { onHover(c.id); }} onMouseLeave={lambda { onHover(""); }} onClick={lambda { open_c = "" if open_c == c.id else c.id; }}>
                        <span className={"cu-no cu-no-" + c.kind}>{c.id}</span>
                        <span className="cu-cname">{c.name}<small>{c.rcd + " · " + f"{c.length_m:.0f} m · Ib {c.ib:.1f} A"}</small></span>
                        <span>{c.breaker}</span>
                        <span>{f"{c.cable:g} mm²"}</span>
                        <span className={"cu-st cu-st-" + c.status.lower()}>{f"{c.vd_pct:.1f}%"}</span>
                    </div>
                }}
            </div>
            {opened is not None and <div className="rr-card wl-checks">
                <div className="rr-q">{opened_title}</div>
                {for (ci, k) in enumerate(opened_checks) {
                    <div key={str(ci)} className="wl-check"><span className={"wl-lvl wl-lvl-" + k.level.lower()}>{k.level}</span><div><div>{k.text}</div><div className="wl-rule">{k.rule + " · Trust: " + k.trust}</div></div></div>
                }}
            </div>}

            <div className="rr-section">WHOLE INSTALLATION</div>
            <div className="rr-card wl-checks">
                {for (ci, k) in enumerate(checks) {
                    <div key={str(ci)} className="wl-check"><span className={"wl-lvl wl-lvl-" + k.level.lower()}>{k.level}</span><div><div>{k.text}</div><div className="wl-rule">{k.rule + " · Trust: " + k.trust}</div></div></div>
                }}
            </div>
            <div className="rr-hint">{cu.summary if cu is not None else ""}</div>
            <div className="rr-actions">
                {cu is not None and not cu.finalized and <button className="rr-primary" disabled={busy or cu.stale} onClick={lambda { onFinalize(); }}>Finalize wiring and create booklet</button>}
                {cu is not None and cu.finalized and <div className="cu-final"><span className="ld-where-pin">FINAL</span>{"Finalized " + cu.finalized_at}</div>}
                {cu is not None and cu.finalized and <button className="rr-primary" onClick={lambda { onOpenBooklet(); }}>Open wiring booklet</button>}
                {not show_form and <button className="rr-outline" onClick={lambda { form_open = True; }}>Change inputs and re-wire</button>}
                <button className="rr-outline" onClick={lambda { onClear(); }}>Remove wiring</button>
            </div>
        </div>}

        <style>{".ld-q{cursor:default}.ld-where{display:flex;gap:8px;align-items:flex-start;border:1px dashed #b45309;background:#fff;padding:7px 8px;font-size:11px;line-height:1.4}.ld-where-pin{flex:none;background:#111;color:#FFD600;font-weight:700;font-size:10px;padding:2px 6px}.ld-field{display:grid;align-items:center;gap:6px;font-size:10px;color:#777}.cu-final{display:flex;align-items:center;gap:8px;font-weight:700}.cu{display:flex;flex-direction:column;gap:10px;font-size:11px}.cu-loc{display:flex;align-items:center;gap:8px;border:1px solid #111;background:#fff;padding:7px 9px}.cu-loc span:nth-child(2){flex:1;font-weight:700}.cu-field{grid-template-columns:96px 1fr}.cu-check{display:flex;align-items:center;gap:8px;font-size:11px}.cu-body{display:flex;flex-direction:column;gap:10px}.cu-tiles{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid #e5e5e2;border-bottom:1px solid #e5e5e2}.cu-tiles>div{display:flex;flex-direction:column;padding:8px 6px;font-size:9px;letter-spacing:.12em;color:#777;font-weight:700;border-right:1px solid #e5e5e2}.cu-tiles>div:last-child{border-right:none}.cu-spare{display:flex;align-items:center;gap:6px;color:#15803d;font-size:11px}.cu-spare-low{color:#b45309}.cu-sq{width:8px;height:8px;background:currentColor}.cu-board{border:2px solid #111;background:#ecebe6;padding:8px;display:flex;flex-direction:column;gap:8px}.cu-row{border:1px solid #9a9a94;background:#e2e1db;padding:4px}.cu-row-tag{font-size:8px;letter-spacing:.12em;color:#555;padding:0 0 3px}.cu-rail{display:flex;gap:1px;min-height:150px}.cu-mod{display:flex;flex-direction:column;min-width:0;cursor:default}.cu-face{display:flex;flex-direction:column;align-items:center;gap:2px;height:84px;padding:3px 1px;border:1px solid #111;background:#fff;overflow:hidden}.cu-top{font-size:7px;font-weight:700}.cu-big{font-size:9px;font-weight:700;color:#111}.cu-small{font-size:7px;color:#555;margin-top:auto}.cu-toggle{width:6px;height:16px;background:#2563eb;border:1px solid #111}.cu-label{flex:1;display:flex;align-items:flex-start;justify-content:center;border:1px solid #c9c8c2;border-top:none;background:#f7f6f1;padding-top:3px;min-height:60px}.cu-label span{writing-mode:vertical-rl;transform:rotate(180deg);font-size:7px;font-weight:700;letter-spacing:.06em;white-space:nowrap;overflow:hidden;max-height:58px}.cu-main .cu-face{background:#111}.cu-main .cu-top,.cu-main .cu-big{color:#FFD600}.cu-main .cu-small{color:#ddd}.cu-rcd .cu-face{background:#111}.cu-rcd .cu-top{color:#FFD600}.cu-rcd .cu-big{color:#fff}.cu-rcd .cu-small{color:#ddd}.cu-spd .cu-face{background:#FFD600}.cu-mcb{cursor:pointer}.cu-mcb:hover .cu-face{outline:2px solid #FFD600}.cu-bad .cu-face{outline:2px solid #e00}.cu-spare .cu-face,.cu-spare .cu-label{background:repeating-linear-gradient(45deg,#e2e1db,#e2e1db 3px,#d3d2cc 3px,#d3d2cc 5px);border-color:#c9c8c2}.cu-table{display:flex;flex-direction:column;border:1px solid #e5e5e2;background:#fff}.cu-tr{display:grid;grid-template-columns:30px 1fr 36px 50px 38px;gap:4px;align-items:center;padding:6px;border-bottom:1px solid #f0f0ec;font-size:10px;cursor:pointer}.cu-tr:hover,.cu-tr-on{background:#fffbe6}.cu-th{font-size:8px;letter-spacing:.12em;color:#888;font-weight:700;cursor:default}.cu-th:hover{background:#fff}.cu-no{font-weight:700;color:#fff;text-align:center;padding:1px 0}.cu-no-lighting{background:#2563eb}.cu-no-sockets{background:#16a34a}.cu-no-dedicated{background:#dc2626}.cu-cname{display:flex;flex-direction:column;font-weight:700;min-width:0}.cu-cname small{font-weight:400;color:#888;font-size:9px}.cu-st{font-weight:700;text-align:right}.cu-st-warning{color:#b45309}.cu-st-error{color:#e00}.is-dark .cu-loc,.is-dark .cu-table{background:#2a2a2a;border-color:#555}"}</style>
    </div>;
}
