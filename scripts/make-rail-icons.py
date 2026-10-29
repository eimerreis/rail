"""Writes the black rail icon variants as SVG: python3 scripts/make-rail-icons.py design/icon"""
import sys, os
out = sys.argv[1]
HEAD = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1c1c1e"/><stop offset="1" stop-color="#050505"/></linearGradient>
  <linearGradient id="rimg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="drop" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="14"/><feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope=".35"/></feComponentTransfer></filter>
  <clipPath id="clip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
'''
BODY = '''</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="#000" filter="url(#drop)"/>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#body)"/>
'''
FOOT = '''<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="url(#rimg)" stroke-width="3"/>
</svg>
'''

def track():
    # Two rails converging on a horizon; sleepers compress with distance.
    vx, vy, by = 512, 250, 924
    L, R = 300, 724
    x_at = lambda x0, y: x0 + (vx - x0) * (by - y) / (by - vy)
    defs = '''  <linearGradient id="fade" gradientUnits="userSpaceOnUse" x1="0" y1="964" x2="0" y2="250"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity=".05"/></linearGradient>
'''
    s = ['<g clip-path="url(#clip)">']
    y, gap = by + 40, 120
    while y > vy + 40 and gap > 6:
        w = 30 * (y - vy) / (by - vy) + 2
        s.append(f'<line x1="{x_at(L - 70, y):.1f}" y1="{y:.1f}" x2="{x_at(R + 70, y):.1f}" y2="{y:.1f}" '
                 f'stroke="url(#fade)" stroke-width="{w:.1f}" stroke-opacity=".35"/>')
        y -= gap
        gap *= 0.78
    for x0 in (L, R):
        s.append(f'<polygon points="{x0 - 24},{by + 40} {x0 + 24},{by + 40} {vx + 1.5},{vy} {vx - 1.5},{vy}" fill="url(#fade)"/>')
    s.append('</g>')
    return defs, "\n".join(s)

def slider():
    # One vertical rail groove with a bright carriage riding at the top.
    defs = '''  <linearGradient id="car" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#b9b9be"/></linearGradient>
  <filter id="glow" x="-100%" y="-50%" width="300%" height="200%"><feGaussianBlur stdDeviation="30"/></filter>
'''
    body = '''<rect x="452" y="214" width="120" height="596" rx="60" fill="#000" stroke="#303034" stroke-width="4"/>
<rect x="470" y="232" width="84" height="250" rx="42" fill="#fff" opacity=".35" filter="url(#glow)"/>
<rect x="470" y="232" width="84" height="250" rx="42" fill="url(#car)"/>'''
    return defs, body

def switch():
    # A straight rail with a branch curving away, like a junction.
    defs = '''  <linearGradient id="main" gradientUnits="userSpaceOnUse" x1="0" y1="960" x2="0" y2="200"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#d1d1d6"/></linearGradient>
  <linearGradient id="branch" gradientUnits="userSpaceOnUse" x1="400" y1="760" x2="680" y2="230"><stop offset="0" stop-color="#8e8e93"/><stop offset="1" stop-color="#3a3a3e"/></linearGradient>
'''
    body = '''<g clip-path="url(#clip)" fill="none" stroke-linecap="round">
  <path d="M400 800 C 400 580, 660 560, 660 250" stroke="url(#branch)" stroke-width="66"/>
  <path d="M400 980 V 250" stroke="url(#main)" stroke-width="66"/>
</g>'''
    return defs, body

for name, fn in (("track", track), ("slider", slider), ("switch", switch)):
    defs, body = fn()
    with open(os.path.join(out, f"rail-{name}.svg"), "w") as f:
        f.write(HEAD + defs + BODY + body + "\n" + FOOT)
