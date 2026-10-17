"""Converts imported floor plans (images, PDF, SVG, DXF) into one image the canvas can show.

All formats become a data URL + a size in cm (canvas units: 1 unit = 1 cm).
DXF keeps its real scale from $INSUNITS; images and PDFs need "Set scale" in the editor.
"""

::py::
import base64, io, os, tempfile

ACCEPT = "PNG, JPG, GIF, WEBP, BMP, TIFF, SVG, PDF, DXF"

def _data_url(mime, raw):
    return "data:" + mime + ";base64," + base64.b64encode(raw).decode("ascii")

def _decode(data_url):
    if "," in data_url:
        data_url = data_url.split(",", 1)[1]
    return base64.b64decode(data_url)

def convert_plan(filename, data_url):
    """Return dict: ok, message, image (data URL), width_cm, height_cm, scaled (real scale known), source."""
    name = (filename or "").lower()
    ext = name.rsplit(".", 1)[-1] if "." in name else ""
    try:
        raw = _decode(data_url)
    except Exception:
        return _fail("Could not read the file.")
    if len(raw) > 25 * 1024 * 1024:
        return _fail("File is larger than 25 MB.")
    try:
        if ext == "dxf":
            return _from_dxf(raw)
        if ext == "pdf":
            return _from_pdf(raw)
        if ext in ("png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "svg"):
            return _from_image(raw, ext)
        if ext == "dwg":
            return _fail("DWG is a closed AutoCAD format. In AutoCAD/BricsCAD/DraftSight use Save As > DXF (or Export > PDF) and import that.")
        return _fail("Unsupported file. Use " + ACCEPT + ".")
    except Exception as err:
        return _fail("Could not convert " + ext.upper() + ": " + str(err)[:200])

def _fail(msg):
    return {"ok": False, "message": msg, "image": "", "width_cm": 0.0, "height_cm": 0.0, "scaled": False, "source": ""}

def _fit(w, h, max_w=900.0):
    # Unknown real scale: show it 9 m wide until the user calibrates
    if w <= 0 or h <= 0:
        return 900.0, 620.0
    return max_w, max_w * h / w

# Line-art cleanup for raster plans (photos, scans, JPG exports)
MIN_LONG_PX = 2400     # upscale smaller images so lines stay smooth when enlarged
MAX_LONG_PX = 4000     # cap output size (stored in the graph as a data URL)
MAX_INK_COVER = 0.35   # above this the image is not line art (photo, filled render)
LINE_INK = 0.35        # ink at least this dark (vs paper) is drawn fully black

def _clean_lineart(img):
    """Turn a drawing on paper into crisp dark lines on a transparent background.

    Returns PNG bytes, or None when the image does not look like line art.
    """
    import numpy as np
    from PIL import Image, ImageFilter, ImageOps
    img = ImageOps.exif_transpose(img).convert("L")
    w, h = img.size
    long_side = max(w, h)
    k = min(3.0, MIN_LONG_PX / long_side) if long_side < MIN_LONG_PX else min(1.0, MAX_LONG_PX / long_side)
    if k != 1.0:
        img = img.resize((max(1, round(w * k)), max(1, round(h * k))), Image.LANCZOS)
    w, h = img.size
    # Paper estimate: shrink, take local max (removes lines), blur, scale back up.
    # Dividing by it flattens shadows, yellowed paper and uneven scan lighting.
    small = img.resize((max(1, w // 16), max(1, h // 16)), Image.BILINEAR)
    paper = small.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(2))
    paper = np.asarray(paper.resize((w, h), Image.BILINEAR), dtype=np.float32)
    gray = np.asarray(img, dtype=np.float32)
    ink = 1.0 - np.clip(gray / np.maximum(paper, 1.0), 0.0, 1.0)   # 0 = paper, 1 = black
    # Paper cutoff sits just above the image's own noise (JPEG speckle, paper grain),
    # so clean scans keep faint hairlines and noisy photos still come out clean.
    med = float(np.median(ink))
    noise = 1.4826 * float(np.median(np.abs(ink - med)))
    cutoff = min(0.12, max(0.05, med + 5.0 * noise))
    marked = ink > cutoff
    if marked.mean() > MAX_INK_COVER or not marked.any():
        return None
    # Stretch so typical line darkness maps to full black; keep anti-aliased edges
    full = min(LINE_INK, max(cutoff + 0.1, float(np.percentile(ink[marked], 50))))
    alpha = np.clip((ink - cutoff) / (full - cutoff), 0.0, 1.0) ** 0.6
    out = np.empty((h, w, 2), dtype=np.uint8)
    out[..., 0] = 17                                   # near-black line colour
    out[..., 1] = (alpha * 255.0 + 0.5).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(out, "LA").save(buf, "PNG", optimize=True)
    return buf.getvalue()

def _from_image(raw, ext):
    from PIL import Image
    if ext == "svg":
        import pymupdf
        page = pymupdf.open(stream=raw, filetype="svg")[0]
        fw, fh = _fit(page.rect.width, page.rect.height)
        return {"ok": True, "message": "SVG imported. Use Set scale to match real size.", "image": _data_url("image/svg+xml", raw),
                "width_cm": fw, "height_cm": fh, "scaled": False, "source": "SVG"}
    img = Image.open(io.BytesIO(raw))
    img.seek(0)  # first frame of animated GIF / multi-page TIFF
    w, h = img.size
    png = _clean_lineart(img)
    if png is not None:
        image = _data_url("image/png", png)
        msg = "Image imported and lines sharpened."
    elif ext in ("png", "jpg", "jpeg", "gif", "webp"):
        image = _data_url("image/jpeg" if ext in ("jpg", "jpeg") else "image/" + ext, raw)
        msg = "Image imported as-is (looks like a photo, not a line drawing)."
    else:  # bmp / tiff -> png so every browser can show it
        buf = io.BytesIO()
        img.convert("RGB").save(buf, "PNG")
        image = _data_url("image/png", buf.getvalue())
        msg = "Image imported as-is (looks like a photo, not a line drawing)."
    fw, fh = _fit(w, h)
    return {"ok": True, "message": msg + " Use Set scale to match real size.", "image": image,
            "width_cm": fw, "height_cm": fh, "scaled": False, "source": ext.upper()}

MAX_SVG_BYTES = 12 * 1024 * 1024

def _is_scan(page):
    """True when the page is mostly one big picture (a scanned drawing) rather than vector lines."""
    page_area = abs(page.rect)
    img_area = 0.0
    for info in page.get_image_info():
        img_area += abs(page.rect & info["bbox"])
    return page_area > 0 and img_area / page_area > 0.5 and len(page.get_drawings()) < 50

def _from_pdf(raw):
    import pymupdf
    from PIL import Image
    doc = pymupdf.open(stream=raw, filetype="pdf")
    page = doc[0]
    fw, fh = _fit(page.rect.width, page.rect.height)
    msg = "PDF page 1 imported"
    if doc.page_count > 1:
        msg = "PDF has " + str(doc.page_count) + " pages; page 1 imported"
    if not _is_scan(page):
        # Vector drawing: keep it as SVG so lines stay sharp at any zoom
        svg_text = page.get_svg_image(text_as_path=True)
        if len(svg_text) <= MAX_SVG_BYTES:
            return {"ok": True, "message": msg + " as vector lines. Use Set scale to match real size.",
                    "image": _data_url("image/svg+xml", svg_text.encode("utf-8")),
                    "width_cm": fw, "height_cm": fh, "scaled": False, "source": "PDF"}
    # Scanned (or too complex for SVG): render at high resolution and clean up the lines
    zoom = MAX_LONG_PX / max(page.rect.width, page.rect.height)
    pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
    img = Image.open(io.BytesIO(pix.tobytes("png")))
    png = _clean_lineart(img) or pix.tobytes("png")
    return {"ok": True, "message": msg + " and lines sharpened. Use Set scale to match real size.",
            "image": _data_url("image/png", png),
            "width_cm": fw, "height_cm": fh, "scaled": False, "source": "PDF"}

def _thicken(svg_text):
    """CAD line weights are tiny at plan scale; enforce a readable minimum."""
    import re
    m = re.search(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"', svg_text)
    if not m:
        return svg_text
    min_w = max(float(m.group(1)), float(m.group(2))) * 0.0012
    def fix(match):
        return "stroke-width: " + str(max(float(match.group(1)), min_w)) + ";"
    return re.sub(r"stroke-width: ([0-9.]+);", fix, svg_text)

def _from_dxf(raw):
    import ezdxf
    from ezdxf import bbox, units
    from ezdxf.addons.drawing import Frontend, RenderContext, svg, layout, config
    with tempfile.NamedTemporaryFile(suffix=".dxf", delete=False) as tmp:
        tmp.write(raw)
        path = tmp.name
    try:
        try:
            doc = ezdxf.readfile(path)
        except ezdxf.DXFStructureError:
            from ezdxf import recover
            doc, _ = recover.readfile(path)
    finally:
        os.unlink(path)
    msp = doc.modelspace()
    ext = bbox.extents(msp, fast=True)
    if not ext.has_data:
        return _fail("The DXF model space is empty.")
    size = ext.size
    insunits = doc.header.get("$INSUNITS", 0)
    assumed = insunits == 0
    if assumed:
        insunits = units.MM  # most metric architectural drawings are in mm
    to_cm = units.conversion_factor(insunits, units.CM)
    cfg = config.Configuration(background_policy=config.BackgroundPolicy.WHITE,
                               color_policy=config.ColorPolicy.BLACK,
                               lineweight_scaling=0.5)
    backend = svg.SVGBackend()
    Frontend(RenderContext(doc), backend, config=cfg).draw_layout(msp)
    # Keep the SVG page a sane size (max 1000 mm side) with a 10 mm margin.
    k = 1000.0 / max(size.x, size.y)
    pad = 10.0
    page = layout.Page(size.x * k + 2 * pad, size.y * k + 2 * pad, layout.Units.mm, margins=layout.Margins.all(pad))
    svg_text = backend.get_string(page, settings=layout.Settings(fit_page=False, scale=k, min_stroke_width=0.0012))
    svg_text = _thicken(svg_text)
    # Real size of the whole SVG page (drawing + margin), in cm
    w_cm = (size.x + 2 * pad / k) * to_cm
    h_cm = (size.y + 2 * pad / k) * to_cm
    msg = "DXF imported at real scale"
    msg += " (no units in file, assumed mm)." if assumed else "."
    return {"ok": True, "message": msg, "image": _data_url("image/svg+xml", svg_text.encode("utf-8")),
            "width_cm": float(w_cm), "height_cm": float(h_cm), "scaled": True, "source": "DXF"}
::py::
