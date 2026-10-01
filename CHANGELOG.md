# Changelog

All notable user-visible changes to ETAF NCM.

## Unreleased

- Queue windows fit the panel height, show the visible range and backend total,
  and let the wheel reach every loaded entry. Scrolling over the panel leaves
  the library selection alone; playback changes centre the queue again.
- Library loads request 1000 rows by default through `etaf-ncm-list-limit`,
  retaining `etaf-ncm-fetch-limit` as a lower bound. Footers preserve backend
  totals, label partial loads, and show one-based ranges across all loaded rows.
- Playing a song in daily recommendations, liked songs or private FM queues
  that library before jumping to the song. `播放全部` appears only where
  whole-list playback is supported.
- Repeat controls and help now say `列表循环`, matching the backend's list loop.
- The lyric window fits the panel height, including translations, while keeping
  the current line emphasized.
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
- A list update re-renders only the rows whose data changed: the view passes
  stable callbacks instead of a fresh closure per row.

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
