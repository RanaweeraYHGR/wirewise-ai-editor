import from ..services.floorPlanService {
    FloorPlan, PlanElement, get_floor_plan, add_plan_element,
    start_blank_plan, load_sample_flat, add_room,
    BackgroundInfo, get_background, import_background, set_background_scale, clear_background,
    SuggestionInfo, get_suggestions, scan_plan, review_suggestion, confirm_all_suggestions, apply_suggestions,
    LayoutResult, LayoutPoint, preview_layout, apply_layout, clear_layout,
    LoadsResult, get_loads, add_ac, add_load, remove_load
}
import from .RoomReview { RoomReview, type_label }
import from .WiringLayout { WiringLayout }
import from .DeviceSymbol { DeviceSymbol }
import from .LoadsWizard { LoadsWizard }
import "../styles/global.css";

# Formats the Import button accepts (DWG is accepted only to show a "save as DXF" hint)
glob ACCEPT_FILES: str = ".png,.jpg,.jpeg,.gif,.webp,.bmp,.tif,.tiff,.svg,.pdf,.dxf,.dwg";
glob MAX_FILE_MB: int = 20;
glob EMPTY_PLAN: dict[str, any] = {"name": "", "level": "Ground", "rooms": [], "devices": []};

def:pub FloorPlanEditor() -> JsxElement {
    has plan: any = None;
    has tool: str = "Select";
    has panel: str = "Properties";
    has zoom: int = 80;
    has dark: bool = False;
    has selected: PlanElement | None = None;
    has project_name: str = "WireWise Residence";
    # Welcome dialog + imported background plan
    has show_welcome: bool = False;
    has bg: any = None;                 # BackgroundInfo from the server (imported plan)
    has import_msg: str = "";
    has importing: bool = False;
    has scale_pts: list[float] = [];    # Set scale: first clicked point [x, y]
    # Room drawing (drag on canvas)
    has drawing: bool = False;
    has start_x: float = 0.0;
    has start_y: float = 0.0;
    has cur_x: float = 0.0;
    has cur_y: float = 0.0;
    # AI room check (Suggest wiring, step 1)
    has suggestions: list[SuggestionInfo] = [];
    has scanning: bool = False;
    has scan_ai: bool = True;
    has scan_msg: str = "";
    has active_sug: str = "";
    # Lights, switches and sockets (Suggest wiring, step 2)
    has layout: LayoutResult | None = None;
    has layout_loading: bool = False;
    # Appliances (Suggest wiring, step 3)
    has ai_view: str = "auto";          # auto | layout | loads
    has loads_data: LoadsResult | None = None;
    has loads_busy: bool = False;
    has hl_tag: str = "";               # plug base highlighted from the loads list

    can with entry { load_plan(); }

    def set_plan(result: any) -> None {
        if result and result.rooms {
            plan = result;
        } else {
            plan = EMPTY_PLAN;
        }
    }

    def set_bg(info: any) -> None {
        if info and info.image {
            bg = info;
        } else {
            bg = None;
        }
    }

    async def load_plan() -> None {
        result = await get_floor_plan();
        set_plan(result);
        set_bg(await get_background());
        suggestions = (await get_suggestions()).suggestions;
        if plan != None and plan.rooms {
            layout = await preview_layout();   # so step 2 knows whether a layout is already placed
        }
        # Always show the welcome dialog when the page loads
        show_welcome = True;
    }

    # ---- Welcome dialog actions ----
    async def draw_room_start() -> None {
        set_plan(await start_blank_plan());
        await clear_background();
        bg = None;
        import_msg = "";
        tool = "Room";
        show_welcome = False;
    }

    async def view_sample() -> None {
        set_plan(await load_sample_flat());
        await clear_background();
        bg = None;
        import_msg = "";
        tool = "Select";
        show_welcome = False;
    }

    # Read a picked file as a data URL (base64) so it can be sent to the server
    def read_file(file: any) -> any {
        return new(Promise, lambda(resolve: any, reject: any) {  # jac:ignore[E1053]
            reader: any = new(FileReader);  # jac:ignore[E1053]
            reader.onload = lambda { resolve.call(None, reader.result); };
            reader.onerror = lambda { reject.call(None, reader.error); };
            reader.readAsDataURL(file);
        });
    }

    async def import_plan(e: ChangeEvent) -> None {
        el: any = e.target;
        file: any = None;
        if el.files and el.files.length > 0 { file = el.files[0]; }
        el.value = "";   # lets you pick the same file again
        if not file { return; }
        if file.size > MAX_FILE_MB * 1024 * 1024 {
            import_msg = "File is larger than " + str(MAX_FILE_MB) + " MB.";
            return;
        }
        importing = True;
        name: str = file.name as str;
        import_msg = "Converting " + name + " ...";
        data_url: str = (await read_file(file)) as str;
        res = await import_background(name, data_url);
        importing = False;
        if not res.ok {
            import_msg = res.message;
            return;
        }
        set_plan(await start_blank_plan());
        set_bg(res);
        import_msg = res.message;
        scale_pts = [];
        tool = "Room" if res.scaled else "Scale";
        show_welcome = False;
    }

    async def remove_background() -> None {
        await clear_background();
        bg = None;
        import_msg = "";
        if tool == "Scale" { tool = "Select"; }
    }

    # Set scale: click two points on the imported plan, then type the real distance
    async def scale_click(e: MouseEvent) -> None {
        if bg == None {
            import_msg = "Import a plan first.";
            return;
        }
        p = to_canvas_raw(e);
        if len(scale_pts) < 2 {
            scale_pts = [p[0], p[1]];
            return;
        }
        dx = p[0] - scale_pts[0];
        dy = p[1] - scale_pts[1];
        dist: float = (dx * dx + dy * dy) ** 0.5;
        if dist < 5.0 { return; }
        answer: any = window.prompt(  # jac:ignore[E1032]
            "Real distance between the two points (meters):", "5");
        scale_pts = [];
        if not answer { return; }
        meters: float = float(String(answer).replace(",", "."));
        if not meters or meters <= 0.0 {
            import_msg = "Enter the distance as a number in meters, e.g. 4.5";
            return;
        }
        res = await set_background_scale(meters * 100.0 / dist);
        if res.ok {
            set_bg(res);
            import_msg = "Scale set - the plan is now real size. Draw rooms on top.";
            tool = "Room";
        }
    }

    # ---- Suggest wiring: AI room check ----
    async def suggest_wiring() -> None {
        if bg == None {
            import_msg = "Import a plan first.";
            return;
        }
        scanning = True;
        panel = "AI";
        active_sug = "";
        scan_msg = "";
        res = await scan_plan();
        scanning = False;
        scan_ai = res.ai;
        scan_msg = res.message;
        if res.ok {
            suggestions = res.suggestions;
            tool = "Select";
            if len(res.suggestions) == 0 {
                await show_layout();   # every room is already on the plan: go straight to step 2
            }
        } else {
            import_msg = res.message;
        }
    }

    async def review(sid: str, action: str, room_type: str, name: str) -> None {
        active_sug = sid;
        suggestions = (await review_suggestion(sid, action, room_type, name)).suggestions;
    }

    async def confirm_all() -> None {
        suggestions = (await confirm_all_suggestions()).suggestions;
    }

    async def apply_rooms() -> None {
        set_plan(await apply_suggestions());
        suggestions = (await get_suggestions()).suggestions;
        active_sug = "";
        scan_msg = "Rooms added to the plan.";
        if len(suggestions) == 0 {
            await show_layout();
        }
    }

    async def show_layout() -> None {
        panel = "AI";
        layout_loading = True;
        layout = await preview_layout();
        layout_loading = False;
    }

    async def place_layout() -> None {
        layout_loading = True;
        set_plan(await apply_layout());
        layout = await preview_layout();
        layout_loading = False;
    }

    async def remove_layout() -> None {
        layout_loading = True;
        set_plan(await clear_layout());
        layout = await preview_layout();
        layout_loading = False;
    }

    def set_loads(res: LoadsResult) {
        loads_data = res;
        if res.plan is not None { set_plan(res.plan); }
        if not res.ok { scan_msg = res.message; }
    }

    async def open_loads() -> None {
        panel = "AI";
        ai_view = "loads";
        loads_busy = True;
        set_loads(await get_loads());
        loads_busy = False;
    }

    async def add_ac_room(room_id: str) -> None {
        loads_busy = True;
        set_loads(await add_ac(room_id));
        loads_busy = False;
    }

    async def add_load_item(item_id: str, room_id: str, watts: float, name: str) -> None {
        loads_busy = True;
        set_loads(await add_load(item_id, room_id, watts, name));
        loads_busy = False;
    }

    async def remove_load_tag(tag: str) -> None {
        loads_busy = True;
        set_loads(await remove_load(tag));
        loads_busy = False;
        hl_tag = "";
    }

    def set_hl(tag: str) { hl_tag = tag; }

    def select_sug(sid: str) {
        active_sug = sid;
        panel = "AI";
    }

    # Canvas tag: "? ROOM 4" (needs an answer), "2 BEDROOM" (suggested), "✓ KITCHEN" (confirmed)
    def sug_tag(s: SuggestionInfo) -> str {
        if s.status == "ask" { return "? ROOM " + str(s.region); }
        name = s.name if s.name != "" else type_label(s.room_type);
        prefix = "✓ " if s.status == "confirmed" else str(s.region) + " ";
        return (prefix + name).upper();
    }

    def poly_points(p: list[float]) -> str {
        out = "";
        i = 0;
        while i + 1 < len(p) {
            out = out + str(p[i]) + "," + str(p[i + 1]) + " ";
            i = i + 2;
        }
        return out;
    }

    # ---- Canvas helpers ----
    def to_canvas_raw(e: MouseEvent) -> list[float] {
        svg: any = e.currentTarget;
        pt: any = svg.createSVGPoint();
        pt.x = e.clientX;
        pt.y = e.clientY;
        q: any = pt.matrixTransform(svg.getScreenCTM().inverse());
        return [q.x as float, q.y as float];
    }

    def to_canvas(e: MouseEvent) -> list[float] {
        p = to_canvas_raw(e);
        # snap to 10 cm grid
        return [float(round(p[0] / 10.0)) * 10.0, float(round(p[1] / 10.0)) * 10.0];
    }

    def on_down(e: MouseEvent) -> None {
        if tool != "Room" { return; }
        p = to_canvas(e);
        drawing = True;
        start_x = p[0]; start_y = p[1];
        cur_x = p[0]; cur_y = p[1];
    }

    def on_move(e: MouseEvent) -> None {
        if tool == "Scale" and len(scale_pts) == 2 {
            q = to_canvas_raw(e);
            cur_x = q[0]; cur_y = q[1];
            return;
        }
        if not drawing { return; }
        p = to_canvas(e);
        cur_x = p[0]; cur_y = p[1];
    }

    async def on_up(e: MouseEvent) -> None {
        if not drawing { return; }
        drawing = False;
        x: float = min(start_x, cur_x);
        y: float = min(start_y, cur_y);
        w: float = abs(cur_x - start_x);
        h: float = abs(cur_y - start_y);
        if w >= 50.0 and h >= 50.0 {
            set_plan(await add_room(x, y, w, h));
        }
    }

    async def place_at(e: MouseEvent) -> None {
        if plan == None { return; }
        if tool == "Scale" {
            await scale_click(e);
            return;
        }
        if tool == "Select" or tool == "Wall" or tool == "Switch link" or tool == "Room" { return; }
        p = to_canvas(e);
        result = await add_plan_element(tool, p[0], p[1]);
        if result and result.rooms { plan = result; }
    }

    def zoom_in() { zoom = zoom + 10; }
    def zoom_out() { if zoom > 30 { zoom = zoom - 10; } }
    def choose_tool(name: str) { tool = name; }
    def choose_panel(name: str) { panel = name; }
    def toggle_theme() { dark = not dark; }
    def pick_room(room: PlanElement) { selected = room; }

    tools_plan: list[list[str]] = [["Select", "V"], ["Room", "R"], ["Wall", "W"], ["Switch link", "J"], ["Consumer unit", "G"], ["Riser / opening", "Y"]];
    tools_electrical: list[list[str]] = [["Socket 16A", "P"], ["Dedicated socket", "S"], ["Cooker outlet 32A", "K"], ["Lighting point", "L"], ["One-way switch", "I"], ["Two-way switch", "T"], ["Roller shutter", "O"], ["Heater", "H"], ["Water heater", "B"], ["Ventilation", "M"], ["RJ45 socket", "N"], ["EV charger", "X"]];

    rooms: list[PlanElement] = [];
    devices: list[PlanElement] = [];
    if plan != None and plan.rooms { rooms = plan.rooms as list[PlanElement]; }
    if plan != None and plan.devices { devices = plan.devices as list[PlanElement]; }
    rooms_count = len(rooms);
    draft_x: float = min(start_x, cur_x);
    draft_y: float = min(start_y, cur_y);
    draft_w: float = abs(cur_x - start_x);
    draft_h: float = abs(cur_y - start_y);
    hint = "Click canvas to place";
    if tool == "Room" { hint = "Drag to draw a room"; }
    if tool == "Scale" {
        hint = "Click the second point" if len(scale_pts) == 2 else "Click two points a known distance apart";
    }
    # Canvas size in cm grows to fit the imported plan (1 unit = 1 cm)
    vw: float = 900.0;
    vh: float = 620.0;
    if bg != None {
        bx: float = bg.x as float;
        b_y: float = bg.y as float;
        bw: float = bg.width as float;
        bh: float = bg.height as float;
        vw = max(900.0, bx + bw + 50.0);
        vh = max(620.0, b_y + bh + 50.0);
    }
    view_box = "0 0 " + str(vw) + " " + str(vh);
    visible_sugs = [s for s in suggestions if s.status != "rejected"];
    ghost_points: list[LayoutPoint] = [];
    if layout is not None and layout.ok and not layout.placed and len(suggestions) == 0 {
        for rl in layout.rooms {
            ghost_points = ghost_points + rl.points;
        }
    }
    ask_count = len([s for s in suggestions if s.status == "ask"]);
    done_count = len([s for s in suggestions if s.status == "confirmed"]);
    banner = "";
    if scanning {
        banner = "Scanning plan · finding rooms";
    } elif ask_count > 0 {
        banner = f"AI found {len(visible_sugs)} rooms · {ask_count} need your answer";
    } elif len(visible_sugs) > 0 and done_count < len(visible_sugs) {
        banner = f"AI found {len(visible_sugs)} rooms · tick or correct them";
    } elif len(visible_sugs) > 0 {
        banner = f"{done_count} rooms confirmed";
    } elif layout_loading {
        banner = "Calculating lights and sockets";
    } elif len(ghost_points) > 0 and layout is not None {
        banner = f"Preview · {layout.total_lights} lights · {layout.total_sockets} sockets · {layout.total_switches} switches";
    }
    bg_label = "";
    if bg != None {
        bg_label = "PLAN · " + (bg.source as str) + ("" if bg.scaled else " · NOT SCALED");
    }

    return <div className={"wirewise flex h-svh flex-col " + ("is-dark" if dark else "")}>
        <header className="flex min-h-14 flex-wrap items-center gap-3 border-b bg-background px-4 py-2"><div className="flex items-center gap-2"><div className="flex size-8 items-center justify-center bg-[#FFD600] text-black font-black">W</div><span className="font-bold">WIREWISE AI</span></div><span>/</span><input aria-label="Project name" className="w-40 bg-transparent text-sm outline-none sm:w-52" value={project_name} onChange={lambda (e: ChangeEvent) { project_name = e.target.value; }} /><span className="text-xs text-muted-foreground">● Saved</span><div className="ml-auto flex items-center gap-1"><button className="top-action">↶</button><button className="top-action">↷</button><button className="top-action hidden sm:block">Fit</button><button className="top-action hidden md:block" onClick={lambda { panel = "AI"; }}>Ask AI Ctrl+K</button><button className="top-action hidden md:block" onClick={lambda { show_welcome = True; }}>New plan</button><button className="top-action" onClick={toggle_theme}>◐</button><button className="export-action">Export PDF</button></div></header>
        <div className="flex min-h-0 flex-1">
            <aside className="tool-rail w-52 shrink-0 overflow-y-auto border-r bg-background px-2 py-3"><div className="tool-heading">PLAN</div>{for item in tools_plan {<button key={item[0]} className={"tool-button " + ("tool-active" if tool == item[0] else "")} onClick={lambda { choose_tool(item[0]); }}><span className="tool-glyph">{item[0][:1]}</span><span className="flex-1 text-left">{item[0]}</span><kbd>{item[1]}</kbd></button>}}<div className="tool-heading mt-5">ELECTRICAL</div>{for item in tools_electrical {<button key={item[0]} className={"tool-button " + ("tool-active" if tool == item[0] else "")} onClick={lambda { choose_tool(item[0]); }}><span className="tool-glyph">{item[0][:1]}</span><span className="flex-1 truncate text-left">{item[0]}</span><kbd>{item[1]}</kbd></button>}}</aside>
            <main className="flex min-w-0 flex-1 flex-col bg-[#f3f3f0]"><div className="flex h-11 shrink-0 items-center gap-2 border-b bg-background px-3"><button className="level-tab">Ground</button><button className="top-action">+ Level</button>{bg != None and <span className="flex shrink-0 items-center gap-1 whitespace-nowrap"><span className="ml-2 border px-2 py-0.5 text-[10px]">{bg_label}</span><button className={"top-action " + ("tool-active" if tool == "Scale" else "")} onClick={lambda { tool = "Scale"; scale_pts = []; }}>Set scale</button><button className="top-action" onClick={remove_background}>Remove plan</button><button className="wire-action" disabled={scanning} onClick={suggest_wiring}><span aria-hidden="true">ϟ</span>{"Scanning…" if scanning else "Suggest wiring"}</button></span>}<span className="ml-auto truncate text-xs text-muted-foreground">{import_msg if import_msg != "" else "10 cm grid"}</span></div>
                <div className="canvas-wrap relative flex min-h-0 flex-1 items-center justify-center overflow-hidden p-4 sm:p-8">
                    <div className="plan-canvas relative h-full max-h-[700px] w-full max-w-[980px] overflow-hidden border bg-white shadow-sm">
                        {plan != None and <svg className="absolute inset-0 h-full w-full" viewBox={view_box} preserveAspectRatio="xMidYMid meet" onClick={place_at} onMouseDown={on_down} onMouseMove={on_move} onMouseUp={on_up}>
                            <defs><pattern id="grid" width="10" height="10" patternUnits="userSpaceOnUse"><path d="M 10 0 L 0 0 0 10" fill="none" stroke="#e9e9e6" strokeWidth="0.7" /></pattern></defs>
                            <rect width={vw} height={vh} fill="url(#grid)" />
                            {bg != None and <image href={bg.image} x={bg.x} y={bg.y} width={bg.width} height={bg.height} preserveAspectRatio="none" />}
                            {for room in rooms {<g key={room.id} onClick={lambda (e: MouseEvent) { e.stopPropagation(); pick_room(room); }}><rect x={room.x} y={room.y} width={room.width} height={room.height} fill={"none" if bg != None else "#fff"} stroke="#171717" strokeWidth="4" /><text x={room.x + 12.0} y={room.y + 25.0} fontSize="12" fontFamily="monospace" fill="#777">{room.label.upper()}</text><text x={room.x + 12.0} y={room.y + room.height - 8.0} fontSize="10" fontFamily="monospace" fill="#aaa">{f"{room.width / 100.0:.2f} × {room.height / 100.0:.2f} m"}</text></g>}}
                            {for s in visible_sugs {<g key={"sug-" + s.id} className="sug" onClick={lambda (e: MouseEvent) { e.stopPropagation(); select_sug(s.id); }}><polygon points={poly_points(s.poly)} className={"sug-shape sug-" + s.status + (" sug-active" if s.id == active_sug else "")} /><g transform={"translate(" + str(s.x + 8.0) + " " + str(s.y + 8.0) + ")"}><rect className={"sug-tag sug-tag-" + s.status} width={len(sug_tag(s)) * 7.4 + 14.0} height="20" /><text x="7" y="14" fontSize="11" fontFamily="monospace" fontWeight="700" className={"sug-tag-text-" + s.status}>{sug_tag(s)}</text></g></g>}}
                            {for device in devices {<g key={device.id} transform={"translate(" + str(device.x) + " " + str(device.y) + ")"}><DeviceSymbol kind={device.kind} label={device.label} highlight={hl_tag != "" and device.label == hl_tag} /></g>}}
                            {for (i, gp) in enumerate(ghost_points) {<g key={"ghost-" + str(i)} transform={"translate(" + str(gp.x) + " " + str(gp.y) + ")"}><DeviceSymbol kind={gp.kind} label={gp.label} ghost={True} /></g>}}
                            {drawing and <g><rect x={draft_x} y={draft_y} width={draft_w} height={draft_h} fill="rgba(255,214,0,0.15)" stroke="#111" strokeWidth="2" strokeDasharray="6 4" /><text x={draft_x + 6.0} y={draft_y - 6.0} fontSize="11" fontFamily="monospace" fill="#111">{f"{draft_w / 100.0:.2f} × {draft_h / 100.0:.2f} m"}</text></g>}
                            {tool == "Scale" and len(scale_pts) == 2 and <g><line x1={scale_pts[0]} y1={scale_pts[1]} x2={cur_x} y2={cur_y} stroke="#e00" strokeWidth="3" strokeDasharray="8 5" /><circle cx={scale_pts[0]} cy={scale_pts[1]} r="6" fill="#e00" /></g>}
                        </svg>}
                        {plan == None and <div className="absolute inset-0 flex items-center justify-center"><div className="border bg-white p-6 text-center shadow-sm"><div className="text-lg font-semibold">Loading plan</div><p className="mt-2 text-sm text-muted-foreground">Connecting to the project graph.</p></div></div>}
                        {scanning and <div className="scan-overlay" aria-hidden="true"><div className="scan-line" /></div>}
                        {banner != "" and <div className="ai-banner" role="status"><span>{banner}</span>{(scanning or layout_loading) and <span className="rr-dot" />}{not scanning and not layout_loading and <button onClick={lambda { panel = "AI"; }}>Review</button>}</div>}
                        <div className="absolute bottom-3 left-3 border bg-white/95 px-3 py-2 text-xs"><span className="font-semibold">{tool}</span><span className="ml-2 text-muted-foreground">{hint}</span></div>
                    </div>
                    {show_welcome and <div className="welcome-backdrop">
                        <div className="welcome-card">
                            <div className="welcome-head flex items-start">
                                <div><div className="welcome-kicker">NEW PLAN</div><div className="welcome-title">Three steps to your consumer unit</div></div>
                                <button className="welcome-close" aria-label="Close" onClick={lambda { show_welcome = False; }}>×</button>
                            </div>
                            <div className="welcome-step"><span className="welcome-num">1</span><span>Draw the rooms</span><span className="welcome-keys"><kbd>R</kbd></span></div>
                            <div className="welcome-step"><span className="welcome-num">2</span><span>Place sockets and lighting points</span><span className="welcome-keys"><kbd>P</kbd><kbd>L</kbd><kbd>I</kbd></span></div>
                            <div className="welcome-step"><span className="welcome-num">3</span><span>Wire it and check compliance</span></div>
                            <div className="welcome-actions">
                                <button className="btn-yellow" onClick={draw_room_start}>Draw a room</button>
                                <label className="btn-outline">{"Importing ..." if importing else "Import a plan"}<input type="file" accept={ACCEPT_FILES} className="hidden" style={{"display": "none"}} disabled={importing} onChange={import_plan} /></label>
                                <button className="btn-text" onClick={view_sample}>View the sample flat</button>
                            </div>
                            <div className="welcome-formats">{import_msg if import_msg != "" else "Import: JPG, PNG, PDF, SVG, DXF (AutoCAD). DWG: save as DXF first."}</div>
                        </div>
                    </div>}
                    <div className="absolute bottom-5 right-5 flex items-center gap-1 border bg-background p-1 shadow-sm"><button className="top-action" onClick={zoom_out}>−</button><span className="min-w-12 text-center text-xs">{str(zoom)}%</span><button className="top-action" onClick={zoom_in}>+</button></div>
                </div>
                <footer className="flex min-h-8 flex-wrap items-center gap-5 border-t bg-background px-3 py-1.5 text-[10px] text-muted-foreground"><span>X 4.20 m</span><span>Y 2.10 m</span><span>Zoom {str(zoom)}%</span><span>Grid 10 cm</span><span className="ml-auto">Ready</span></footer></main>
            <aside className="hidden w-80 shrink-0 border-l bg-background lg:flex lg:flex-col"><div className="grid grid-cols-5 border-b">{for tab in ["Properties", "Unit", "Compliance", "Materials", "AI"] {<button key={tab} className={"panel-tab " + ("panel-tab-active" if panel == tab else "")} onClick={lambda { choose_panel(tab); }}>{tab}</button>}}</div><div className="flex-1 overflow-y-auto p-4"><div className="text-sm font-semibold">{panel}</div><p className="mt-1 text-xs text-muted-foreground">Panel tools for this floor plan.</p>{panel == "Properties" and <div className="mt-5 border-t pt-4"><div className="property-label">SELECTION</div><div className="mt-2 text-sm">{selected.label if selected != None else "Nothing selected"}</div><div className="mt-5 property-label">PROJECT STANDARD</div><div className="mt-2 text-sm">BS 7671:2018+A2:2022</div></div>}{panel == "Compliance" and <div className="mt-5 border p-3 text-xs">No issues detected</div>}{panel == "Materials" and <div className="mt-5 border p-3 text-xs">Material quantities update as devices are placed.</div>}{panel == "AI" and (scanning or len(suggestions) > 0) and <div className="mt-4"><RoomReview suggestions={suggestions} scanning={scanning} aiOk={scan_ai} message={scan_msg} activeId={active_sug} onReview={review} onSelect={select_sug} onConfirmAll={confirm_all} onApply={apply_rooms} onRescan={suggest_wiring} /></div>}{panel == "AI" and not scanning and len(suggestions) == 0 and rooms_count > 0 and <div className="ai-steps"><button className={"ai-step" + (" ai-step-on" if ai_view != "loads" else "")} onClick={lambda { ai_view = "layout"; }}>2 · Lights &amp; sockets</button><button className={"ai-step" + (" ai-step-on" if ai_view == "loads" else "")} onClick={open_loads}>3 · Appliances</button></div>}{panel == "AI" and not scanning and len(suggestions) == 0 and rooms_count > 0 and ai_view != "loads" and <div className="mt-4"><WiringLayout layout={layout} loading={layout_loading} onPreview={show_layout} onApply={place_layout} onClear={remove_layout} onRescan={suggest_wiring} onNext={open_loads} /></div>}{panel == "AI" and not scanning and len(suggestions) == 0 and rooms_count > 0 and ai_view == "loads" and <div className="mt-4"><LoadsWizard data={loads_data} busy={loads_busy} onAddAc={add_ac_room} onAddLoad={add_load_item} onRemove={remove_load_tag} onHover={set_hl} /></div>}{panel == "AI" and not scanning and len(suggestions) == 0 and rooms_count == 0 and bg != None and <div className="mt-5"><button className="wire-action wire-action-block" onClick={suggest_wiring}><span aria-hidden="true">ϟ</span>Suggest wiring</button><p className="mt-2 text-xs text-muted-foreground">Scans the imported plan, names each room and asks you about any it is unsure of.</p></div>}{panel == "AI" and not scanning and len(suggestions) == 0 and rooms_count == 0 and <div className="mt-5"><textarea className="w-full resize-none border bg-background p-3 text-xs" rows={4} placeholder="Add sockets to the kitchen per regs" /><button className="mt-2 w-full bg-[#FFD600] px-3 py-2 text-xs font-semibold text-black">Ask WireWise</button></div>}{panel == "Unit" and <div className="mt-5 border p-3 text-xs">12 ways · 100 A main switch<br />No circuits assigned yet.</div>}</div></aside>
        </div>
        <style>{".wirewise{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:12px;color:#171717}.tool-heading{padding:8px 8px 5px;font-size:9px;font-weight:700;letter-spacing:.14em;color:#8b8b85}.tool-button{display:flex;width:100%;align-items:center;gap:8px;padding:7px 8px;border:1px solid transparent;background:transparent;font-size:10px;color:#363630}.tool-button:hover{background:#f4f4ef}.tool-active{background:#fff2a6;border-color:#e2c300}.tool-glyph{display:flex;width:22px;height:22px;align-items:center;justify-content:center;border:1px solid #ddd;background:white;font-size:10px;font-weight:700}.tool-button kbd{font-size:9px;color:#999}.top-action{padding:6px 8px;border:1px solid transparent;background:transparent;font-size:11px}.top-action:hover{border-color:#ddd;background:#f5f5f2}.export-action{background:#FFD600;padding:8px 12px;font-size:10px;font-weight:700;color:#111}.level-tab{height:100%;border-bottom:2px solid #FFD600;padding:0 10px;font-size:11px;font-weight:700}.panel-tab{border-bottom:1px solid #e5e5e2;padding:12px 1px;font-size:9px;color:#777}.panel-tab-active{border-bottom:2px solid #FFD600;color:#111;font-weight:700}.property-label{font-size:9px;letter-spacing:.12em;color:#999}.plan-canvas{cursor:crosshair}.is-dark{background:#171717;color:#f5f5f5}.is-dark header,.is-dark aside,.is-dark footer{background:#202020;color:#eee}.is-dark .canvas-wrap{background:#292929}.is-dark .top-action{color:#eee}.is-dark .plan-canvas{filter:invert(.88) hue-rotate(160deg)}@media(max-width:700px){.tool-rail{width:54px;padding:4px}.tool-heading{font-size:7px;padding-left:3px}.tool-button{justify-content:center;padding:5px 2px}.tool-button>span:nth-child(2),.tool-button kbd{display:none}.canvas-wrap{padding:8px}.export-action{padding:7px 8px}}.welcome-backdrop{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(243,243,240,.55);z-index:20}.welcome-card{width:min(520px,92%);border:2px solid #111;background:#f7f6f1;box-shadow:6px 6px 0 #111}.welcome-head{background:#111;color:#fff;padding:14px 20px}.welcome-kicker{font-size:10px;font-weight:700;letter-spacing:.2em;color:#FFD600}.welcome-title{margin-top:4px;font-size:18px;font-weight:700}.welcome-step{display:flex;align-items:center;gap:14px;border-bottom:1px solid #ddd;padding:14px 20px;font-size:13px}.welcome-num{display:flex;width:30px;height:30px;align-items:center;justify-content:center;border:1px solid #111;font-weight:700}.welcome-keys{margin-left:auto;display:flex;gap:4px}.welcome-keys kbd{border:1px solid #ccc;padding:1px 5px;font-size:9px;color:#777}.welcome-actions{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:16px 20px}.btn-yellow{background:#FFD600;border:1px solid #111;padding:8px 12px;font-weight:700;font-size:12px;box-shadow:2px 2px 0 #111;cursor:pointer}.btn-outline{background:#fff;border:1px solid #111;padding:8px 12px;font-size:12px;cursor:pointer}.btn-text{background:transparent;border:none;padding:8px 6px;font-size:12px;cursor:pointer}.btn-text:hover{text-decoration:underline}.welcome-formats{border-top:1px solid #ddd;padding:10px 20px;font-size:11px;color:#666}.welcome-close{margin-left:auto;background:transparent;border:none;color:#fff;font-size:16px;cursor:pointer}.wire-action{display:inline-flex;align-items:center;gap:6px;margin-left:6px;background:#FFD600;border:1px solid #111;padding:5px 10px;font-size:11px;font-weight:700;color:#111;box-shadow:2px 2px 0 #111;cursor:pointer;white-space:nowrap}.wire-action:hover{background:#ffe14d}.wire-action:disabled{opacity:.6;cursor:progress}.wire-action-block{width:100%;justify-content:center;margin-left:0;padding:9px 12px;font-size:12px}.ai-banner{position:absolute;top:12px;left:50%;transform:translateX(-50%);display:flex;align-items:center;gap:12px;background:#111;color:#fff;padding:8px 14px;font-size:12px;z-index:15;white-space:nowrap}.ai-banner button{background:transparent;border:none;color:#FFD600;font-weight:700;cursor:pointer;font-size:12px;padding:0}.scan-overlay{position:absolute;inset:0;pointer-events:none;overflow:hidden;background:rgba(255,214,0,.05);z-index:10}.scan-line{position:absolute;left:0;right:0;height:60px;top:-60px;background:linear-gradient(to bottom,rgba(255,214,0,0),rgba(255,214,0,.35));border-bottom:2px solid #FFD600;animation:scanmove 1.8s linear infinite}@keyframes scanmove{to{top:100%}}.rr-dot{display:inline-block;width:8px;height:8px;background:#FFD600;animation:blink 1s steps(2) infinite}@keyframes blink{50%{opacity:0}}.sug{cursor:pointer}.sug-shape{stroke-width:2.5;vector-effect:non-scaling-stroke}.sug:hover .sug-shape,.sug-active{stroke-width:4.5}.sug-pending{fill:rgba(37,99,235,.07);stroke:#2563eb;stroke-dasharray:8 5}.sug-ask{fill:rgba(255,214,0,.24);stroke:#b45309;stroke-dasharray:8 5}.sug-confirmed{fill:rgba(23,23,23,.04);stroke:#171717}.sug-tag-pending{fill:#2563eb}.sug-tag-text-pending{fill:#fff}.sug-tag-ask{fill:#FFD600;stroke:#111;stroke-width:1}.sug-tag-text-ask{fill:#111}.sug-tag-confirmed{fill:#111}.sug-tag-text-confirmed{fill:#FFD600}.dev-ghost{opacity:.55}.dev-ring{fill:rgba(37,99,235,.18);stroke:#2563eb;stroke-width:3;animation:ring 1s ease-in-out infinite alternate}@keyframes ring{from{opacity:.35}to{opacity:1}}.ai-steps{display:grid;grid-template-columns:1fr 1fr;margin-top:12px;border:1px solid #111}.ai-step{padding:7px 4px;font-size:10px;font-weight:700;background:#fff;border:none;cursor:pointer;font-family:inherit;color:#777}.ai-step+.ai-step{border-left:1px solid #111}.ai-step-on{background:#111;color:#FFD600}.rr{display:flex;flex-direction:column;gap:10px;font-size:11px}.rr-head{display:flex;align-items:flex-start;justify-content:space-between;gap:8px}.rr-kicker{font-size:9px;font-weight:700;letter-spacing:.14em;color:#8b8b85}.rr-title{font-size:14px;font-weight:700;margin-top:2px}.rr-ghost{border:1px solid #111;background:#fff;padding:4px 8px;font-size:10px;font-weight:700;cursor:pointer}.rr-ghost:disabled{opacity:.5}.rr-note{border:1px solid #e5e5e2;background:#fafaf7;padding:8px 10px;color:#555;line-height:1.5}.rr-warn{border:1px solid #e2c300;background:#fff8d6;padding:8px 10px;color:#5c4a00;line-height:1.5}.rr-scanning{display:flex;align-items:center;gap:8px}.rr-counts{display:flex;gap:10px;font-size:9px;font-weight:700;letter-spacing:.12em;color:#777;border-bottom:1px solid #e5e5e2;padding-bottom:8px}.rr-count-ask{color:#111;background:#FFD600;padding:0 4px}.rr-section{font-size:9px;font-weight:700;letter-spacing:.14em;color:#8b8b85;margin-top:4px}.rr-card{border:1px solid #d4d4cf;background:#fff;padding:10px;display:flex;flex-direction:column;gap:8px;cursor:pointer}.rr-card:hover{border-color:#111}.rr-active{border-color:#111;box-shadow:3px 3px 0 #111}.rr-ask{border-color:#e2c300;background:#fffbe6}.rr-row{display:flex;align-items:center;gap:8px}.rr-row-gap{gap:6px}.rr-num{display:flex;flex:none;width:22px;height:22px;align-items:center;justify-content:center;border:1px solid #111;font-weight:700;font-size:11px;background:#fff}.rr-num-ask{background:#FFD600}.rr-num-done{background:#111;color:#FFD600}.rr-q{font-weight:700;font-size:12px}.rr-name{flex:1;min-width:0;border:1px solid transparent;background:transparent;padding:3px 4px;font-weight:700;font-size:12px;font-family:inherit;color:inherit}.rr-name:hover,.rr-name:focus{border-color:#d4d4cf;background:#fff;outline:none}.rr-conf{font-size:10px;color:#777}.rr-select{border:1px solid #d4d4cf;background:#fff;padding:4px 6px;font-size:11px;font-family:inherit;color:inherit}.rr-grow{flex:1;min-width:0}.rr-tick{width:30px;height:28px;flex:none;background:#111;color:#FFD600;border:1px solid #111;font-weight:700;cursor:pointer}.rr-cross{width:30px;height:28px;flex:none;background:#fff;color:#111;border:1px solid #d4d4cf;cursor:pointer}.rr-cross:hover{border-color:#111}.rr-meta{font-size:10px;color:#777}.rr-chips{display:flex;flex-wrap:wrap;gap:6px}.rr-chip{border:1px solid #111;background:#fff;padding:5px 8px;font-size:11px;font-weight:700;cursor:pointer;box-shadow:2px 2px 0 #111;font-family:inherit}.rr-chip:hover{background:#FFD600}.rr-chip-muted{box-shadow:none;border-color:#d4d4cf;font-weight:400;color:#666}.rr-done{flex-direction:row;align-items:center;padding:7px 10px}.rr-done-name{font-weight:700;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.rr-done-type{font-size:10px;color:#888}.rr-link{background:none;border:none;padding:0 2px;font-size:10px;text-decoration:underline;cursor:pointer;color:inherit;opacity:.75}.rr-ignored{align-self:flex-start}.rr-muted{opacity:.65}.rr-actions{display:flex;flex-direction:column;gap:8px;border-top:1px solid #e5e5e2;padding-top:10px}.rr-outline{border:1px solid #111;background:#fff;padding:8px;font-weight:700;font-size:11px;cursor:pointer;font-family:inherit}.rr-primary{border:1px solid #111;background:#FFD600;color:#111;padding:9px;font-weight:700;font-size:12px;cursor:pointer;box-shadow:2px 2px 0 #111;font-family:inherit}.rr-primary:disabled{opacity:.45;cursor:not-allowed;box-shadow:none}.rr-hint{font-size:10px;color:#777}.rr-next{display:flex;flex-direction:column;gap:3px;border:1px dashed #d4d4cf;padding:8px 10px;color:#999;font-size:10px}.is-dark .rr-card,.is-dark .rr-num,.is-dark .rr-ghost,.is-dark .rr-select,.is-dark .rr-chip,.is-dark .rr-outline,.is-dark .rr-cross{background:#2a2a2a;color:#eee;border-color:#555}.is-dark .rr-ask{background:#3a3200;border-color:#8a7400}.is-dark .rr-num-ask{background:#FFD600;color:#111}.is-dark .rr-note{background:#262626;border-color:#3a3a3a;color:#bbb}.is-dark .rr-active{border-color:#FFD600;box-shadow:3px 3px 0 #FFD600}.is-dark .rr-chip{box-shadow:2px 2px 0 #000}.dev-ghost circle,.dev-ghost rect{stroke-dasharray:3 2}"}</style>
    </div>;
}
