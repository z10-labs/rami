// Runs before the page paints (plain script in <head>), so a saved look
// does not flash the default first. Storage may be unavailable: ignore.
try {
  var look = localStorage.getItem('brain.look');
  if (look === 'a' || look === 'b' || look === 'c') document.documentElement.dataset.dir = look;
} catch (e) { /* default look */ }
