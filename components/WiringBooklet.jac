sv import from ..services.floorPlanService { Booklet, BookletRoom, BomLine, KeyValue, CircuitInfo, LayoutCheck, PlanElement }
import from .DeviceSymbol { DeviceSymbol }

glob BOM_GROUPS: list[str] = ["Cables", "Consumer unit", "Lighting", "Switches", "Sockets", "Appliance outlets"];
glob KIND_COLOR: dict[str, str] = {"lighting": "#2563eb", "sockets": "#16a34a", "dedicated": "#dc2626"};

obj RcdGroup {
    has name: str;
    has x: float;
    has w: float;
    has n: int;
}

obj Col {
    has c: CircuitInfo;
    has x: float;
}

obj BomGroup {
    has name: str;
    has lines: list[BomLine];
}

# Smallest / largest value. Not min(list) / max(list): jac 0.34 compiles those to
# Math.min(array), which is NaN in the browser.
def list_min(xs: list[float]) -> float {
    m = xs[0];
    for v in xs { if v < m { m = v; } }
    return m;
}

def list_max(xs: list[float]) -> float {
    m = xs[0];
    for v in xs { if v > m { m = v; } }
    return m;
}

def pts(p: list[float]) -> str {
    out = "";
    i = 0;
    while i + 1 < len(p) {
        out = out + str(p[i]) + "," + str(p[i + 1]) + " ";
        i = i + 2;
    }
    return out;
}

def qty(q: float, unit: str) -> str {
    if unit == "m" {
        return "measure" if q == 0.0 else f"{q:.1f} m";
    }
    return str(round(q));
}

def kind_name(kind: str) -> str {
    if kind == "lighting" { return "Lighting"; }
    if kind == "sockets" { return "Sockets"; }
    return "Dedicated";
}

"""Single line diagram: supply, main switch, SPD, busbar, two RCCBs and every final circuit."""
def:pub SingleLineDiagram(b: Booklet) -> JsxElement {
    cw = 74.0;
    gap = 34.0;
    x0 = 60.0;
    rcd1: list[CircuitInfo] = [c for c in b.circuits if c.rcd == "RCD1"];
    rcd2: list[CircuitInfo] = [c for c in b.circuits if c.rcd == "RCD2"];
    w1 = max(1, len(rcd1)) * cw;
    w2 = max(1, len(rcd2)) * cw;
    g1 = x0 + 150.0;
    g2 = g1 + w1 + gap;
    width = g2 + w2 + 40.0;
    bus_y = 230.0;
    main_x = 90.0;
    label_h = 270.0;
    height = 420.0 + label_h;
    # Circuit columns with their x centre
    cols: list[Col] = [];
    for (i, c) in enumerate(rcd1) { cols.append(Col(c=c, x=g1 + cw * i + cw / 2.0)); }
    for (i, c) in enumerate(rcd2) { cols.append(Col(c=c, x=g2 + cw * i + cw / 2.0)); }
    groups = [RcdGroup(name="RCD1", x=g1, w=w1, n=len(rcd1)), RcdGroup(name="RCD2", x=g2, w=w2, n=len(rcd2))];
    board = b.board;

    return <svg className="bk-sld" viewBox={f"0 0 {width} {height}"} xmlns="http://www.w3.org/2000/svg">
        <g fontFamily="monospace" fontSize="11" fill="#111">
            <rect x="20" y="14" width="140" height="44" fill="#fff" stroke="#111" strokeWidth="1.5" />
            <text x="90" y="32" textAnchor="middle" fontWeight="700">SUPPLY</text>
            <text x="90" y="48" textAnchor="middle" fontSize="9">{b.supply + " · " + b.earthing}</text>
            <line x1={str(main_x)} y1="58" x2={str(main_x)} y2="88" stroke="#111" strokeWidth="2" />
            <rect x="40" y="88" width="100" height="46" fill="#111" />
            <text x="90" y="107" textAnchor="middle" fill="#FFD600" fontWeight="700">MAIN SWITCH</text>
            <text x="90" y="124" textAnchor="middle" fill="#fff" fontSize="10">{"2P " + str(board.main_a) + " A"}</text>
            <line x1={str(main_x)} y1="134" x2={str(main_x)} y2={str(bus_y)} stroke="#111" strokeWidth="2" />
            {board.spd and <g>
                <line x1={str(main_x)} y1="170" x2="150" y2="170" stroke="#111" strokeWidth="1.5" />
                <rect x="150" y="155" width="56" height="30" fill="#FFD600" stroke="#111" strokeWidth="1.5" />
                <text x="178" y="174" textAnchor="middle" fontWeight="700" fontSize="10">SPD T2</text>
                <line x1="206" y1="170" x2="226" y2="170" stroke="#111" strokeWidth="1.5" />
                <path d="M 226 160 L 226 180 M 231 163 L 231 177 M 236 166 L 236 174" stroke="#111" strokeWidth="1.5" />
            </g>}
            <line x1={str(main_x)} y1={str(bus_y)} x2={str(width - 30.0)} y2={str(bus_y)} stroke="#111" strokeWidth="4" />
            <text x={str(width - 30.0)} y={str(bus_y - 8.0)} textAnchor="end" fontSize="9">BUSBAR</text>
            {for g in groups {
                <g key={g.name}>
                    <line x1={str(g.x + g.w / 2.0)} y1={str(bus_y)} x2={str(g.x + g.w / 2.0)} y2={str(bus_y + 26.0)} stroke="#111" strokeWidth="2" />
                    <rect x={str(g.x + g.w / 2.0 - 62.0)} y={str(bus_y + 26.0)} width="124" height="44" fill="#111" />
                    <text x={str(g.x + g.w / 2.0)} y={str(bus_y + 44.0)} textAnchor="middle" fill="#FFD600" fontWeight="700">{g.name + " " + str(board.rccb_a) + " A"}</text>
                    <text x={str(g.x + g.w / 2.0)} y={str(bus_y + 61.0)} textAnchor="middle" fill="#fff" fontSize="9">{str(board.rccb_ma) + " mA Type " + board.rccb_type}</text>
                    <line x1={str(g.x + g.w / 2.0)} y1={str(bus_y + 70.0)} x2={str(g.x + g.w / 2.0)} y2={str(bus_y + 90.0)} stroke="#111" strokeWidth="2" />
                    {g.n > 0 and <line x1={str(g.x + cw / 2.0)} y1={str(bus_y + 90.0)} x2={str(g.x + g.w - cw / 2.0)} y2={str(bus_y + 90.0)} stroke="#111" strokeWidth="3" />}
                </g>
            }}
            {for col in cols {
                <g key={col.c.id}>
                    <line x1={str(col.x)} y1={str(bus_y + 90.0)} x2={str(col.x)} y2={str(bus_y + 108.0)} stroke="#111" strokeWidth="1.5" />
                    <rect x={str(col.x - 26.0)} y={str(bus_y + 108.0)} width="52" height="40" fill="#fff" stroke="#111" strokeWidth="1.5" />
                    <text x={str(col.x)} y={str(bus_y + 124.0)} textAnchor="middle" fontWeight="700">{col.c.id}</text>
                    <text x={str(col.x)} y={str(bus_y + 140.0)} textAnchor="middle" fontSize="10">{col.c.breaker}</text>
                    <line x1={str(col.x)} y1={str(bus_y + 148.0)} x2={str(col.x)} y2={str(bus_y + 178.0)} stroke={KIND_COLOR[col.c.kind]} strokeWidth="2.5" />
                    <g transform={f"rotate(90 {col.x - 4.0} {bus_y + 184.0})"}>
                        <text x={str(col.x - 4.0)} y={str(bus_y + 184.0)} fontSize="10" fontWeight="700">{f"{col.c.cable:g} mm² T&E · {col.c.length_m:.0f} m"}</text>
                        <text x={str(col.x - 4.0)} y={str(bus_y + 172.0)} fontSize="9" fill="#555">{col.c.name[:44]}</text>
                    </g>
                </g>
            }}
            <g transform={f"translate(20 {height - 70.0})"}>
                <rect width="96" height="26" fill="#fff" stroke="#111" strokeWidth="1.5" />
                <text x="48" y="17" textAnchor="middle" fontSize="10" fontWeight="700">MAIN EARTH</text>
                <line x1="48" y1="26" x2="48" y2="40" stroke="#16a34a" strokeWidth="2" />
                <path d="M 36 40 L 60 40 M 40 45 L 56 45 M 44 50 L 52 50" stroke="#111" strokeWidth="1.5" />
                <text x="70" y="50" fontSize="9">{"Earth electrode (TT) · RA " + (f"{b.ra_ohm:g} Ω" if b.ra_ohm > 0.0 else "not measured")}</text>
                <line x1="48" y1="0" x2="48" y2={str(-(height - 70.0 - bus_y - 20.0))} stroke="#16a34a" strokeWidth="1.5" strokeDasharray="5 4" />
            </g>
        </g>
    </svg>;
}

"""Floor plan with every device, circuit route and the consumer unit."""
def:pub WiringSchematic(b: Booklet) -> JsxElement {
    rooms: list[PlanElement] = b.plan.rooms if b.plan is not None else [];
    devices: list[PlanElement] = b.plan.devices if b.plan is not None else [];
    xs: list[float] = [r.x for r in rooms] + [r.x + r.width for r in rooms] + [b.cu_x];
    ys: list[float] = [r.y for r in rooms] + [r.y + r.height for r in rooms] + [b.cu_y];
    if b.bg_image != "" {
        xs = xs + [b.bg_x, b.bg_x + b.bg_w];
        ys = ys + [b.bg_y, b.bg_y + b.bg_h];
    }
    x0 = list_min(xs) - 40.0;
    y0 = list_min(ys) - 40.0;
    vw = list_max(xs) - x0 + 40.0;
    vh = list_max(ys) - y0 + 40.0;
    return <svg className="bk-plan" viewBox={f"{x0} {y0} {vw} {vh}"} xmlns="http://www.w3.org/2000/svg">
        <rect x={str(x0)} y={str(y0)} width={str(vw)} height={str(vh)} fill="#fff" />
        {b.bg_image != "" and <image href={b.bg_image} x={b.bg_x} y={b.bg_y} width={b.bg_w} height={b.bg_h} opacity="0.45" preserveAspectRatio="none" />}
        {for r in rooms {<g key={r.id}><rect x={r.x} y={r.y} width={r.width} height={r.height} fill="none" stroke="#999" strokeWidth="1" strokeDasharray="6 4" /><text x={r.x + 8.0} y={r.y + 18.0} fontSize="12" fontWeight="700" fontFamily="monospace" fill="#555">{r.label.upper()}</text></g>}}
        {for c in b.circuits {<g key={"w" + c.id}><polyline points={pts(c.path)} fill="none" stroke={KIND_COLOR[c.kind]} strokeWidth="2.2" opacity="0.85" /><text x={c.path[len(c.path) - 2] + 8.0} y={c.path[len(c.path) - 1] + 14.0} fontSize="10" fontWeight="700" fontFamily="monospace" fill={KIND_COLOR[c.kind]}>{c.id}</text></g>}}
        {for d in devices {<g key={d.id} transform={"translate(" + str(d.x) + " " + str(d.y) + ")"}><DeviceSymbol kind={d.kind} label={d.label} /></g>}}
        <g transform={"translate(" + str(b.cu_x) + " " + str(b.cu_y) + ")"}><rect x="-30" y="-15" width="60" height="30" fill="#fff" stroke="#111" strokeWidth="3" /><path d="M 30 -15 L 30 15 L -30 15 Z" fill="#111" /><text x="0" y="32" textAnchor="middle" fontSize="10" fontWeight="700" fontFamily="monospace">CONSUMER UNIT</text></g>
    </svg>;
}

"""Printable wiring booklet (A4 pages): cover, wiring layout, single line diagram, schedules, materials, checks."""
def:pub WiringBooklet(b: Booklet, onClose: Callable[[], None]) -> JsxElement {
    def print_it() {
        w: any = window;
        w.print();
    }
    bom_groups = [BomGroup(name=g, lines=[l for l in b.bom if l.group == g]) for g in BOM_GROUPS];

    return <div className="bk">
        <div className="bk-toolbar">
            <span className="bk-brand">LUMIRA · Wiring booklet</span>
            <button className="bk-btn bk-btn-main" onClick={lambda { print_it(); }}>Print / Save as PDF</button>
            <button className="bk-btn" onClick={lambda { onClose(); }}>Close</button>
        </div>

        <section className="bk-page bk-cover">
            <div className="bk-logo"><span>L</span>LUMIRA</div>
            <div className="bk-kicker">ELECTRICAL WIRING BOOKLET</div>
            <h1>{b.project}</h1>
            <div className="bk-sub">{"Level: " + b.level + " · Finalized " + b.date}</div>
            <div className={"bk-stamp" + (" bk-stamp-err" if b.summary.startswith("Errors") else "")}>{b.summary}</div>
            <div className="bk-tiles">{for t in b.totals {<div key={t.key}><span>{t.value}</span><small>{t.key.upper()}</small></div>}}</div>
            <h2>Design basis</h2>
            <table className="bk-table bk-kv"><tbody>
                <tr><td>Standard</td><td>{b.standard}</td></tr>
                <tr><td>Rule profile</td><td>{b.profile_id}</td></tr>
                {for kv in b.inputs {<tr key={kv.key}><td>{kv.key}</td><td>{kv.value}</td></tr>}}
            </tbody></table>
            <p className="bk-note">{b.profile_status}</p>
            <p className="bk-note">Every value carries a trust tag (verified_current, verified_2008_guide, secondary, unverified, design choice). This booklet is a design aid: a qualified electrician must review it, measure cable routes on site and test the installation before use.</p>
        </section>

        <section className="bk-page">
            <h2>1 · Wiring layout</h2>
            <WiringSchematic b={b} />
            <div className="bk-legend">
                <span><i style={{"background": "#2563eb"}} />Lighting circuit</span>
                <span><i style={{"background": "#16a34a"}} />Socket circuit</span>
                <span><i style={{"background": "#dc2626"}} />Dedicated circuit</span>
                <span>⊗ light · ● switch · ▭ socket · blue ▭ appliance outlet · ◩ consumer unit</span>
            </div>
            <p className="bk-note">Routes are schematic right-angle runs from the consumer unit; lengths are estimates (plan route + drops). Measure on site.</p>
        </section>

        <section className="bk-page">
            <h2>2 · Single line diagram</h2>
            <SingleLineDiagram b={b} />
        </section>

        <section className="bk-page">
            <h2>3 · Circuit schedule</h2>
            <table className="bk-table">
                <thead><tr><th>No</th><th>Circuit</th><th>RCD</th><th>MCB</th><th>Cable</th><th>Length</th><th>Ib</th><th>Iz</th><th>VD</th><th>Status</th></tr></thead>
                <tbody>{for c in b.circuits {
                    <tr key={c.id}><td><b style={{"color": KIND_COLOR[c.kind]}}>{c.id}</b></td><td>{c.name}<br /><small>{kind_name(c.kind)}</small></td><td>{c.rcd}</td><td>{c.breaker}</td><td>{f"{c.cable:g}/{c.cpc:g} mm²"}</td><td>{f"{c.length_m:.0f} m"}</td><td>{f"{c.ib:.1f} A"}</td><td>{f"{c.iz:.1f} A"}</td><td>{f"{c.vd_pct:.2f}% / {c.vd_limit:g}%"}</td><td className={"bk-st-" + c.status.lower()}>{c.status}</td></tr>
                }}</tbody>
            </table>
            <h2>4 · Lighting schedule and illumination levels</h2>
            <table className="bk-table">
                <thead><tr><th>Room</th><th>Area</th><th>Target</th><th>Lamp</th><th>Qty</th><th>Lumens</th><th>Achieved</th><th>W/m²</th><th>Switches</th></tr></thead>
                <tbody>{for r in b.rooms {
                    <tr key={r.name}><td>{r.name}</td><td>{f"{r.area_m2:.1f} m²"}</td><td>{(str(r.lux) + " lx") if r.lux > 0 else "not in profile"}</td><td>{r.lamp}</td><td>{str(r.lights)}</td><td>{f"{r.lumens:.0f} / {r.lumens_needed:.0f} lm"}</td><td>{f"{r.achieved_lux:.0f} lx"}</td><td>{f"{r.w_per_m2:.1f}"}</td><td>{str(r.switches)}</td></tr>
                }}</tbody>
            </table>
            <p className="bk-note">Lumen method from the rule profile: lumens needed = target lux × area / (UF × MF). Target lux values are tagged unverified in the profile; W/m² is compared with the 7.5 W/m² SLSEA benchmark.</p>
        </section>

        <section className="bk-page">
            <h2>5 · Bill of materials</h2>
            {for g in bom_groups {
                <div key={g.name}>
                    {len(g.lines) > 0 and <h3>{g.name}</h3>}
                    {len(g.lines) > 0 and <table className="bk-table">
                        <thead><tr><th>Item</th><th>Specification</th><th>Qty</th><th>Note</th></tr></thead>
                        <tbody>{for (i, l) in enumerate(g.lines) {<tr key={str(i)}><td>{l.item}</td><td>{l.spec}</td><td className="bk-qty">{qty(l.qty, l.unit)}</td><td>{l.note}{l.trust != "" and <small>{" · trust: " + l.trust}</small>}</td></tr>}}</tbody>
                    </table>}
                </div>
            }}
            <h2>6 · Points per room</h2>
            <table className="bk-table">
                <thead><tr><th>Room</th><th>Lights</th><th>Switches</th><th>Sockets</th><th>Appliance outlets</th></tr></thead>
                <tbody>{for r in b.rooms {
                    <tr key={r.name}><td>{r.name}</td><td>{str(r.lights)}</td><td>{str(r.switches)}</td><td>{str(r.sockets)}</td><td>{", ".join(r.appliances) if len(r.appliances) > 0 else "—"}</td></tr>
                }}</tbody>
            </table>
        </section>

        <section className="bk-page">
            <h2>7 · Checks and open issues</h2>
            {len(b.issues) == 0 and <p>No warnings or errors.</p>}
            {for (i, k) in enumerate(b.issues) {
                <div key={str(i)} className="bk-issue"><span className={"bk-lvl bk-lvl-" + k.level.lower()}>{k.level}</span><div><div>{k.text}</div><small>{"Rule: " + k.rule + " · Trust: " + k.trust}</small></div></div>
            }}
            <h3>Whole installation</h3>
            {for (i, k) in enumerate(b.checks) {
                <div key={str(i)} className="bk-issue"><span className={"bk-lvl bk-lvl-" + k.level.lower()}>{k.level}</span><div><div>{k.text}</div><small>{"Rule: " + k.rule + " · Trust: " + k.trust}</small></div></div>
            }}
            <p className="bk-note">{b.summary}</p>
        </section>

        <style>{".bk{position:fixed;inset:0;z-index:100;overflow:auto;background:#6b6b66;font-family:'JetBrains Mono',ui-monospace,monospace;color:#111}.bk-toolbar{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:10px;padding:10px 16px;background:#111;color:#fff}.bk-brand{flex:1;font-weight:700;letter-spacing:.06em}.bk-btn{border:1px solid #fff;background:transparent;color:#fff;padding:6px 12px;font-family:inherit;font-size:12px;cursor:pointer}.bk-btn-main{background:#FFD600;color:#111;border-color:#FFD600;font-weight:700}.bk-page{width:210mm;min-height:297mm;margin:16px auto;background:#fff;padding:14mm 13mm;box-shadow:0 2px 12px rgba(0,0,0,.35);box-sizing:border-box;font-size:10px;line-height:1.45}.bk-page h1{font-size:26px;margin:6px 0 2px}.bk-page h2{font-size:14px;margin:0 0 10px;padding-bottom:4px;border-bottom:2px solid #111}.bk-page h3{font-size:11px;margin:12px 0 4px;letter-spacing:.06em}.bk-logo{display:flex;align-items:center;gap:8px;font-weight:900;font-size:16px;letter-spacing:.1em}.bk-logo span{display:flex;width:30px;height:30px;align-items:center;justify-content:center;background:#FFD600}.bk-kicker{margin-top:36px;font-size:10px;font-weight:700;letter-spacing:.2em;color:#777}.bk-sub{color:#555}.bk-stamp{display:inline-block;margin:16px 0;border:2px solid #111;padding:6px 10px;font-weight:700;background:#fffbe6}.bk-stamp-err{background:#fee2e2;border-color:#e00;color:#991b1b}.bk-tiles{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid #111;margin:6px 0 18px}.bk-tiles>div{display:flex;flex-direction:column;padding:8px;border-right:1px solid #ddd;border-bottom:1px solid #ddd}.bk-tiles span{font-size:16px;font-weight:700}.bk-tiles small{font-size:8px;letter-spacing:.12em;color:#777}.bk-table{width:100%;border-collapse:collapse;margin-bottom:10px}.bk-table th{text-align:left;font-size:8px;letter-spacing:.1em;color:#555;border-bottom:1.5px solid #111;padding:4px 3px}.bk-table td{border-bottom:1px solid #e3e3df;padding:4px 3px;vertical-align:top}.bk-table small{color:#888}.bk-kv td:first-child{width:38%;color:#555}.bk-qty{font-weight:700;white-space:nowrap}.bk-st-pass{color:#15803d;font-weight:700}.bk-st-warning{color:#b45309;font-weight:700}.bk-st-error{color:#e00;font-weight:700}.bk-note{color:#666;font-size:9px}.bk-plan,.bk-sld{width:100%;height:auto;border:1px solid #111;display:block}.bk-legend{display:flex;flex-wrap:wrap;gap:12px;margin:8px 0;font-size:9px}.bk-legend i{display:inline-block;width:14px;height:4px;margin-right:5px;vertical-align:middle}.bk-issue{display:flex;gap:8px;padding:5px 0;border-bottom:1px solid #eee}.bk-issue small{color:#888}.bk-lvl{flex:none;font-size:8px;font-weight:700;padding:1px 5px;border:1px solid #111;height:fit-content}.bk-lvl-pass{background:#111;color:#FFD600}.bk-lvl-info{background:#fff}.bk-lvl-warning{background:#FFD600}.bk-lvl-error{background:#e00;color:#fff;border-color:#e00}@media print{@page{size:A4;margin:0}.bk{position:static;overflow:visible;background:#fff}.bk-toolbar{display:none}.bk-page{margin:0;box-shadow:none;page-break-after:always;break-after:page}}"}</style>
    </div>;
}
