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

def _from_image(raw, ext):
    import pymupdf
    ftype = "jpg" if ext == "jpeg" else ("tiff" if ext == "tif" else ext)
    doc = pymupdf.open(stream=raw, filetype=ftype)
    page = doc[0]
    w, h = page.rect.width, page.rect.height
    if ext in ("png", "jpg", "jpeg", "gif", "webp"):
        mime = "image/jpeg" if ext in ("jpg", "jpeg") else "image/" + ext
        image = _data_url(mime, raw)
    elif ext == "svg":
        image = _data_url("image/svg+xml", raw)
    else:  # bmp / tiff -> png so every browser can show it
        image = _data_url("image/png", page.get_pixmap().tobytes("png"))
    fw, fh = _fit(w, h)
    return {"ok": True, "message": "Image imported. Use Set scale to match real size.", "image": image,
            "width_cm": fw, "height_cm": fh, "scaled": False, "source": ext.upper()}

def _from_pdf(raw):
    import pymupdf
    doc = pymupdf.open(stream=raw, filetype="pdf")
    page = doc[0]
    zoom = min(3.0, 3000.0 / max(page.rect.width, page.rect.height))
    pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
    fw, fh = _fit(page.rect.width, page.rect.height)
    msg = "PDF page 1 imported."
    if doc.page_count > 1:
        msg = "PDF has " + str(doc.page_count) + " pages; page 1 imported."
    return {"ok": True, "message": msg + " Use Set scale to match real size.", "image": _data_url("image/png", pix.tobytes("png")),
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
