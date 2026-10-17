sv import from ..services.floorPlanService {
    FloorPlan, PlanElement, get_floor_plan, add_plan_element,
    start_blank_plan, load_sample_flat, add_room,
    BackgroundInfo, get_background, import_background, set_background_scale, clear_background
}
import "../styles/global.css";

# Formats the Import button accepts (DWG is accepted only to show a "save as DXF" hint)
glob ACCEPT_FILES: str = ".png,.jpg,.jpeg,.gif,.webp,.bmp,.tif,.tiff,.svg,.pdf,.dxf,.dwg";
glob MAX_FILE_MB: int = 20;
glob EMPTY_PLAN: dict = {"name": "", "level": "Ground", "rooms": [], "devices": []};

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
        by: float = bg.y as float;
        bw: float = bg.width as float;
        bh: float = bg.height as float;
        vw = max(900.0, bx + bw + 50.0);
        vh = max(620.0, by + bh + 50.0);
    }
    view_box = "0 0 " + str(vw) + " " + str(vh);
    bg_label = "";
    if bg != None {
        bg_label = "PLAN · " + (bg.source as str) + ("" if bg.scaled else " · NOT SCALED");
    }

    return <div className={"wirewise flex h-svh flex-col " + ("is-dark" if dark else "")}>
        <header className="flex min-h-14 flex-wrap items-center gap-3 border-b bg-background px-4 py-2"><div className="flex items-center gap-2"><div className="flex size-8 items-center justify-center bg-[#FFD600] text-black font-black">W</div><span className="font-bold">WIREWISE AI</span></div><span>/</span><input aria-label="Project name" className="w-40 bg-transparent text-sm outline-none sm:w-52" value={project_name} onChange={lambda (e: ChangeEvent) { project_name = e.target.value; }} /><span className="text-xs text-muted-foreground">● Saved</span><div className="ml-auto flex items-center gap-1"><button className="top-action">↶</button><button className="top-action">↷</button><button className="top-action hidden sm:block">Fit</button><button className="top-action hidden md:block" onClick={lambda { panel = "AI"; }}>Ask AI Ctrl+K</button><button className="top-action hidden md:block" onClick={lambda { show_welcome = True; }}>New plan</button><button className="top-action" onClick={toggle_theme}>◐</button><button className="export-action">Export PDF</button></div></header>
        <div className="flex min-h-0 flex-1">
            <aside className="tool-rail w-52 shrink-0 overflow-y-auto border-r bg-background px-2 py-3"><div className="tool-heading">PLAN</div>{for item in tools_plan {<button key={item[0]} className={"tool-button " + ("tool-active" if tool == item[0] else "")} onClick={lambda { choose_tool(item[0]); }}><span className="tool-glyph">{item[0][:1]}</span><span className="flex-1 text-left">{item[0]}</span><kbd>{item[1]}</kbd></button>}}<div className="tool-heading mt-5">ELECTRICAL</div>{for item in tools_electrical {<button key={item[0]} className={"tool-button " + ("tool-active" if tool == item[0] else "")} onClick={lambda { choose_tool(item[0]); }}><span className="tool-glyph">{item[0][:1]}</span><span className="flex-1 truncate text-left">{item[0]}</span><kbd>{item[1]}</kbd></button>}}</aside>
            <main className="flex min-w-0 flex-1 flex-col bg-[#f3f3f0]"><div className="flex h-11 shrink-0 items-center gap-2 border-b bg-background px-3"><button className="level-tab">Ground</button><button className="top-action">+ Level</button>{bg != None and <span className="flex shrink-0 items-center gap-1 whitespace-nowrap"><span className="ml-2 border px-2 py-0.5 text-[10px]">{bg_label}</span><button className={"top-action " + ("tool-active" if tool == "Scale" else "")} onClick={lambda { tool = "Scale"; scale_pts = []; }}>Set scale</button><button className="top-action" onClick={remove_background}>Remove plan</button></span>}<span className="ml-auto truncate text-xs text-muted-foreground">{import_msg if import_msg != "" else "10 cm grid"}</span></div>
                <div className="canvas-wrap relative flex min-h-0 flex-1 items-center justify-center overflow-hidden p-4 sm:p-8">
                    <div className="plan-canvas relative h-full max-h-[700px] w-full max-w-[980px] overflow-hidden border bg-white shadow-sm">
                        {plan != None and <svg className="absolute inset-0 h-full w-full" viewBox={view_box} preserveAspectRatio="xMidYMid meet" onClick={place_at} onMouseDown={on_down} onMouseMove={on_move} onMouseUp={on_up}>
                            <defs><pattern id="grid" width="10" height="10" patternUnits="userSpaceOnUse"><path d="M 10 0 L 0 0 0 10" fill="none" stroke="#e9e9e6" strokeWidth="0.7" /></pattern></defs>
                            <rect width={vw} height={vh} fill="url(#grid)" />
                            {bg != None and <image href={bg.image} x={bg.x} y={bg.y} width={bg.width} height={bg.height} opacity="0.6" preserveAspectRatio="none" />}
                            {for room in rooms {<g key={room.id} onClick={lambda (e: MouseEvent) { e.stopPropagation(); pick_room(room); }}><rect x={room.x} y={room.y} width={room.width} height={room.height} fill={"none" if bg != None else "#fff"} stroke="#171717" strokeWidth="4" /><text x={room.x + 12.0} y={room.y + 25.0} fontSize="12" fontFamily="monospace" fill="#777">{room.label.upper()}</text><text x={room.x + 12.0} y={room.y + room.height - 8.0} fontSize="10" fontFamily="monospace" fill="#aaa">{f"{room.width / 100.0:.2f} × {room.height / 100.0:.2f} m"}</text></g>}}
                            {for device in devices {<g key={device.id} transform={"translate(" + str(device.x) + " " + str(device.y) + ")"}><circle r="11" fill="#FFD600" stroke="#111" strokeWidth="2" /><text x="0" y="4" textAnchor="middle" fontSize="8" fontFamily="monospace" fill="#111">{device.label}</text></g>}}
                            {drawing and <g><rect x={draft_x} y={draft_y} width={draft_w} height={draft_h} fill="rgba(255,214,0,0.15)" stroke="#111" strokeWidth="2" strokeDasharray="6 4" /><text x={draft_x + 6.0} y={draft_y - 6.0} fontSize="11" fontFamily="monospace" fill="#111">{f"{draft_w / 100.0:.2f} × {draft_h / 100.0:.2f} m"}</text></g>}
                            {tool == "Scale" and len(scale_pts) == 2 and <g><line x1={scale_pts[0]} y1={scale_pts[1]} x2={cur_x} y2={cur_y} stroke="#e00" strokeWidth="3" strokeDasharray="8 5" /><circle cx={scale_pts[0]} cy={scale_pts[1]} r="6" fill="#e00" /></g>}
                        </svg>}
                        {plan == None and <div className="absolute inset-0 flex items-center justify-center"><div className="border bg-white p-6 text-center shadow-sm"><div className="text-lg font-semibold">Loading plan</div><p className="mt-2 text-sm text-muted-foreground">Connecting to the project graph.</p></div></div>}
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
            <aside className="hidden w-64 shrink-0 border-l bg-background lg:flex lg:flex-col"><div className="grid grid-cols-5 border-b">{for tab in ["Properties", "Unit", "Compliance", "Materials", "AI"] {<button key={tab} className={"panel-tab " + ("panel-tab-active" if panel == tab else "")} onClick={lambda { choose_panel(tab); }}>{tab}</button>}}</div><div className="flex-1 overflow-y-auto p-4"><div className="text-sm font-semibold">{panel}</div><p className="mt-1 text-xs text-muted-foreground">Panel tools for this floor plan.</p>{panel == "Properties" and <div className="mt-5 border-t pt-4"><div className="property-label">SELECTION</div><div className="mt-2 text-sm">{selected.label if selected != None else "Nothing selected"}</div><div className="mt-5 property-label">PROJECT STANDARD</div><div className="mt-2 text-sm">BS 7671:2018+A2:2022</div></div>}{panel == "Compliance" and <div className="mt-5 border p-3 text-xs">No issues detected</div>}{panel == "Materials" and <div className="mt-5 border p-3 text-xs">Material quantities update as devices are placed.</div>}{panel == "AI" and <div className="mt-5"><textarea className="w-full resize-none border bg-background p-3 text-xs" rows={4} placeholder="Add sockets to the kitchen per regs" /><button className="mt-2 w-full bg-[#FFD600] px-3 py-2 text-xs font-semibold text-black">Ask WireWise</button></div>}{panel == "Unit" and <div className="mt-5 border p-3 text-xs">12 ways · 100 A main switch<br />No circuits assigned yet.</div>}</div></aside>
        </div>
        <style>{".wirewise{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:12px;color:#171717}.tool-heading{padding:8px 8px 5px;font-size:9px;font-weight:700;letter-spacing:.14em;color:#8b8b85}.tool-button{display:flex;width:100%;align-items:center;gap:8px;padding:7px 8px;border:1px solid transparent;background:transparent;font-size:10px;color:#363630}.tool-button:hover{background:#f4f4ef}.tool-active{background:#fff2a6;border-color:#e2c300}.tool-glyph{display:flex;width:22px;height:22px;align-items:center;justify-content:center;border:1px solid #ddd;background:white;font-size:10px;font-weight:700}.tool-button kbd{font-size:9px;color:#999}.top-action{padding:6px 8px;border:1px solid transparent;background:transparent;font-size:11px}.top-action:hover{border-color:#ddd;background:#f5f5f2}.export-action{background:#FFD600;padding:8px 12px;font-size:10px;font-weight:700;color:#111}.level-tab{height:100%;border-bottom:2px solid #FFD600;padding:0 10px;font-size:11px;font-weight:700}.panel-tab{border-bottom:1px solid #e5e5e2;padding:12px 1px;font-size:9px;color:#777}.panel-tab-active{border-bottom:2px solid #FFD600;color:#111;font-weight:700}.property-label{font-size:9px;letter-spacing:.12em;color:#999}.plan-canvas{cursor:crosshair}.is-dark{background:#171717;color:#f5f5f5}.is-dark header,.is-dark aside,.is-dark footer{background:#202020;color:#eee}.is-dark .canvas-wrap{background:#292929}.is-dark .top-action{color:#eee}.is-dark .plan-canvas{filter:invert(.88) hue-rotate(160deg)}@media(max-width:700px){.tool-rail{width:54px;padding:4px}.tool-heading{font-size:7px;padding-left:3px}.tool-button{justify-content:center;padding:5px 2px}.tool-button>span:nth-child(2),.tool-button kbd{display:none}.canvas-wrap{padding:8px}.export-action{padding:7px 8px}}.welcome-backdrop{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(243,243,240,.55);z-index:20}.welcome-card{width:min(520px,92%);border:2px solid #111;background:#f7f6f1;box-shadow:6px 6px 0 #111}.welcome-head{background:#111;color:#fff;padding:14px 20px}.welcome-kicker{font-size:10px;font-weight:700;letter-spacing:.2em;color:#FFD600}.welcome-title{margin-top:4px;font-size:18px;font-weight:700}.welcome-step{display:flex;align-items:center;gap:14px;border-bottom:1px solid #ddd;padding:14px 20px;font-size:13px}.welcome-num{display:flex;width:30px;height:30px;align-items:center;justify-content:center;border:1px solid #111;font-weight:700}.welcome-keys{margin-left:auto;display:flex;gap:4px}.welcome-keys kbd{border:1px solid #ccc;padding:1px 5px;font-size:9px;color:#777}.welcome-actions{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:16px 20px}.btn-yellow{background:#FFD600;border:1px solid #111;padding:8px 12px;font-weight:700;font-size:12px;box-shadow:2px 2px 0 #111;cursor:pointer}.btn-outline{background:#fff;border:1px solid #111;padding:8px 12px;font-size:12px;cursor:pointer}.btn-text{background:transparent;border:none;padding:8px 6px;font-size:12px;cursor:pointer}.btn-text:hover{text-decoration:underline}.welcome-formats{border-top:1px solid #ddd;padding:10px 20px;font-size:11px;color:#666}.welcome-close{margin-left:auto;background:transparent;border:none;color:#fff;font-size:16px;cursor:pointer}"}</style>
    </div>;
}
