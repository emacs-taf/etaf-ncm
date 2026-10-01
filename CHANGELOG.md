# Changelog

All notable user-visible changes to ETAF NCM.

## Unreleased

- The bottom player bar follows the native client's layout and keeps one clear
  line above and below itself: cover, VIP/title and track actions on the left, a
  red play/pause pill with the seek bar in the centre, and reported quality,
  lyrics, queue and volume on the right. Compact bars retain the controls in
  three rows without the cover or quality badge.
- Bar controls stay inside their columns at every width: a control shrinks to
  its content instead of filling the window, so the transport stays centred and
  the tools stay at the right edge. The play/pause glyph spans the pill, so its
  insets match on both sides.
- The sidebar and the narrow chip strip draw the same shared SVG icons as the
  player bar (`star`, `radio`, `disc`, `chart`, `mic` and `clock` joined the
  set), instead of a mix of text glyphs.
- The volume bar follows the native 0–100% scale, so its filled width matches
  the percentage label, and both the seek and volume bars keep the pointed
  position while the backend applies a gesture instead of jumping back.
- The like control flips between the filled and hollow heart as soon as it is
  pressed and returns to its previous state when the request fails.
- `n`, `p`, `SPC`, `<next>`, `<prior>`, `q` and `RET` reach the player in a
  mounted buffer even though the renderer binds them in its own minor-mode map.
  `RET` activates the focused control and falls back to the selected row.
- Bar controls use the shared `etaf-ui-icon' SVG set, so every icon shares one
  optical size and style and none of them changes the row height.
- Click or drag the seek or volume bar to set the position or 0–130% volume,
  with immediate feedback and backend reconciliation; the seek and volume bars
  are the shared `etaf-range' Component and never round the ratio to whole
  blocks. Cover, lyric and queue controls reveal their panes without resetting
  the library or queue window.
- While a song plays, the elapsed label and progress fill move through ETAF's
  retained Host updates instead of republishing the view every second.
- The player background reaches the window edge: the mount viewport uses the window
  body width in pixels, the buffer's default face follows the palette and the
  truncation slot stays blank, so a sub-cell remainder no longer shows as a gap.
- A selected sidebar entry highlights only its text line, while its whole
  two-line cell remains clickable and reachable through TAB/RET.
- Sidebar group labels keep a blank line between the label and the first entry.
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
