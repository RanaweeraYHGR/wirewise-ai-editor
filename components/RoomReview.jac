import from ..services.floorPlanService { SuggestionInfo }

# Room types the user can pick (value, label) - values match services/roomAgent RoomType
glob ROOM_TYPES: list[list[str]] = [
    ["living", "Living room"], ["bedroom", "Bedroom"], ["kitchen", "Kitchen"], ["bathroom", "Bathroom"],
    ["wc", "WC"], ["dining", "Dining room"], ["hall", "Hall / landing"], ["utility", "Utility"],
    ["office", "Office"], ["storage", "Storage"], ["garage", "Garage"], ["other", "Other room"]
];

def:pub type_label(value: str) -> str {
    for t in ROOM_TYPES {
        if t[0] == value { return t[1]; }
    }
    if value == "not_a_room" { return "Not a room"; }
    return "Room";
}

def size_text(s: SuggestionInfo) -> str {
    if not s.sized { return "Size: set scale first"; }
    return f"{s.width / 100.0:.2f} × {s.height / 100.0:.2f} m · {s.area_m2:.1f} m²";
}

"""Step 1 of Suggest wiring: confirm, correct or answer each room the AI found."""
def:pub RoomReview(
    suggestions: list[SuggestionInfo],
    scanning: bool,
    aiOk: bool,
    message: str,
    activeId: str,
    onReview: Callable[[str, str, str, str], None],
    onSelect: Callable[[str], None],
    onConfirmAll: Callable[[], None],
    onApply: Callable[[], None],
    onRescan: Callable[[], None]
) -> JsxElement {
    has show_ignored: bool = False;

    asks = [s for s in suggestions if s.status == "ask"];
    pending = [s for s in suggestions if s.status == "pending"];
    confirmed = [s for s in suggestions if s.status == "confirmed"];
    ignored = [s for s in suggestions if s.status == "rejected"];
    sized = len(suggestions) == 0 or suggestions[0].sized;

    def card_class(s: SuggestionInfo, extra: str) -> str {
        return "rr-card " + extra + (" rr-active" if s.id == activeId else "");
    }

    return <div className="rr">
        <div className="rr-head">
            <div><div className="rr-kicker">STEP 1 OF 2 · ROOMS</div><div className="rr-title">Check the rooms</div></div>
            <button className="rr-ghost" disabled={scanning} onClick={lambda { onRescan(); }}>Rescan</button>
        </div>
        {scanning and <div className="rr-note rr-scanning"><span className="rr-dot" />Scanning the plan: walls, rooms, labels…</div>}
        {not scanning and not aiOk and message != "" and <div className="rr-warn">{message}</div>}
        {not scanning and aiOk and message != "" and <div className="rr-note">{message}</div>}
        {not scanning and not sized and <div className="rr-note">Plan is not to scale yet. Use <strong>Set scale</strong> to get room sizes.</div>}
        {len(suggestions) > 0 and <div className="rr-counts">
            <span>{str(len(suggestions) - len(ignored))} FOUND</span>
            <span className={"rr-count-ask" if len(asks) > 0 else ""}>{str(len(asks))} TO ANSWER</span>
            <span>{str(len(confirmed))} CONFIRMED</span>
        </div>}

        {len(asks) > 0 and <div className="rr-section">NEEDS YOUR ANSWER</div>}
        {for s in asks {
            <div key={s.id} className={card_class(s, "rr-ask")} onClick={lambda { onSelect(s.id); }}>
                <div className="rr-row"><span className="rr-num rr-num-ask">{str(s.region)}</span><span className="rr-q">What is this room?</span></div>
                <div className="rr-meta">{size_text(s)}{s.written_label != "" and <span>{" · plan says “" + s.written_label + "”"}</span>}</div>
                <div className="rr-chips">
                    {for t in s.alternatives {
                        <button key={t} className="rr-chip" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onReview(s.id, "confirm", t, ""); }}>{type_label(t)}?</button>
                    }}
                    <select className="rr-select" value="" aria-label="Other room type" onClick={lambda (e: MouseEvent) { e.stopPropagation(); }} onChange={lambda (e: ChangeEvent) { if e.target.value != "" { onReview(s.id, "confirm", e.target.value, ""); } }}>
                        <option value="">Other…</option>
                        {for t in ROOM_TYPES { <option key={t[0]} value={t[0]}>{t[1]}</option> }}
                    </select>
                    <button className="rr-chip rr-chip-muted" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onReview(s.id, "reject", "", ""); }}>Not a room</button>
                </div>
            </div>
        }}

        {len(pending) > 0 and <div className="rr-section">AI SUGGESTS · TICK OR CHANGE</div>}
        {for s in pending {
            <div key={s.id} className={card_class(s, "")} onClick={lambda { onSelect(s.id); }}>
                <div className="rr-row">
                    <span className="rr-num">{str(s.region)}</span>
                    <input key={s.id + s.name} className="rr-name" defaultValue={s.name} aria-label="Room name" onClick={lambda (e: MouseEvent) { e.stopPropagation(); }} onBlur={lambda (e: FocusEvent) { field: any = e.target; if field.value != s.name { onReview(s.id, "", "", field.value as str); } }} />
                    <span className="rr-conf" title="AI confidence">{str(round(s.confidence * 100.0))}%</span>
                </div>
                <div className="rr-row rr-row-gap">
                    <select className="rr-select rr-grow" value={s.room_type} aria-label="Room type" onClick={lambda (e: MouseEvent) { e.stopPropagation(); }} onChange={lambda (e: ChangeEvent) { onReview(s.id, "", e.target.value, ""); }}>
                        {for t in ROOM_TYPES { <option key={t[0]} value={t[0]}>{t[1]}</option> }}
                    </select>
                    <button className="rr-tick" title="Correct" aria-label="Confirm room" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onReview(s.id, "confirm", "", ""); }}>✓</button>
                    <button className="rr-cross" title="Not a room" aria-label="Reject room" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onReview(s.id, "reject", "", ""); }}>✕</button>
                </div>
                <div className="rr-meta">{size_text(s)}{s.written_label != "" and <span>{" · plan says “" + s.written_label + "”"}</span>}</div>
            </div>
        }}

        {len(confirmed) > 0 and <div className="rr-section">CONFIRMED</div>}
        {for s in confirmed {
            <div key={s.id} className={card_class(s, "rr-done")} onClick={lambda { onSelect(s.id); }}>
                <span className="rr-num rr-num-done">✓</span>
                <span className="rr-done-name">{s.name if s.name != "" else type_label(s.room_type)}</span>
                <span className="rr-done-type">{type_label(s.room_type)}</span>
                <button className="rr-link" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onReview(s.id, "reset", "", ""); }}>Edit</button>
            </div>
        }}

        {len(ignored) > 0 and <button className="rr-link rr-ignored" onClick={lambda { show_ignored = not show_ignored; }}>{("Hide" if show_ignored else "Show") + " " + str(len(ignored)) + " ignored area" + ("" if len(ignored) == 1 else "s")}</button>}
        {show_ignored and <div>
            {for s in ignored {
                <div key={s.id} className="rr-card rr-done rr-muted">
                    <span className="rr-num">{str(s.region)}</span>
                    <span className="rr-done-name">Not a room</span>
                    <button className="rr-link" onClick={lambda { onReview(s.id, "reset", "", ""); }}>Restore</button>
                </div>
            }}
        </div>}

        {len(suggestions) > 0 and <div className="rr-actions">
            {len(pending) > 0 and <button className="rr-outline" onClick={lambda { onConfirmAll(); }}>Confirm all {str(len(pending))} suggested</button>}
            <button className="rr-primary" disabled={len(confirmed) == 0} onClick={lambda { onApply(); }}>{"Add " + str(len(confirmed)) + " room" + ("" if len(confirmed) == 1 else "s") + " to plan"}</button>
            {len(asks) > 0 and <div className="rr-hint">Answer the highlighted rooms to add them too.</div>}
        </div>}

        <div className="rr-next"><span className="rr-kicker">STEP 2 OF 2 · WIRING</span><span>After you add the rooms, WireWise calculates lights (lux levels), a switch by each door and socket outlets per room.</span></div>
    </div>;
}
