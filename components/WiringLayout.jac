import from ..services.floorPlanService { LayoutResult, RoomLayout, LayoutCheck }

def level_class(c: LayoutCheck) -> str {
    return "wl-lvl wl-lvl-" + c.level.lower();
}

def needs_review(r: RoomLayout) -> bool {
    return any([c.level == "WARNING" or c.level == "ERROR" for c in r.checks]);
}

"""Step 2 of Suggest wiring: lights (lumen method), one switch by the door and sockets for every room."""
def:pub WiringLayout(
    layout: LayoutResult | None,
    loading: bool,
    onPreview: Callable[[], None],
    onApply: Callable[[], None],
    onClear: Callable[[], None],
    onRescan: Callable[[], None],
    onNext: Callable[[], None]
) -> JsxElement {
    has open_room: str = "";

    def toggle(room_id: str) {
        open_room = "" if open_room == room_id else room_id;
    }

    room_layouts: list[RoomLayout] = layout.rooms if layout is not None else [];

    return <div className="wl">
        <div className="rr-head">
            <div><div className="rr-kicker">STEP 2 OF 2 · WIRING</div><div className="rr-title">Lights and sockets</div></div>
            <button className="rr-ghost" disabled={loading} onClick={lambda { onPreview(); }}>Recalculate</button>
        </div>
        {loading and <div className="rr-note rr-scanning"><span className="rr-dot" />Calculating lux levels and positions…</div>}
        {not loading and layout is None and <div className="rr-actions"><div className="rr-note">Calculate lights, switches and socket outlets for every room from the BS 7671 rule profile.</div><button className="rr-primary" onClick={lambda { onPreview(); }}>Calculate lights and sockets</button></div>}
        {not loading and layout is not None and not layout.ok and <div className="rr-warn">{layout.message}</div>}
        {not loading and layout is not None and layout.ok and <div className="wl-body">
            {not layout.sized and <div className="rr-warn">Plan is not to scale, so room areas are assumed. Use <strong>Set scale</strong> first, then Recalculate.</div>}
            <div className="wl-totals">
                <div><span className="wl-big">{str(layout.total_lights)}</span><span>LIGHTS</span></div>
                <div><span className="wl-big">{str(layout.total_sockets)}</span><span>SOCKETS</span></div>
                <div><span className="wl-big">{str(layout.total_switches)}</span><span>SWITCHES</span></div>
                <div><span className="wl-big">{str(round(layout.lighting_watts))}</span><span>W LIGHT</span></div>
            </div>
            {for r in room_layouts {
                <div key={r.room_id} className={"wl-room" + (" wl-room-warn" if needs_review(r) else "")}>
                    <button className="wl-room-head" onClick={lambda { toggle(r.room_id); }}>
                        <span className="wl-room-name">{r.name}</span>
                        <span className="wl-room-area">{f"{r.area_m2:.1f} m²"}</span>
                        <span className="wl-caret">{"−" if open_room == r.room_id else "+"}</span>
                    </button>
                    <div className="wl-chips">
                        <span className="wl-chip"><svg width="14" height="14" viewBox="-8 -8 16 16" aria-hidden="true"><circle r="6.5" fill="none" stroke="currentColor" strokeWidth="1.6" /><path d="M -4.6 -4.6 L 4.6 4.6 M -4.6 4.6 L 4.6 -4.6" stroke="currentColor" strokeWidth="1.6" /></svg>{str(r.lights) + " × " + str(r.lamp_watts) + " W"}</span>
                        <span className="wl-chip"><svg width="16" height="12" viewBox="-9 -6 18 12" aria-hidden="true"><rect x="-8" y="-5" width="16" height="10" fill="#FFD600" stroke="currentColor" strokeWidth="1.4" /><path d="M -3 -2 L -3 2 M 3 -2 L 3 2" stroke="currentColor" strokeWidth="1.4" /></svg>{str(r.sockets) + " socket" + ("" if r.sockets == 1 else "s")}</span>
                        <span className="wl-chip"><svg width="12" height="12" viewBox="-6 -6 12 12" aria-hidden="true"><circle r="3" fill="currentColor" /><path d="M 0 0 L 5 -5" stroke="currentColor" strokeWidth="1.6" /></svg>1 switch</span>
                    </div>
                    {r.lux > 0 and <div className="rr-meta">{f"{r.lux} lx target → {r.lights * r.lamp_lumens} lm ≥ {r.lumens_needed:.0f} lm needed"}</div>}
                    {open_room == r.room_id and <div className="wl-checks">
                        {for (ci, c) in enumerate(r.checks) {
                            <div key={str(ci)} className="wl-check">
                                <span className={level_class(c)}>{c.level}</span>
                                <div><div>{c.text}</div><div className="wl-rule">{c.rule + " · Trust: " + c.trust}</div></div>
                            </div>
                        }}
                    </div>}
                </div>
            }}
            <div className="rr-actions">
                {not layout.placed and <button className="rr-primary" onClick={lambda { onApply(); }}>{"Place " + str(layout.total_lights) + " lights, " + str(layout.total_sockets) + " sockets"}</button>}
                {layout.placed and <button className="rr-primary" onClick={lambda { onNext(); }}>Next: AC, pump, hot water →</button>}
                {layout.placed and <button className="rr-outline" onClick={lambda { onApply(); }}>Re-place layout</button>}
                {layout.placed and <button className="rr-outline" onClick={lambda { onClear(); }}>Remove placed layout</button>}
                <div className="rr-hint">Passed under selected rule profile — review required. Hand-placed devices are never removed.</div>
            </div>
        </div>}
        <button className="rr-link wl-rescan" onClick={lambda { onRescan(); }}>Rescan plan for more rooms</button>
        <style>{".wl{display:flex;flex-direction:column;gap:10px;font-size:11px}.wl-body{display:flex;flex-direction:column;gap:10px}.wl-totals{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid #111}.wl-totals>div{display:flex;flex-direction:column;align-items:center;padding:8px 2px;border-right:1px solid #e5e5e2;font-size:8px;letter-spacing:.12em;color:#777;font-weight:700}.wl-totals>div:last-child{border-right:none}.wl-big{font-size:18px;color:#111;letter-spacing:0}.wl-room{border:1px solid #d4d4cf;background:#fff;padding:9px 10px;display:flex;flex-direction:column;gap:6px}.wl-room-warn{border-left:3px solid #e2c300}.wl-room-head{display:flex;align-items:center;gap:8px;background:none;border:none;padding:0;cursor:pointer;font-family:inherit;color:inherit;text-align:left}.wl-room-name{flex:1;font-weight:700;font-size:12px}.wl-room-area{font-size:10px;color:#777}.wl-caret{width:16px;text-align:center;font-weight:700}.wl-chips{display:flex;flex-wrap:wrap;gap:6px}.wl-chip{display:inline-flex;align-items:center;gap:5px;border:1px solid #e5e5e2;padding:3px 6px;font-size:10px;font-weight:700}.wl-checks{display:flex;flex-direction:column;gap:6px;border-top:1px dashed #e5e5e2;padding-top:6px}.wl-check{display:flex;gap:6px;align-items:flex-start;font-size:10px;line-height:1.45}.wl-lvl{flex:none;font-size:8px;font-weight:700;letter-spacing:.08em;padding:1px 4px;border:1px solid #111}.wl-lvl-pass{background:#111;color:#FFD600}.wl-lvl-info{background:#fff;color:#111}.wl-lvl-warning{background:#FFD600;color:#111}.wl-lvl-error{background:#e00;color:#fff;border-color:#e00}.wl-rule{color:#888;font-size:9px}.wl-rescan{align-self:flex-start}.is-dark .wl-room,.is-dark .wl-totals{background:#2a2a2a;border-color:#555}.is-dark .wl-big{color:#eee}"}</style>
    </div>;
}
