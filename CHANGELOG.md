# Changelog

All notable user-visible changes to ETAF NCM.

## Unreleased

- A press on the row that is already selected plays it, so starting a song no
  longer depends on a second click arriving inside a timing window.
- Playback commands show their effect immediately: the play/pause state, the
  volume, the shuffle and repeat flags and the message line change before the
  backend answers, and the reply reconciles them.
- Library switches use a cached list when one exists and refresh it in the
  background; a mounted player warms the lists it has not seen yet, and
  `etaf-ncm-library-refresh-interval` (five minutes) keeps cached lists fresh.
  `etaf-ncm-prefetch-libraries` turns the background warming off.
- A playing second updates the elapsed label and the progress meter in place
  instead of republishing the whole view.

## 0.1.0

First release.

- Mount the player with `etaf-ncm-open`; the sidebar covers the daily
  recommendation, private FM, liked songs, playlists, saved albums and artists,
  charts, podcasts and recent plays, plus song search with a playlist scope.
- Play a row or a whole list, pause, skip, stop, set volume, seek, shuffle,
  repeat, like and unlike, and jump anywhere in the queue.
- Lyric panel with the current line highlighted and translations next to it;
  panel switches between lyric and queue.
- Dark and light palettes with one key, published as ETAF UI theme tokens.
- Headless sessions (`etaf-ncm-create` + actions + `etaf-ncm-state`) and a
  pluggable client (`etaf-ncm-client-factory`) for scripts and tests.
- The layout follows the window width: a wide frame keeps all three columns, a
  medium one keeps a glyph-only library rail with one visible pane, and a narrow
  one stacks the header and shows one full-width pane. `etaf-ncm-wide-columns`
  and `etaf-ncm-medium-columns` set the thresholds, `v` switches the visible
  pane and `etaf-ncm-show-pane` does it from Lisp.
- Runnable demo on a scripted library: `M-x etaf-ncm-demo-open`.
