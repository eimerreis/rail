// Extra line icons for the reading list mockups, same grid and stroke as ../project-overview/icons.js.
const R = {
  inbox:'<path d="M4 13.5 6.6 5.6A1.5 1.5 0 0 1 8 4.5h8a1.5 1.5 0 0 1 1.4 1.1l2.6 7.9V18a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18Z"/><path d="M4 13.5h4.5l1.5 2.5h4l1.5-2.5H20"/>',
  rss:'<path d="M5 5a14 14 0 0 1 14 14M5 11a8 8 0 0 1 8 8"/><circle cx="6" cy="18" r="1.4" fill="currentColor"/>',
  circleCheck:'<circle cx="12" cy="12" r="8.5"/><path d="m8.5 12.2 2.4 2.4 4.6-5"/>',
  save:'<path d="M7 4h10a1 1 0 0 1 1 1v15l-6-4-6 4V5a1 1 0 0 1 1-1Z"/>',
  reader:'<path d="M6 6h12M6 10.5h12M6 15h12M6 19.5h7"/>',
  merge:'<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="15" r="2"/><path d="M6 7v10M6 7c0 5 5 8 10 8"/>'
};
document.body.insertAdjacentHTML('afterbegin',
  '<svg width="0" height="0" style="position:absolute" aria-hidden="true">' +
  Object.entries(R).map(([k,v]) => `<symbol id="${k}" viewBox="0 0 24 24">${v}</symbol>`).join('') + '</svg>');
