/* PRODUCT §2.1 Sign in — shown whenever TDLib is not authorizationStateReady.
 *
 * A visitor who arrived on a public link (§2.13) gets the same screen with the
 * destination named: TDLib refuses every chat read before authorization, so
 * the link cannot be honoured until this is done.
 */
import { h, button, field, replace } from '../../vendor/house-pour.js';
import { authErrorCopy } from '../td.js';
import { ENTRY_LABEL, ENTRY_NOTE } from '../demo/mode.js';
import { contactMailLink } from './safety.js';

export function render(app) {
  const root = h('div.signin');
  const stage = h('div');
  const dest = app.pendingDest;
  const intro = h('div',
    h('div.wordmark', 'tgsocial'),
    h('h1', 'Your Telegram, as a feed.'),
    h('p.muted', dest
      ? `Sign in to see @${dest.username}.`
      : 'Sign in with the Telegram account you already have. Nothing is stored anywhere but Telegram and this device.'),
  );
  /**
   * §2.22's entry point, and the §2.19 footer under it. Both sit OUTSIDE the
   * card, which still begins at `PHONE NUMBER` and ends at the one gold
   * button, so the primary action keeps the only fill on the screen.
   */
  const demoHost = h('div.signin-demo');
  root.append(
    h('div.card', intro, stage),
    demoHost,
    h('p.muted.small.signin-contact', contactMailLink()),
  );

  let shown = null;
  let demoShown = null;
  /**
   * §2.1 — step 1 only. On the code, 2FA, other-device and registration steps
   * the screen has one job: once a number is in flight nobody can fall into
   * the demo by mistake, which is half of §2.22's answer to "could a real user
   * mistake this for broken sign-in".
   */
  const paintDemo = (on) => {
    if (demoShown === on) return;
    demoShown = on;
    if (!on) {
      replace(demoHost);
      return;
    }
    replace(demoHost,
      button(ENTRY_LABEL, { style: 'ghost', onClick: () => app.enterDemo() }),
      h('p.muted.small', ENTRY_NOTE),
    );
  };
  const show = (key, make) => {
    if (shown === key) return; // never replace a form the user may be typing in
    shown = key;
    replace(stage, make());
  };
  const usePhone = () => show('phone', () => phoneStep(app));
  const paint = () => {
    const state = app.td.authState?.['@type'] ?? null;
    paintDemo(!state || state === 'authorizationStateWaitPhoneNumber' || state === 'authorizationStateWaitTdlibParameters');
    if (!app.td.client) show('starting', () => h('p.muted', 'Starting TDLib…'));
    else if (state === 'authorizationStateWaitCode') show('code', () => codeStep(app, usePhone));
    else if (state === 'authorizationStateWaitPassword') show('password', () => passwordStep(app));
    else if (state === 'authorizationStateWaitOtherDeviceConfirmation') show('qr', () => qrStep(app));
    else if (state === 'authorizationStateWaitRegistration') show('registration', () => registrationStep(app, usePhone));
    else if (state === 'authorizationStateLoggingOut' || state === 'authorizationStateClosing') show('out', () => h('p.muted', 'Signing out…'));
    else if (state === 'authorizationStateClosed') show('closed', () => h('p.muted', 'Telegram session closed. Reload to start again.'));
    else show('phone', () => phoneStep(app));
  };
  paint();
  app.onLeave(app.td.on('auth', paint));
  return root;
}

function submitOn(form, fn) {
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    fn();
  });
}

function phoneStep(app) {
  const { wrap, input } = field('Phone number', { type: 'tel', autocomplete: 'tel', inputmode: 'tel', placeholder: '+1 604 555 0199', required: true });
  const btn = button('Send Code', { style: 'primary', type: 'submit' });
  const form = h('form', wrap, btn);
  submitOn(form, async () => {
    const phone = input.value.replace(/[^\d+]/g, '');
    if (!phone) return;
    btn.disabled = true;
    try {
      await app.td.setPhone(phone);
    } catch (err) {
      app.toast(authErrorCopy(err), 'bad');
    } finally {
      btn.disabled = false;
    }
  });
  return form;
}

function codeStep(app, usePhone) {
  const { wrap, input } = field('Code', { type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', pattern: '[0-9]*', maxlength: 6, placeholder: '12345', required: true });
  const btn = button('Sign In', { style: 'primary', type: 'submit' });
  // setAuthenticationPhoneNumber is accepted again while in WaitCode, so "back" is just the phone form
  const back = button('Use another number', { style: 'ghost', onClick: usePhone });
  const form = h('form', wrap, btn, back);
  submitOn(form, async () => {
    const code = input.value.trim();
    if (!code) return;
    btn.disabled = true;
    try {
      await app.td.checkCode(code);
    } catch (err) {
      app.toast(authErrorCopy(err), 'bad');
    } finally {
      btn.disabled = false;
    }
  });
  return form;
}

function passwordStep(app) {
  const hint = app.td.authState?.password_hint;
  const { wrap, input } = field('Password', { type: 'password', autocomplete: 'current-password', required: true });
  const btn = button('Unlock', { style: 'primary', type: 'submit' });
  const form = h('form', wrap, hint ? h('p.muted.small', hint) : null, btn);
  submitOn(form, async () => {
    const password = input.value;
    if (!password) return;
    btn.disabled = true;
    try {
      await app.td.checkPassword(password);
    } catch (err) {
      app.toast(authErrorCopy(err), 'bad');
    } finally {
      btn.disabled = false;
    }
  });
  return form;
}

function qrStep(app) {
  const link = app.td.authState?.link ?? '';
  return h('div',
    h('label.field', 'Confirm on another device'),
    h('p.muted', 'Open Telegram on a signed-in device and scan or paste this link.'),
    h('div.pre', link),
  );
}

function registrationStep(app, usePhone) {
  return h('div',
    h('h2', 'Sign up in Telegram first.'),
    h('p.muted', 'tgsocial never creates Telegram accounts. Make one in the Telegram app, then come back.'),
    button('Use another number', { style: 'ghost', onClick: usePhone }),
  );
}
