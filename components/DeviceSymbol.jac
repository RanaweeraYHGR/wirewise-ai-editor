"""Plan symbol for one device, drawn at the origin (wrap it in a translated <g>). Canvas units are cm."""
def:pub DeviceSymbol(kind: str, label: str, ghost: bool = False, highlight: bool = False) -> JsxElement {
    cls = "dev" + (" dev-ghost" if ghost else "") + (" dev-hl" if highlight else "");
    if kind == "Appliance" {
        w = max(34.0, len(label) * 8.0 + 12.0);
        return <g className={cls}><rect x={-w / 2.0} y="-12" width={w} height="24" fill="#fff" stroke="#111" strokeWidth="2.5" /><text x="0" y="4.5" textAnchor="middle" fontSize="12" fontWeight="700" fontFamily="monospace" fill="#111">{label}</text></g>;
    }
    if kind == "Plug base" {
        # Blue plug with a tag callout so the appliance's outlet is easy to find on the plan
        w = len(label) * 7.6 + 10.0;
        return <g className={cls}>{highlight and <circle r="30" className="dev-ring" />}<rect x="-12" y="-8" width="24" height="16" fill="#2563eb" stroke="#111" strokeWidth="2" /><path d="M -4.5 -3.5 L -4.5 3.5 M 4.5 -3.5 L 4.5 3.5" stroke="#fff" strokeWidth="2" /><g transform="translate(14 -26)"><rect width={w} height="16" fill="#111" /><text x="5" y="12" fontSize="11" fontWeight="700" fontFamily="monospace" fill="#FFD600">{label}</text></g></g>;
    }
    if kind == "Lighting point" {
        return <g className={cls}><circle r="12" fill="#fff" stroke="#111" strokeWidth="2" /><path d="M -8.5 -8.5 L 8.5 8.5 M -8.5 8.5 L 8.5 -8.5" stroke="#111" strokeWidth="2" /></g>;
    }
    if kind.startswith("Socket") {
        return <g className={cls}><rect x="-12" y="-8" width="24" height="16" fill="#FFD600" stroke="#111" strokeWidth="2" /><path d="M -4.5 -3.5 L -4.5 3.5 M 4.5 -3.5 L 4.5 3.5" stroke="#111" strokeWidth="2" /></g>;
    }
    if "switch" in kind.lower() {
        return <g className={cls}><circle r="6" fill="#111" /><path d="M 0 0 L 13 -13" stroke="#111" strokeWidth="2.5" /></g>;
    }
    return <g className={cls}><circle r="11" fill="#FFD600" stroke="#111" strokeWidth="2" /><text x="0" y="4" textAnchor="middle" fontSize="8" fontFamily="monospace" fill="#111">{label}</text></g>;
}
