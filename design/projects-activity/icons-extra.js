// Extra line icons for the Projects + Activity mockups, same grid and stroke as ../project-overview/icons.js.
const E = {
  activity:'<circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="18" r="2"/><path d="M6 8v8M18 16V9a2 2 0 0 0-2-2h-4m2-2.5L11.5 7 14 9.5"/>',
  list:'<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r=".9" fill="currentColor"/><circle cx="4.5" cy="12" r=".9" fill="currentColor"/><circle cx="4.5" cy="18" r=".9" fill="currentColor"/>',
  merge:'<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="12" r="2"/><path d="M6 7v10M6 7c0 4 4 5 10 5"/>',
  conflict:'<path d="M12 3v6M12 15v6M5 9l3 3-3 3M19 9l-3 3 3 3"/>',
  arrowr:'<path d="M5 12h14M13 6l6 6-6 6"/>',
  sort:'<path d="M7 5v14M4 16l3 3 3-3M17 19V5M14 8l3-3 3 3"/>',
  ret:'<path d="M20 5v7a3 3 0 0 1-3 3H5M9 11l-4 4 4 4"/>',
  eye:'<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.8"/>',
  bell:'<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15ZM10 20.5h4"/>'
};
document.body.insertAdjacentHTML('afterbegin',
  '<svg width="0" height="0" style="position:absolute" aria-hidden="true">' +
  Object.entries(E).map(([k,v]) => `<symbol id="${k}" viewBox="0 0 24 24">${v}</symbol>`).join('') + '</svg>');

// Hash-routed view switch: #projects (default) or #activity.
const setView = () => {
  const v = location.hash === '#activity' ? 'activity' : 'projects';
  document.body.dataset.view = v;
  document.querySelectorAll('.navrow[data-to]').forEach(b => b.dataset.to === v ? b.setAttribute('aria-current','page') : b.removeAttribute('aria-current'));
  document.querySelector('.url b').textContent = v === 'activity' ? 'Work · Activity' : 'Work · Projects';
  document.querySelector('.url use').setAttribute('href', v === 'activity' ? '#activity' : '#grid');
};
document.addEventListener('click', e => { const b = e.target.closest('.navrow[data-to]'); if (b) location.hash = b.dataset.to; });
addEventListener('hashchange', setView);
addEventListener('DOMContentLoaded', setView);
