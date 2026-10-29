"""Writes the black rail-switch icon variants as SVG: python3 scripts/make-switch-icons.py design/icon"""
import sys, os, math
out = sys.argv[1]
HEAD = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1c1c1e"/><stop offset="1" stop-color="#050505"/></linearGradient>
  <linearGradient id="rimg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="drop" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="14"/><feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope=".35"/></feComponentTransfer></filter>
  <clipPath id="clip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
  <linearGradient id="near" gradientUnits="userSpaceOnUse" x1="0" y1="980" x2="0" y2="260"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity=".15"/></linearGradient>
  <linearGradient id="nearDim" gradientUnits="userSpaceOnUse" x1="0" y1="980" x2="0" y2="260"><stop offset="0" stop-color="#8e8e93"/><stop offset="1" stop-color="#8e8e93" stop-opacity=".1"/></linearGradient>
  <linearGradient id="diag" gradientUnits="userSpaceOnUse" x1="100" y1="924" x2="924" y2="100"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#d1d1d6"/></linearGradient>
  <linearGradient id="diagDim" gradientUnits="userSpaceOnUse" x1="100" y1="924" x2="924" y2="100"><stop offset="0" stop-color="#8e8e93"/><stop offset="1" stop-color="#48484c"/></linearGradient>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="#000" filter="url(#drop)"/>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#body)"/>
<g clip-path="url(#clip)">
'''
FOOT = '''</g>
<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="url(#rimg)" stroke-width="3"/>
</svg>
'''

def bez(p0, p1, p2, p3):
    def f(t):
        u = 1 - t
        return tuple(u**3*a + 3*u*u*t*b + 3*u*t*t*c + t**3*d for a, b, c, d in zip(p0, p1, p2, p3))
    return f

def line(p0, p1):
    return lambda t: (p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t)

def ribbon(f, w0, w1, fill, n=120, cut=False):
    """Filled stroke along curve f whose width tapers from w0 to w1 (perspective)."""
    pts = [f(i / n) for i in range(n + 1)]
    left, right = [], []
    for i, (x, y) in enumerate(pts):
        a, b = pts[max(i - 1, 0)], pts[min(i + 1, n)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        l = math.hypot(dx, dy) or 1
        nx, ny = -dy / l, dx / l
        w = (w0 + (w1 - w0) * i / n) / 2
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    poly = left + right[::-1]
    return '<path d="M' + " L".join(f"{x:.1f} {y:.1f}" for x, y in poly) + f'Z" fill="{fill}"' + (' stroke="#0a0a0b" stroke-width="16" paint-order="stroke"' if cut else '') + '/>'

def offset(f, k0, k1, n=160):
    """Curve parallel to f at a side distance tapering from k0 to k1."""
    def g(t):
        h = 1e-3
        a, b = f(max(t - h, 0)), f(min(t + h, 1))
        dx, dy = b[0] - a[0], b[1] - a[1]
        l = math.hypot(dx, dy) or 1
        k = k0 + (k1 - k0) * t
        x, y = f(t)
        return (x - dy / l * k, y + dx / l * k)
    return g

def track(f, gauge0, gauge1, w0, w1, fill, cut=False):
    return "\n".join(ribbon(offset(f, s * gauge0 / 2, s * gauge1 / 2), w0, w1, fill, cut=cut) for s in (-1, 1))

def horizon():
    # Eye-level view: the line runs to the horizon while a second track splits off to the right.
    main = line((400, 1040), (430, 290))
    branch = bez(main(0.18), main(0.34), (540, 480), (830, 360))
    return "\n".join([
        track(branch, 520 - 484 * 0.18, 46, 64, 8, "url(#nearDim)"),
        track(main, 520, 36, 76, 8, "url(#near)", cut=True),
    ])

def turnout():
    # Plan view of a turnout: paired rails on the diagonal, a second pair easing away.
    main = line((20, 1080), (1080, 20))
    branch = bez((250, 850), (430, 670), (520, 480), (560, 40))
    return "\n".join([
        track(branch, 120, 120, 34, 34, "url(#diagDim)"),
        track(main, 120, 120, 34, 34, "url(#diag)", cut=True),
    ])

def sweep():
    # Seen from above at an angle: the track bends right and recedes, the straight line fades away.
    main = bez((300, 1060), (300, 700), (520, 470), (980, 400))
    straight = line((300, 1060), (330, 220))
    return "\n".join([
        track(straight, 260, 70, 40, 10, "url(#nearDim)"),
        track(main, 260, 70, 44, 12, "url(#diag)", cut=True),
    ])

for name, fn in (("horizon", horizon), ("turnout", turnout), ("sweep", sweep)):
    with open(os.path.join(out, f"switch-{name}.svg"), "w") as f:
        f.write(HEAD + fn() + "\n" + FOOT)
