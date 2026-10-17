"""Room agent wiring: the model may zoom in with look_closer, then must return one guess per region."""

import base64;
import from jaclang.byllm.lib { MockLLM, MockToolCall, Image }
import services.roomAgent as agent;
import from services.roomAgent { identify_rooms, look_closer, RoomType }
import from services.planVision { scan_start }

# A tiny two-room plan: thick outer walls and one dividing wall
def _two_room_plan() -> str {
    import numpy as np;
    import cv2;
    img = np.full((400, 600), 255, dtype=np.uint8);
    cv2.rectangle(img, (40, 40), (560, 360), 0, 10);
    cv2.line(img, (300, 40), (300, 360), 0, 8);
    encoded: any = cv2.imencode(".png", img)[1];
    return "data:image/png;base64," + base64.b64encode(encoded.tobytes() as bytes).decode("ascii");
}

test "scan finds both rooms and the agent can zoom in before answering" {
    scan = scan_start(_two_room_plan()) as dict[str, any];
    regions = scan["regions"] as list[dict[str, any]];
    assert len(regions) == 2, f"expected 2 rooms, got {len(regions)}";
    mock = MockLLM(outputs=[
        MockToolCall(tool=look_closer, args={"scan_id": scan["scan_id"], "region": 2}),
        MockToolCall(tool="finish_tool", args={"final_output": [
            {"region": 1, "room_type": "kitchen", "name": "Kitchen", "confidence": 0.9, "alternatives": [], "written_label": "", "written_size": ""},
            {"region": 2, "room_type": "bathroom", "name": "Bath", "confidence": 0.6, "alternatives": ["wc"], "written_label": "Bath", "written_size": ""}
        ]})
    ]);
    agent.llm = mock;
    guesses = identify_rooms(Image(url=scan["marked"] as str), scan["scan_id"] as str, "Region 1: 50%\nRegion 2: 50%");
    assert len(guesses) == 2;
    assert guesses[1].room_type == RoomType.BATHROOM;
    assert guesses[1].alternatives == [RoomType.WC];
    sent = str(mock.sent("messages"));
    assert "Close-up of region 2" in sent, "look_closer result should reach the model";
}

test "look_closer reports unknown regions instead of failing" {
    scan = scan_start(_two_room_plan()) as dict[str, any];
    out = look_closer(scan["scan_id"] as str, 99);
    assert len(out) == 1;
}
