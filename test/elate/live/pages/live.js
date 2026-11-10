// Mirrors the fields of `live` into document.title as "key=value;key=value",
// where the Emacs side reads them from the page's state.  A page may define
// update() to refresh fields that have no event.
var live = {};
function report() {
  if (typeof update === 'function') update();
  var parts = [];
  for (var key in live) parts.push(key + '=' + live[key]);
  var title = parts.join(';');
  if (document.title !== title) document.title = title;
}
setInterval(report, 50);
window.addEventListener('load', report);
