"""Writes the loop-and-trail icon variants as SVG: python3 scripts/make-loop-trail-icons.py design/icon"""
import sys, os, math
out = sys.argv[1]
HEAD = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1c1c1e"/><stop offset="1" stop-color="#050505"/></linearGradient>
  <linearGradient id="rimg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="drop" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="14"/><feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope=".35"/></feComponentTransfer></filter>
  <clipPath id="clip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
  <linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="200" y1="924" x2="924" y2="200"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#d8d8dc"/></linearGradient>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="#000" filter="url(#drop)"/>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#body)"/>
<g clip-path="url(#clip)">
'''
FOOT = '''</g>
<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="url(#rimg)" stroke-width="3"/>
</svg>
'''

def spline(pts):
    p = [pts[0]] + pts + [pts[-1]]
    segs = len(pts) - 1
    def f(t):
        t = min(max(t, 0), 1) * segs
        i = min(int(t), segs - 1); u = t - i
        p0, p1, p2, p3 = p[i], p[i + 1], p[i + 2], p[i + 3]
        return tuple(0.5 * (2*b + (-a + c)*u + (2*a - 5*b + 4*c - d)*u*u + (-a + 3*b - 3*c + d)*u**3)
                     for a, b, c, d in zip(p0, p1, p2, p3))
    return f

def brush(f, width, nib, n=900):
    """Calligraphic stroke: each sample is a dab whose width depends on the travel direction vs. a flat nib.
    Drawn as many overlapping round dabs merged into one path, so self-crossings stay solid."""
    pts = [f(i / n) for i in range(n + 1)]
    dabs = []
    for i, (x, y) in enumerate(pts):
        a, b = pts[max(i - 1, 0)], pts[min(i + 1, n)]
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        w = width(i / n) * (0.42 + 0.58 * abs(math.sin(ang - nib)))
        dabs.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{w / 2:.1f}"/>')
    return '<g fill="url(#ink)">' + "".join(dabs) + "</g>"

def hairline(f, n=300, w=9, opacity=0.55):
    d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in (f(i / n) for i in range(n + 1)))
    return f'<path d="{d}" fill="none" stroke="#fff" stroke-opacity="{opacity}" stroke-width="{w}" stroke-linecap="round"/>'

def bubbles(dots):
    return "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="url(#ink)"/>' for x, y, r in dots)

NIB = math.radians(-35)

LOOP = [(290, 1100), (305, 860), (410, 710), (580, 610), (690, 470), (650, 320), (520, 270), (400, 350),
        (410, 520), (550, 610), (700, 625)]
ECHO = [(350, 1100), (370, 880), (480, 740), (640, 650), (760, 500), (740, 300), (620, 210), (480, 200)]
TRAIL = [(776, 600, 30), (836, 556, 22), (880, 506, 15)]

def ink():
    # Brush line rises from the corner, rolls over itself once, then drifts off as thought bubbles.
    s = [hairline(spline(ECHO), w=8, opacity=0.5)]
    s.append(brush(spline(LOOP), lambda t: 92 - 34 * t, NIB))
    s.append(bubbles(TRAIL))
    return "\n".join(s)

def mono():
    # The same gesture as one even, rounded line.
    s = [hairline(spline(ECHO), w=8, opacity=0.5)]
    s.append(hairline(spline(LOOP), w=64, opacity=1, n=600).replace('stroke="#fff"', 'stroke="url(#ink)"'))
    s.append(bubbles(TRAIL))
    return "\n".join(s)

for name, fn in (("ink", ink), ("mono", mono)):
    with open(os.path.join(out, f"loop-trail-{name}.svg"), "w") as f:
        f.write(HEAD + fn() + "\n" + FOOT)
