/*!
 * Detail CRM booking embed (P-10). No dependencies, no cookies, no tracking.
 *
 * Paste on any web page:
 *   <div data-detailcrm-book="your-shop-slug"></div>
 *   <script src="https://<app origin>/embed.js" async></script>
 *
 * Optional attributes on the div:
 *   data-link="<token>"   a private booking link (only its services)
 *   data-lead="<token>"   a contact / lead form instead of the booking page
 *   data-title="…"        the frame's accessible title
 * Or put data-slug (and data-link / data-lead) on the <script> tag itself:
 * the frame is inserted right after it.
 *
 * The frame shows <origin>/book/<slug>?embed=1 (or /lead/<token>?embed=1)
 * and grows with its content: the page posts {type:'detailcrm:height',
 * height} to its parent, and only messages from that frame on the app's own
 * origin are honoured. When the page moves to a new step it posts
 * {type:'detailcrm:scroll-top'} and the frame's top is scrolled into view
 * (only when it is above or below the visible area). SPA sites can call
 * window.DetailCRMEmbed.init() after adding a div.
 */
(function () {
  'use strict';

  var MESSAGE_TYPE = 'detailcrm:height';
  var SCROLL_TOP_TYPE = 'detailcrm:scroll-top';
  var MIN_HEIGHT = 320;
  var MAX_HEIGHT = 20000;
  var SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i;
  var TOKEN_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  function findScript() {
    if (document.currentScript && document.currentScript.src) return document.currentScript;
    var scripts = document.getElementsByTagName('script');
    for (var i = scripts.length - 1; i >= 0; i -= 1) {
      if (/\/embed\.js(?:[?#].*)?$/.test(scripts[i].src || '')) return scripts[i];
    }
    return null;
  }

  var script = findScript();
  if (!script) return;
  var origin;
  try {
    origin = new URL(script.src, window.location.href).origin;
  } catch (e) {
    return;
  }

  var frames = [];

  function frameUrl(slug, link, lead) {
    if (lead) return origin + '/lead/' + encodeURIComponent(lead) + '?embed=1';
    var url = origin + '/book/' + encodeURIComponent(slug) + '?embed=1';
    return link ? url + '&link=' + encodeURIComponent(link) : url;
  }

  function createFrame(slug, link, lead, title) {
    if (lead ? !TOKEN_RE.test(lead) : !SLUG_RE.test(slug || '')) return null;
    if (link && !TOKEN_RE.test(link)) link = null;
    var iframe = document.createElement('iframe');
    iframe.src = frameUrl(slug, link, lead);
    iframe.title = title || (lead ? 'Contact form' : 'Book an appointment');
    iframe.loading = 'lazy';
    iframe.setAttribute('scrolling', 'no');
    iframe.style.width = '100%';
    iframe.style.border = '0';
    iframe.style.display = 'block';
    iframe.style.minHeight = MIN_HEIGHT + 'px';
    iframe.style.height = '720px';
    iframe.style.colorScheme = 'normal';
    frames.push(iframe);
    return iframe;
  }

  function init() {
    var targets = document.querySelectorAll('[data-detailcrm-book]:not([data-detailcrm-ready])');
    for (var i = 0; i < targets.length; i += 1) {
      var el = targets[i];
      el.setAttribute('data-detailcrm-ready', '');
      var frame = createFrame(
        el.getAttribute('data-detailcrm-book'),
        el.getAttribute('data-link'),
        el.getAttribute('data-lead'),
        el.getAttribute('data-title'),
      );
      if (frame) el.appendChild(frame);
    }
    var ownSlug = script.getAttribute('data-slug');
    var ownLead = script.getAttribute('data-lead');
    if ((ownSlug || ownLead) && !script.hasAttribute('data-detailcrm-ready')) {
      script.setAttribute('data-detailcrm-ready', '');
      var own = createFrame(
        ownSlug,
        script.getAttribute('data-link'),
        ownLead,
        script.getAttribute('data-title'),
      );
      if (own && script.parentNode) script.parentNode.insertBefore(own, script.nextSibling);
    }
  }

  function frameFor(source) {
    for (var i = 0; i < frames.length; i += 1) {
      if (frames[i].contentWindow === source) return frames[i];
    }
    return null;
  }

  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }

  function scrollFrameTop(frame) {
    var top = frame.getBoundingClientRect().top;
    // Already showing the frame's top: leave the page where it is.
    if (top >= 0 && top < (window.innerHeight || document.documentElement.clientHeight)) return;
    try {
      frame.scrollIntoView({ block: 'start', behavior: reducedMotion() ? 'auto' : 'smooth' });
    } catch (e) {
      frame.scrollIntoView(true);
    }
  }

  window.addEventListener('message', function (event) {
    if (event.origin !== origin) return;
    var data = event.data;
    if (!data || typeof data !== 'object') return;
    if (data.type !== MESSAGE_TYPE && data.type !== SCROLL_TOP_TYPE) return;
    var frame = frameFor(event.source);
    if (!frame) return;
    if (data.type === SCROLL_TOP_TYPE) {
      scrollFrameTop(frame);
      return;
    }
    var height = Number(data.height);
    if (!isFinite(height) || height <= 0) return;
    height = Math.max(MIN_HEIGHT, Math.min(MAX_HEIGHT, Math.ceil(height)));
    frame.style.height = height + 'px';
  });

  window.DetailCRMEmbed = { init: init };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
