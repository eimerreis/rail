"""Writes the bubbly "thought" rail icon variants as SVG: python3 scripts/make-thought-icons.py design/icon"""
import sys, os, math
out = sys.argv[1]
HEAD = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1c1c1e"/><stop offset="1" stop-color="#050505"/></linearGradient>
  <linearGradient id="rimg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="drop" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="14"/><feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope=".35"/></feComponentTransfer></filter>
  <clipPath id="clip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
  <linearGradient id="hi" gradientUnits="userSpaceOnUse" x1="200" y1="924" x2="924" y2="200"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#d1d1d6"/></linearGradient>
  <linearGradient id="lo" gradientUnits="userSpaceOnUse" x1="200" y1="924" x2="600" y2="150"><stop offset="0" stop-color="#8e8e93"/><stop offset="1" stop-color="#3a3a3e"/></linearGradient>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="#000" filter="url(#drop)"/>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#body)"/>
<g clip-path="url(#clip)">
'''
FOOT = '''</g>
<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="url(#rimg)" stroke-width="3"/>
</svg>
'''
CUT = ' stroke="#0a0a0b" stroke-width="26" stroke-linejoin="round" paint-order="stroke"'

def spline(pts):
    """Catmull-Rom through pts, returned as f(t), t in [0,1]."""
    p = [pts[0]] + pts + [pts[-1]]
    segs = len(pts) - 1
    def f(t):
        t = min(max(t, 0), 1) * segs
        i = min(int(t), segs - 1); u = t - i
        p0, p1, p2, p3 = p[i], p[i + 1], p[i + 2], p[i + 3]
        return tuple(0.5 * (2*b + (-a + c)*u + (2*a - 5*b + 4*c - d)*u*u + (-a + 3*b - 3*c + d)*u**3)
                     for a, b, c, d in zip(p0, p1, p2, p3))
    return f

def offset(f, k):
    def g(t):
        h = 1e-3
        a, b = f(max(t - h, 0)), f(min(t + h, 1))
        dx, dy = b[0] - a[0], b[1] - a[1]; l = math.hypot(dx, dy) or 1
        x, y = f(t); kk = k(t) if callable(k) else k
        return (x - dy / l * kk, y + dx / l * kk)
    return g

def ribbon(f, width, fill, cut=False, n=400):
    """Filled stroke with width(t) and round caps."""
    pts = [f(i / n) for i in range(n + 1)]
    L, R = [], []
    for i, (x, y) in enumerate(pts):
        a, b = pts[max(i - 1, 0)], pts[min(i + 1, n)]
        dx, dy = b[0] - a[0], b[1] - a[1]; l = math.hypot(dx, dy) or 1
        w = width(i / n) / 2
        L.append((x - dy / l * w, y + dx / l * w)); R.append((x + dy / l * w, y - dx / l * w))
    w0, w1 = width(0) / 2, width(1) / 2
    d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in L)
    d += f" A{w1:.1f} {w1:.1f} 0 0 0 {R[-1][0]:.1f} {R[-1][1]:.1f} L"
    d += " L".join(f"{x:.1f} {y:.1f}" for x, y in R[::-1])
    d += f" A{w0:.1f} {w0:.1f} 0 0 0 {L[0][0]:.1f} {L[0][1]:.1f}Z"
    return f'<path d="{d}" fill="{fill}"' + (CUT if cut else '') + '/>'

def swell(base, amp, waves, taper=0.0):
    return lambda t: (base - taper * t) * (1 + amp * math.sin(t * waves * 2 * math.pi) ** 2)

def rotate(f, ang, origin):
    c, sn = math.cos(ang), math.sin(ang)
    def g(t):
        x, y = f(t)
        return (origin[0] + x * c - y * sn, origin[1] + x * sn + y * c)
    return g

def meander():
    # Thick paired rails taking a lazy S on their way out to the right.
    main = spline([(320, 1100), (330, 880), (470, 720), (580, 580), (600, 440), (720, 330), (1010, 310)])
    def rail(f, n=300):
        d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in (f(i / n) for i in range(n + 1)))
        return f'<path d="{d}" fill="none" stroke="url(#hi)" stroke-width="68" stroke-linecap="round" stroke-linejoin="round"/>'
    return "\n".join(rail(offset(main, sg * 84)) for sg in (-1, 1))

def loop():
    # One fat line that rolls over itself once before heading off to the right.
    main = spline([(330, 1100), (345, 860), (450, 710), (620, 610), (730, 470), (690, 330),
                   (560, 290), (450, 370), (460, 520), (600, 610), (790, 610), (1010, 540)])
    w = lambda t: 118 - 40 * t
    return ribbon(main, w, "url(#hi)", cut=True, n=700)

def trail():
    # The sweep, thick and round, trailing off into thought bubbles.
    main = spline([(290, 1100), (300, 860), (400, 660), (560, 560)])
    s = [ribbon(main, lambda t: 140 - 30 * t, "url(#hi)")]
    for (x, y, r) in ((690, 470, 52), (800, 365, 38), (880, 270, 26)):
        s.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="url(#hi)"/>')
    return "\n".join(s)

for name, fn in (("meander", meander), ("loop", loop), ("trail", trail)):
    with open(os.path.join(out, f"thought-{name}.svg"), "w") as f:
        f.write(HEAD + fn() + "\n" + FOOT)
