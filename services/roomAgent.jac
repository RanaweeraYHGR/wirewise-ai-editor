"""AI room identification for imported floor plans.

Rooms are found geometrically (services/planVision); the vision model only names them.
It sees the plan with every room outlined and numbered, and can call look_closer to
zoom into one room when the label is small or handwritten.
"""

import from jaclang.byllm.lib { Image }
import from jaclang.byllm.types { Text, Media }
import from services.planVision { scan_crop }

enum RoomType: str {
    LIVING = "living",
    BEDROOM = "bedroom",
    KITCHEN = "kitchen",
    BATHROOM = "bathroom",
    WC = "wc",
    DINING = "dining",
    HALL = "hall",
    UTILITY = "utility",
    OFFICE = "office",
    STORAGE = "storage",
    GARAGE = "garage",
    OTHER = "other",
    NOT_A_ROOM = "not_a_room"
}

sem RoomType.LIVING = "Living room, lounge, sitting room, family room.";
sem RoomType.BEDROOM = "Bedroom (master, double, single, guest).";
sem RoomType.KITCHEN = "Kitchen or kitchen-diner.";
sem RoomType.BATHROOM = "Bathroom or shower room with a bath or shower.";
sem RoomType.WC = "Toilet / cloakroom with only a WC and basin.";
sem RoomType.DINING = "Dining room.";
sem RoomType.HALL = "Hallway, corridor, landing, entrance or lobby.";
sem RoomType.UTILITY = "Utility or laundry room.";
sem RoomType.OFFICE = "Study or home office.";
sem RoomType.STORAGE = "Store, cupboard, wardrobe or pantry.";
sem RoomType.GARAGE = "Garage.";
sem RoomType.OTHER = "A real room that fits none of the other types.";
sem RoomType.NOT_A_ROOM = "Not a room: wall cavity, gap between dimension lines, staircase void, or drawing artefact.";

obj RoomGuess {
    has region: int;
    has room_type: RoomType;
    has name: str;
    has confidence: float;
    has alternatives: list[RoomType];
    has written_label: str;
    has written_size: str;
}

sem RoomGuess.region = "The red number printed inside the outlined region.";
sem RoomGuess.room_type = "Best guess for what this region is.";
sem RoomGuess.name = "Short display name, e.g. 'Bedroom 1', 'Kitchen', 'Bath'. Use the label written on the plan when there is one.";
sem RoomGuess.confidence = "0.0-1.0. Above 0.85 only when the plan labels the room or the fixtures make it unambiguous. 0.5 or less when guessing from size and position alone.";
sem RoomGuess.alternatives = "Up to 3 other plausible types, most likely first. Empty when confidence is above 0.9.";
sem RoomGuess.written_label = "The room label exactly as written on the plan, or empty if none.";
sem RoomGuess.written_size = "Any dimension text written inside or along this room (e.g. '12 x 8', '3.6m'), or empty.";

"""Zoomed image of one numbered region, for reading small or handwritten text."""
def look_closer(scan_id: str, region: int) -> list[Media] {
    url = scan_crop(scan_id, region) as str;
    if url == "" {
        return [Text(text=f"There is no region {region}.")];
    }
    return [Text(text=f"Close-up of region {region}:"), Image(url=url)];
}

sem look_closer = "Zoom into one numbered region to read its label, fixtures (bath, WC, hob, bed) and door positions. Use it whenever a region's label is unreadable or missing in the overview.";
sem look_closer.scan_id = "The scan_id given to you.";
sem look_closer.region = "The region number to zoom into.";

def identify_rooms(plan: Image, scan_id: str, regions: str) -> list[RoomGuess] by llm(
    tools=[look_closer],
    temperature=0.1,
    max_react_iterations=10
);

sem identify_rooms = """Identify every numbered region on an architectural floor plan for an electrician who will wire the home.
Each candidate room is outlined in red with its number at the centre.
Read labels written on the plan first; then use fixtures (bath, shower, WC, basin, hob, sink, bed), size and position.
Call look_closer for any region whose label you cannot read clearly in the overview.
Return exactly one RoomGuess per region number listed, in order. Never invent region numbers.
Be honest with confidence: a wrong confident answer is worse than asking the user.""";
sem identify_rooms.plan = "The floor plan with numbered red room outlines.";
sem identify_rooms.scan_id = "Pass this to look_closer.";
sem identify_rooms.regions = "One line per region: number, share of the floor area, proportions, real size if known, and neighbouring regions.";
