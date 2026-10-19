# jac 0.34 registers an endpoint at /function/<name> only when the entry module imports it by name
# (jaseci-labs/jac#7695): keep every def:pub from the service listed here.
import from services.floorPlanService {
    rename_project, get_floor_plan, start_blank_plan, load_sample_flat, add_room,
    add_plan_element, get_background, import_background, set_background_scale,
    clear_background, get_suggestions, scan_plan, review_suggestion, confirm_all_suggestions,
    apply_suggestions, preview_layout, apply_layout, clear_layout, get_loads, preview_load,
    add_load, add_ac, remove_load, get_cu, confirm_cu, move_cu, start_wiring, clear_wiring,
    finalize_wiring, get_booklet
}
import from .components.FloorPlanEditor { FloorPlanEditor }
import ".styles.global.css";

def:pub app() -> JsxElement {
    return <FloorPlanEditor />;
}
