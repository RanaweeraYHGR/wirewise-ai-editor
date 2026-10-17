"""Room detection on imported floor plans (OpenCV), for the AI room check.

Walls are the thick strokes of the drawing; door gaps are closed with a gap size that
separates the most rooms, then each room grows back out to its walls. Thin lines (text,
door swings, dimensions) never split rooms. Coordinates are working-raster pixels;
the caller converts them to canvas cm.
"""

::py::
import base64, io

WORK_PX = 1400        # long side of the working raster
INK_LEVEL = 170       # gray below this counts as drawn ink


def _decode(data_url):
    head, _, body = data_url.partition(",")
    return head, base64.b64decode(body)


def plan_gray(data_url):
    """Rasterize the stored plan image (PNG/JPG/SVG data URL) to a white-backed grayscale array."""
    import numpy as np
    from PIL import Image
    head, raw = _decode(data_url)
    if "svg" in head:
        import pymupdf
        page = pymupdf.open(stream=raw, filetype="svg")[0]
        zoom = WORK_PX / max(page.rect.width, page.rect.height)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
        img = Image.open(io.BytesIO(pix.tobytes("png")))
    else:
        img = Image.open(io.BytesIO(raw))
    img = img.convert("RGBA")
    flat = Image.new("RGBA", img.size, "white")
    flat.alpha_composite(img)
    img = flat.convert("L")
    k = WORK_PX / max(img.size)
    img = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))), Image.LANCZOS)
    return np.asarray(img, dtype=np.uint8)


def _wall_mask(ink, size):
    """Wall strokes only. Drawings with thick walls drop every thin line (text, door
    swings, dimensions, furniture); thin-line CAD drawings keep lines but drop small marks."""
    import cv2, numpy as np
    dist = cv2.distanceTransform(ink, cv2.DIST_L2, 3)
    ridge = dist[(dist >= cv2.dilate(dist, np.ones((3, 3), np.uint8))) & (dist > 0)]
    if ridge.size:
        thick_half = float(np.percentile(ridge, 90))
        thin_half = float(np.percentile(ridge, 50))
        if thick_half >= 3.0 and thick_half >= 2.5 * thin_half:
            k = 2 * max(2, round(thick_half * 0.35)) + 1
            walls = cv2.morphologyEx(ink, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (k, k)))
            if cv2.countNonZero(walls) > ink.size * 0.002:
                return _drop_small(walls, size * 0.02)
    return _drop_small(ink, size * 0.06)


def _drop_small(mask, min_extent):
    """Remove marks whose bounding box is smaller than min_extent px (letters, symbols, specks)."""
    import cv2, numpy as np
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    keep = [i for i in range(1, n) if max(stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT]) >= min_extent]
    return np.where(np.isin(labels, keep), 255, 0).astype(np.uint8)


def _footprint(walls):
    """Building outline: convex hull of the walls. Closes wide exterior openings."""
    import cv2
    pts = cv2.findNonZero(walls)
    return None if pts is None else cv2.convexHull(pts)


def _cores_at(walls, hull_mask, r):
    """Room cores: free space inside the footprint after closing gaps narrower than 2r (doors)."""
    import cv2
    kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
    free = cv2.bitwise_and(cv2.bitwise_not(cv2.dilate(walls, kern)), hull_mask)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(free, connectivity=4)
    min_core = cv2.countNonZero(hull_mask) * 0.003
    keep = [i for i in range(1, n) if stats[i, cv2.CC_STAT_AREA] >= min_core]
    return labels, keep


def _regrow(labels, keep, open_space, steps):
    """Grow each core back out to its walls; rooms meet halfway across a doorway."""
    import cv2, numpy as np
    lab = np.zeros(labels.shape, np.uint16)
    for new_id, old in enumerate(keep, start=1):
        lab[labels == old] = new_id
    free = open_space > 0
    k3 = np.ones((3, 3), np.uint8)
    for _ in range(steps):
        grown = cv2.dilate(lab, k3)
        fill = (lab == 0) & free & (grown > 0)
        if not fill.any():
            break
        lab[fill] = grown[fill]
    return lab, [((lab == i).astype(np.uint8) * 255) for i in range(1, len(keep) + 1)]


def _doorways(lab, size):
    """Openings between rooms: where two regrown rooms touch with no wall between them.
    Returns {label: [[x, y, width], ...]} in px."""
    import cv2, numpy as np
    pairs = {}
    for a, b, ys, xs in ((lab[:, :-1], lab[:, 1:], None, None), (lab[:-1, :], lab[1:, :], None, None)):
        touch = (a > 0) & (b > 0) & (a != b)
        ys, xs = np.nonzero(touch)
        lo = np.minimum(a[ys, xs], b[ys, xs]).astype(np.int64)
        hi = np.maximum(a[ys, xs], b[ys, xs]).astype(np.int64)
        for key in np.unique(lo * 65536 + hi):
            sel = (lo * 65536 + hi) == key
            pairs.setdefault(int(key), []).append((ys[sel], xs[sel]))
    doors = {}
    for key, parts in pairs.items():
        mask = np.zeros(lab.shape, np.uint8)
        for ys, xs in parts:
            mask[ys, xs] = 255
        mask = cv2.dilate(mask, np.ones((5, 5), np.uint8))
        n, _, stats, cents = cv2.connectedComponentsWithStats(mask, connectivity=8)
        for i in range(1, n):
            width = max(stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT]) - 4
            if width < size * 0.015:
                continue
            door = [float(cents[i][0]), float(cents[i][1]), float(width)]
            for label in (key // 65536, key % 65536):
                doors.setdefault(label, []).append(door)
    return doors


def segment_rooms(gray):
    """Find enclosed rooms. Returns list of dicts with pixel bbox, area, polygon (all in working-raster px)."""
    import cv2, numpy as np
    h, w = gray.shape
    size = max(h, w)
    ink = np.where(gray < INK_LEVEL, 255, 0).astype(np.uint8)
    walls = _wall_mask(ink, size)
    hull = _footprint(walls)
    if hull is None:
        return []
    cv2.polylines(walls, [hull], True, 255, max(2, round(size * 0.004)))
    hull_mask = np.zeros_like(ink)
    cv2.fillPoly(hull_mask, [hull], 255)
    # Try door-gap sizes from narrow to wide; keep the one that separates the most rooms
    best_r, best_keep, best_labels = 0, [], None
    for frac in (0.008, 0.015, 0.022, 0.03, 0.04, 0.05, 0.06):
        r = max(1, round(size * frac))
        labels, keep = _cores_at(walls, hull_mask, r)
        if len(keep) > len(best_keep):
            best_r, best_keep, best_labels = r, keep, labels
    if not best_keep:
        return []
    open_space = cv2.bitwise_and(cv2.bitwise_not(walls), hull_mask)
    hull_area = cv2.countNonZero(hull_mask)
    lab, masks = _regrow(best_labels, best_keep, open_space, round(best_r * 1.6) + 2)
    door_map = _doorways(lab, size)
    kept = [i for i, m in enumerate(masks) if cv2.countNonZero(m) >= hull_area * 0.01]
    best = [masks[i] for i in kept]
    best_doors = [door_map.get(i + 1, []) for i in kept]
    # Rooms whose masks nearly touch across a wall are neighbours
    reach = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (round(size * 0.03) | 1,) * 2)
    grown = [cv2.dilate(m, reach) for m in best]
    out = []
    for idx, mask in enumerate(best):
        x, y, bw, bh = cv2.boundingRect(mask)
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        c = max(contours, key=cv2.contourArea)
        poly = cv2.approxPolyDP(c, size * 0.005, True).reshape(-1, 2)
        m = cv2.moments(mask, binaryImage=True)
        out.append({"x": x, "y": y, "w": bw, "h": bh, "area": int(cv2.countNonZero(mask)),
                    "cx": m["m10"] / m["m00"], "cy": m["m01"] / m["m00"],
                    "poly": [[int(px), int(py)] for px, py in poly],
                    "doors": best_doors[idx],
                    "_idx": idx, "_near": [j for j in range(len(best)) if j != idx and cv2.countNonZero(cv2.bitwise_and(grown[idx], best[j])) > 0]})
    # Reading order: top-to-bottom, left-to-right
    out.sort(key=lambda r: (round(r["cy"] / (size * 0.08)), r["cx"]))
    ids = {}
    for i, r in enumerate(out):
        r["id"] = i + 1
        ids[r["_idx"]] = i + 1
    for r in out:
        r["near"] = sorted(ids[j] for j in r.pop("_near"))
        del r["_idx"]
    return out


# Recent scans, so the agent's look_closer tool can crop the same raster
_SCANS = {}


def scan_start(data_url):
    """Detect rooms on a plan image. Returns scan_id, raster size, regions and the numbered overview image."""
    import uuid
    gray = plan_gray(data_url)
    regions = segment_rooms(gray)
    scan_id = uuid.uuid4().hex[:12]
    while len(_SCANS) >= 4:
        _SCANS.pop(next(iter(_SCANS)))
    _SCANS[scan_id] = (gray, regions)
    h, w = gray.shape
    return {"scan_id": scan_id, "width": w, "height": h, "regions": regions,
            "marked": marked_image(gray, regions) if regions else ""}


def scan_crop(scan_id, region):
    """Close-up PNG data URL of one region from a recent scan ('' if unknown)."""
    entry = _SCANS.get(scan_id)
    if entry is None:
        return ""
    gray, regions = entry
    for r in regions:
        if r["id"] == int(region):
            return region_crop(gray, r)
    return ""


def marked_image(gray, regions):
    """Plan with each detected room outlined and numbered, for the vision model."""
    import cv2, numpy as np
    img = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    size = max(gray.shape)
    fs = size / 1400.0
    for r in regions:
        pts = np.array(r["poly"], dtype=np.int32)
        cv2.polylines(img, [pts], True, (0, 0, 255), max(2, round(3 * fs)))
        label = str(r["id"])
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 1.1 * fs, max(2, round(2 * fs)))
        # Badge in the room's top-left corner so it never hides the written room label
        pad = round(8 * fs)
        cx = r["x"] + tw // 2 + pad + round(10 * fs)
        cy = r["y"] + th // 2 + pad + round(10 * fs)
        cv2.rectangle(img, (cx - tw // 2 - pad, cy - th // 2 - pad), (cx + tw // 2 + pad, cy + th // 2 + pad), (0, 0, 255), -1)
        cv2.putText(img, label, (cx - tw // 2, cy + th // 2), cv2.FONT_HERSHEY_SIMPLEX, 1.1 * fs, (255, 255, 255), max(2, round(2 * fs)))
    return _png_url(img, 1400)


def region_crop(gray, region, regions=None):
    """Zoomed view of one room (with a margin) so the model can read small text."""
    import cv2
    h, w = gray.shape
    pad = round(max(region["w"], region["h"]) * 0.15) + 10
    x0, y0 = max(0, region["x"] - pad), max(0, region["y"] - pad)
    x1, y1 = min(w, region["x"] + region["w"] + pad), min(h, region["y"] + region["h"] + pad)
    crop = cv2.cvtColor(gray[y0:y1, x0:x1], cv2.COLOR_GRAY2BGR)
    return _png_url(crop, 1024, upscale=True)


def _png_url(img, max_side, upscale=False):
    import cv2
    h, w = img.shape[:2]
    k = max_side / max(h, w)
    if k < 1.0 or upscale:
        img = cv2.resize(img, (max(1, round(w * k)), max(1, round(h * k))), interpolation=cv2.INTER_AREA if k < 1 else cv2.INTER_CUBIC)
    ok, buf = cv2.imencode(".png", img)
    return "data:image/png;base64," + base64.b64encode(buf.tobytes()).decode("ascii")
::py::
