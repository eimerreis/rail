// Extra line icons for the settings mockups, same grid and stroke as ../project-overview/icons.js.
const S = {
  appearance:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M5.5 8h1.5M5.5 11h1.5"/>',
  motion:'<path d="M3 12h9M3 8h5M3 16h5"/><path d="m15 7 5 5-5 5"/>',
  tabs:'<rect x="4" y="4" width="16" height="5" rx="1.5"/><rect x="4" y="11" width="16" height="4" rx="1.5"/><path d="M4 19h10"/>',
  spaces:'<rect x="4" y="3" width="6" height="6" rx="1.6"/><rect x="4" y="11" width="6" height="6" rx="1.6"/><path d="M14 6h6M14 14h6M4 21h6"/>',
  session:'<circle cx="8" cy="9" r="3"/><path d="M3 19c0-3 2.2-5 5-5s5 2 5 5"/><circle cx="17" cy="10" r="2.4"/><path d="M15 14.6c3 .2 5 2 5 4.4"/>',
  folder:'<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
  wrench:'<path d="M14.5 6.5a4 4 0 0 0 5 5L21 13l-8 8-3-3 6.5-6.5M14.5 6.5 13 5a4 4 0 0 0-5.5 5.5L3 15l3 3 4.5-4.5"/>',
  compass:'<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5Z"/>',
  link2:'<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  key:'<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8M16 7l2 2M14 9l2 2"/>',
  dock:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M14 4v16"/>',
  popout:'<rect x="3" y="8" width="13" height="12" rx="2"/><path d="M11 4h9v9M20 4l-8 8"/>',
  arrowleft:'<path d="M19 12H5M11 6l-6 6 6 6"/>',
  enter:'<path d="M20 5v7a3 3 0 0 1-3 3H5M9 11l-4 4 4 4"/>',
  info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/>',
  minus:'<path d="M5 12h14"/>',
  flask:'<path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.7 3h10.6a2 2 0 0 0 1.7-3l-5-9V3M7.5 14h9"/>',
  heart:'<path d="M12 20s-7.5-4.6-7.5-10A4.5 4.5 0 0 1 12 7a4.5 4.5 0 0 1 7.5 3c0 5.4-7.5 10-7.5 10Z"/>'
};
document.body.insertAdjacentHTML('afterbegin',
  '<svg width="0" height="0" style="position:absolute" aria-hidden="true">' +
  Object.entries(S).map(([k,v]) => `<symbol id="${k}" viewBox="0 0 24 24">${v}</symbol>`).join('') + '</svg>');
