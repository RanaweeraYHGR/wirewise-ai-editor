import from services.floorPlanService { get_floor_plan, add_plan_element }
import from .components.FloorPlanEditor { FloorPlanEditor }
import ".styles.global.css";

def:pub app() -> JsxElement {
    return <FloorPlanEditor />;
}
