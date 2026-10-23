#!/usr/bin/env python3
"""Convert simple-icons SVG path data (24x24 viewBox) into SwiftUI Path code."""
import re
import math

CLAUDE_D = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

OPENAI_D = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"

GROK_D = "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"

GEMINI_D = "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"

DEEPSEEK_D = "M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.828-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.003-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.231 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3.101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113.074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.25 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-.156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45"

KIMI_D = "M21.765.351C22.998.351 24 1.353 24 2.586S22.998 4.82 21.765 4.82h-1.974c-.15 0-.26-.12-.26-.26V2.586A2.237 2.237 0 0 1 21.765.35M9.41 13.388l8.447-8.377c.16-.16.07-.471-.14-.471h-4.55s-.1.02-.14.06l-9.099 9.029c-.14.14-.35.02-.35-.21V4.81c0-.15-.1-.27-.221-.27H.22c-.12 0-.22.12-.22.27v18.57c0 .15.1.27.22.27h3.137c.12 0 .22-.12.22-.27v-3.79c0-.08.03-.16.08-.21l2.826-2.796c.07-.07.16-.08.241-.03l7.546 5.551a8.9 8.9 0 0 0 4.018 1.493c.12.01.23-.11.23-.27V19.76c0-.14-.08-.25-.19-.26a5.8 5.8 0 0 1-2.355-.942l-6.533-4.73c-.14-.09-.15-.32-.03-.441"

NUM = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def tokenize(d):
    """Arc-aware lexer: arc flags are single chars that may be glued to the
    next number (e.g. "a2.5 2.5 0 011.4-.4"), so they are consumed by position
    rather than by the number regex."""
    out = []
    i = 0
    n = len(d)
    cmd = None

    def skip_separators(i):
        while i < n and d[i] in ", \t\n":
            i += 1
        return i

    while True:
        i = skip_separators(i)
        if i >= n:
            break
        if d[i].isalpha():
            cmd = d[i]
            i += 1
        elif cmd is None:
            raise ValueError(f"path must start with a command: {d[:12]!r}")
        elif cmd in "Mm":
            cmd = "L" if cmd == "M" else "l"  # implicit repeat

        out.append(cmd)
        for k in range(ARITY[cmd.upper()]):
            i = skip_separators(i)
            if cmd.upper() == "A" and k in (3, 4):
                if i >= n or d[i] not in "01":
                    raise ValueError(f"bad arc flag at {i}: {d[i:i+8]!r}")
                out.append(float(d[i]))
                i += 1
                continue
            m = NUM.match(d, i)
            if not m:
                raise ValueError(f"bad number at {i}: {d[i:i+12]!r}")
            out.append(float(m.group()))
            i = m.end()
    return out


def arc_to_cubics(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """Endpoint to center parameterization, then split into <=90 degree cubics."""
    if rx == 0 or ry == 0:
        return [("L", x2, y2)]
    phi = math.radians(phi_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cosp * dx2 + sinp * dy2
    y1p = -sinp * dx2 + cosp * dy2
    rx, ry = abs(rx), abs(ry)
    lam = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(0, num / den)) if den else 0
    if large == sweep:
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx
    cx = cosp * cxp - sinp * cyp + (x1 + x2) / 2
    cy = sinp * cxp + cosp * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        norm = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1, min(1, dot / norm)))
        if ux * vy - uy * vx < 0:
            a = -a
        return a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    segs = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2))))
    delta = dtheta / segs
    t = 4 / 3 * math.tan(delta / 4)
    cmds = []
    th = theta1
    for _ in range(segs):
        cos1, sin1 = math.cos(th), math.sin(th)
        cos2, sin2 = math.cos(th + delta), math.sin(th + delta)

        def pt(c, s):
            return (cx + rx * cosp * c - ry * sinp * s,
                    cy + rx * sinp * c + ry * cosp * s)

        def dpt(c, s):
            return (-rx * cosp * s - ry * sinp * c,
                    -rx * sinp * s + ry * cosp * c)

        p1 = pt(cos1, sin1)
        p2 = pt(cos2, sin2)
        d1 = dpt(cos1, sin1)
        d2 = dpt(cos2, sin2)
        c1 = (p1[0] + t * d1[0], p1[1] + t * d1[1])
        c2 = (p2[0] - t * d2[0], p2[1] - t * d2[1])
        cmds.append(("C", c1[0], c1[1], c2[0], c2[1], p2[0], p2[1]))
        th += delta
    return cmds


def parse(d):
    """Yield absolute commands: (M x y) (L x y) (C x1 y1 x2 y2 x y) (Z)."""
    tokens = tokenize(d)
    i = 0
    cmd = None
    cx = cy = sx = sy = 0.0
    pcx = pcy = None  # previous cubic control for S
    out = []
    while i < len(tokens):
        if isinstance(tokens[i], str):
            cmd = tokens[i]
            i += 1
        else:
            # implicit repeat; m/M repeats as l/L
            if cmd in ("M", "m"):
                cmd = "L" if cmd == "M" else "l"

        def take(n):
            nonlocal i
            vals = tokens[i:i + n]
            if len(vals) != n or any(isinstance(v, str) for v in vals):
                raise ValueError(f"expected {n} numbers for {cmd} at token {i}")
            i += n
            return vals

        if cmd in ("M", "m"):
            x, y = take(2)
            if cmd == "m":
                x += cx
                y += cy
            cx, cy, sx, sy = x, y, x, y
            out.append(("M", x, y))
            pcx = pcy = None
        elif cmd in ("L", "l"):
            x, y = take(2)
            if cmd == "l":
                x += cx
                y += cy
            cx, cy = x, y
            out.append(("L", x, y))
            pcx = pcy = None
        elif cmd in ("H", "h"):
            (x,) = take(1)
            if cmd == "h":
                x += cx
            cx = x
            out.append(("L", x, cy))
            pcx = pcy = None
        elif cmd in ("V", "v"):
            (y,) = take(1)
            if cmd == "v":
                y += cy
            cy = y
            out.append(("L", cx, y))
            pcx = pcy = None
        elif cmd in ("C", "c"):
            x1, y1, x2, y2, x, y = take(6)
            if cmd == "c":
                x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
            out.append(("C", x1, y1, x2, y2, x, y))
            pcx, pcy = x2, y2
            cx, cy = x, y
        elif cmd in ("S", "s"):
            x2, y2, x, y = take(4)
            if cmd == "s":
                x2 += cx; y2 += cy; x += cx; y += cy
            x1 = 2 * cx - pcx if pcx is not None else cx
            y1 = 2 * cy - pcy if pcy is not None else cy
            out.append(("C", x1, y1, x2, y2, x, y))
            pcx, pcy = x2, y2
            cx, cy = x, y
        elif cmd in ("Q", "q"):
            x1, y1, x, y = take(4)
            if cmd == "q":
                x1 += cx; y1 += cy; x += cx; y += cy
            c1x, c1y = cx + 2 / 3 * (x1 - cx), cy + 2 / 3 * (y1 - cy)
            c2x, c2y = x + 2 / 3 * (x1 - x), y + 2 / 3 * (y1 - y)
            out.append(("C", c1x, c1y, c2x, c2y, x, y))
            pcx, pcy = x1, y1  # quadratic reflection point for T
            cx, cy = x, y
        elif cmd in ("T", "t"):
            x, y = take(2)
            if cmd == "t":
                x += cx
                y += cy
            qx = 2 * cx - pcx if pcx is not None else cx
            qy = 2 * cy - pcy if pcy is not None else cy
            c1x, c1y = cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy)
            c2x, c2y = x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y)
            out.append(("C", c1x, c1y, c2x, c2y, x, y))
            pcx, pcy = qx, qy
            cx, cy = x, y
        elif cmd in ("A", "a"):
            rx, ry, rot, large, sweep, x, y = take(7)
            if cmd == "a":
                x += cx
                y += cy
            for c in arc_to_cubics(cx, cy, rx, ry, rot, int(large), int(sweep), x, y):
                out.append(c)
            cx, cy = x, y
            pcx = pcy = None
        elif cmd in ("Z", "z"):
            out.append(("Z",))
            cx, cy = sx, sy
            pcx = pcy = None
        else:
            raise ValueError(f"unsupported command {cmd}")
    return out


def swift_lines(cmds):
    lines = []
    f = lambda v: f"{v:.4f}".rstrip("0").rstrip(".") or "0"
    for c in cmds:
        if c[0] == "M":
            lines.append(f"        p.move(to: CGPoint(x: {f(c[1])}, y: {f(c[2])}))")
        elif c[0] == "L":
            lines.append(f"        p.addLine(to: CGPoint(x: {f(c[1])}, y: {f(c[2])}))")
        elif c[0] == "C":
            lines.append(
                f"        p.addCurve(to: CGPoint(x: {f(c[5])}, y: {f(c[6])}), "
                f"control1: CGPoint(x: {f(c[1])}, y: {f(c[2])}), "
                f"control2: CGPoint(x: {f(c[3])}, y: {f(c[4])}))")
        elif c[0] == "Z":
            lines.append("        p.closeSubpath()")
    return lines


def emit_shape(name, d, comment):
    cmds = parse(d)
    body = swift_lines(cmds)
    # split into chunks of 90 statements so the type checker stays fast
    chunks = [body[i:i + 90] for i in range(0, len(body), 90)]
    fns = []
    for idx, chunk in enumerate(chunks):
        fns.append(f"    private func segment{idx}(_ p: inout Path) {{\n" + "\n".join(chunk) + "\n    }")
    calls = "\n".join(f"        segment{i}(&p)" for i in range(len(chunks)))
    return f"""/// {comment}
/// Exact vector traced in a 24x24 grid; scaled to fit the given rect.
struct {name}: Shape {{
    func path(in rect: CGRect) -> Path {{
        var p = Path()
{calls}
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 12 * scale,
                                             y: rect.midY - 12 * scale))
        return p.applying(transform)
    }}

{chr(10).join(fns)}
}}"""


HEADER = """import SwiftUI

// Generated by scratchpad/svg2swift.py from the official simple-icons vectors
// (plus the LobeHub grok vector, all viewBox 0 0 24 24). Do not edit the coordinates by
// hand; rerun the script instead.

/// Which vector mark a provider draws. Marks are template style, single colour,
/// tinted with the provider accent.
enum BrandMarkKind {
    case claude
    case openAI
    case grok
    case gemini
    case deepseek
    case kimi
    case generic
}

/// Draws the mark for a provider at a given point size.
struct BrandMark: View {
    let kind: BrandMarkKind
    var size: CGFloat = 18
    var tint: Color

    var body: some View {
        Group {
            switch kind {
            case .claude:
                ClaudeMarkShape().fill(tint, style: FillStyle(eoFill: true))
            case .openAI:
                OpenAIMarkShape().fill(tint, style: FillStyle(eoFill: true))
            case .grok:
                GrokMarkShape().fill(tint, style: FillStyle(eoFill: true))
            case .gemini:
                GeminiMarkShape().fill(tint, style: FillStyle(eoFill: true))
            case .deepseek:
                DeepSeekMarkShape().fill(tint, style: FillStyle(eoFill: true))
            case .kimi:
                KimiMarkShape().fill(tint, style: FillStyle(eoFill: true))
            case .generic:
                Circle().strokeBorder(tint, lineWidth: size * 0.09)
            }
        }
        .frame(width: size, height: size)
    }
}
"""

claude_shape = emit_shape("ClaudeMarkShape", CLAUDE_D, "Claude's official sunburst mark.")
openai_shape = emit_shape("OpenAIMarkShape", OPENAI_D, "OpenAI's official knot mark, arcs converted to cubic Beziers.")
grok_shape = emit_shape("GrokMarkShape", GROK_D, "Grok's diagonal-swoosh mark (LobeHub icons trace).")
gemini_shape = emit_shape("GeminiMarkShape", GEMINI_D, "Google Gemini's four-point sparkle, quadratics converted to cubics.")
deepseek_shape = emit_shape("DeepSeekMarkShape", DEEPSEEK_D, "DeepSeek's whale mark.")
kimi_shape = emit_shape("KimiMarkShape", KIMI_D, "Moonshot's KIMI wordmark.")

out = (HEADER + "\n" + claude_shape + "\n\n" + openai_shape + "\n\n" + grok_shape
       + "\n\n" + gemini_shape + "\n\n" + deepseek_shape + "\n\n" + kimi_shape + "\n")
path = "/Users/hojaejung/Desktop/UL Engineering/notch-peek/Sources/NotchPeek/Views/BrandMarks.swift"
with open(path, "w") as fh:
    fh.write(out)
print(f"wrote {path}: {len(out.splitlines())} lines")
