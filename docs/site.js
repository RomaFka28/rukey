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
    if (!word || !result) return; // guard: leave static final state
    var typed = word.textContent;
    var fixed = result.textContent;
    word.style.transition = 'opacity ' + FADE_MS + 'ms';
    result.style.transition = 'opacity ' + FADE_MS + 'ms';

    function cycle() {
      return sleep(TYPE_MS).then(function () {
        word.classList.remove('is-struck');
        word.textContent = '';
        result.style.opacity = '0';
        word.style.opacity = '1';
        var i = 0;
        function type() {
          if (i >= typed.length) return sleep(STRIKE_PAUSE).then(function () {
            word.classList.add('is-struck');
            return sleep(SWAP_PAUSE).then(function () {
              result.style.opacity = '1';
              return sleep(HOLD).then(function () {
                word.style.opacity = '0';
                result.style.opacity = '0';
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
