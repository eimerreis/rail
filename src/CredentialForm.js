(function fillRailLogin(username, password, creating) {
  // This function is invoked only by the renderer's native IPC handler. It is
  // never installed on window and does not expose the vault to page scripts.
  const visible = el => !el.disabled && !el.readOnly && !el.closest('[hidden],[inert]') && el.type !== 'hidden' &&
    el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden' &&
    getComputedStyle(el).display !== 'none' && getComputedStyle(el).opacity !== '0';
  const inputs = [...document.querySelectorAll('input')].filter(visible);
  const passwords = inputs.filter(el => el.type === 'password');
  const active = document.activeElement;
  let form = active instanceof HTMLInputElement && visible(active) ? active.form : null;
  if (!form) {
    const forms = [...new Set(passwords.map(el => el.form))];
    if (forms.length > 1) return 'ambiguous';
    form = forms[0] || null;
  }
  const fields = inputs.filter(el => el.form === form);
  if (form && (new URL(form.action || location.href, location.href).origin !== location.origin ||
      form.querySelector('input[formaction],button[formaction]'))) return 'unsafe_form';
  const pw = fields.filter(el => el.type === 'password');
  if (pw.length > 3) return 'ambiguous';
  let targets;
  if (creating) {
    // A change-password form also contains a current password; do not replace it.
    if (pw.some(el => el.autocomplete === 'current-password')) return 'ambiguous';
    targets = pw;
  } else {
    targets = pw.filter(el => el.autocomplete !== 'new-password');
    if (targets.length > 1) return 'ambiguous';
  }
  const userFields = fields.filter(el => ['text','email','tel'].includes(el.type));
  let user = userFields.find(el => el.autocomplete.split(' ').includes('username')) ||
    userFields.find(el => el.type === 'email') ||
    userFields.find(el => /^(user(name)?|email|login)$/i.test(el.name || el.id));
  if (!user && userFields.length === 1) user = userFields[0];
  if (!targets.length && (!user || !username || creating)) return 'no_fields';
  if (targets.length && !password) return 'empty_password';
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  const set = (el,value) => {
    setter.call(el,value);
    el.dispatchEvent(new Event('input',{bubbles:true}));
    el.dispatchEvent(new Event('change',{bubbles:true}));
  };
  // Validate the entire target before touching any field. Never submit the form.
  if (user && username) set(user,username);
  for (const el of targets) set(el,password);
  return targets.length ? 'filled' : 'username_filled';
})
