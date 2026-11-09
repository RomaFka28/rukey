/* Hero demo: replays the wrong-layout → corrected typing loop.
   No CSS/markup changes required; without JS the static final state stands. */
(function () {
  'use strict';
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  var TYPE_MS = 60, STRIKE_PAUSE = 400, SWAP_PAUSE = 250,
      HOLD = 2000, FADE_MS = 250, LINE_OFFSET = 1700;

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function runLine(line) {
    var word = line.querySelector('.demo-word');
    var result = line.querySelector('.demo-result');
    var caret = line.querySelector('.demo-caret');
    if (!word || !result) return; // guard: leave static final state
    var typed = word.textContent;
    var fixed = result.textContent;
    word.style.transition = 'opacity ' + FADE_MS + 'ms';
    result.style.transition = 'opacity 340ms ease, transform 340ms ease';
    if (caret) caret.style.transition = 'opacity ' + FADE_MS + 'ms';

    function cycle() {
      return sleep(TYPE_MS).then(function () {
        word.classList.remove('is-struck');
        word.textContent = '';
        result.style.opacity = '0';
        result.style.transform = 'translateY(4px)';
        word.style.opacity = '1';
        if (caret) { line.insertBefore(caret, result); caret.style.opacity = '1'; }
        var i = 0;
        function type() {
          if (i >= typed.length) return sleep(STRIKE_PAUSE).then(function () {
            word.classList.add('is-struck');
            return sleep(SWAP_PAUSE).then(function () {
              result.style.opacity = '1';
              result.style.transform = 'translateY(0)';
              if (caret) line.appendChild(caret); // caret belongs after the fix once it appears
              return sleep(HOLD).then(function () {
                word.style.opacity = '0';
                result.style.opacity = '0';
                if (caret) caret.style.opacity = '0';
                return sleep(FADE_MS);
              });
            });
          });
          word.textContent += typed.charAt(i++);
          return sleep(TYPE_MS).then(type);
        }
        return type();
      }).then(cycle);
    }
    cycle();
  }

  var blocks = document.querySelectorAll('.demo');
  for (var i = 0; i < blocks.length; i++) {
    var lines = blocks[i].querySelectorAll('.demo-line');
    for (var j = 0; j < lines.length; j++) {
      if (j > 0) (function (line) { setTimeout(function () { runLine(line); }, LINE_OFFSET); })(lines[j]);
      else runLine(lines[j]);
    }
  }
})();

/* Changelog line: fill from the latest GitHub release so it never goes stale.
   No JS, or any API failure, leaves the static text in the markup. */
(function () {
  'use strict';
  var el = document.getElementById('release');
  if (!el || !window.fetch) return;
  fetch('https://api.github.com/repos/RomaFka28/rukey/releases/latest', {
    headers: { 'Accept': 'application/vnd.github+json' }
  }).then(function (r) {
    return r.ok ? r.json() : null;
  }).then(function (d) {
    if (!d || !d.tag_name) return;
    var date = (d.published_at || '').slice(0, 10);
    el.textContent = d.tag_name + (date ? ' · ' + date : '');
  }).catch(function () { /* static fallback stands */ });
})();

/* Hero menu bar: live local time, formatted like macOS' status clock.
   Visitor's timezone — the bar shows the time wherever they are. */
(function () {
  'use strict';
  var el = document.getElementById('menubar-clock');
  if (!el) return;
  var DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function tick() {
    var d = new Date();
    el.textContent = DAYS[d.getDay()] + ' ' + MONTHS[d.getMonth()] + ' ' + d.getDate() +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }
  tick();
  setInterval(tick, 15000);
})();
