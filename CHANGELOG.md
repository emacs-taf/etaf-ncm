# Changelog

All notable user-visible changes to ETAF NCM.

## Unreleased

- The seek and volume meters draw a one-pixel rule again. `etaf-range` now
  honors `:bar-height` on graphical frames, so an unset value made both bars
  six pixels tall; the player asks for the hairline its native-style bar
  reserves inside the full-height hit row.
- Installing from the package archive now compiles every module: the entry
  resolves its `lisp/` directory from the file being compiled, so an
  installation started from a script cannot point the compiler at the script's
  own directory.

- The NetEase backend now ships inside this package under `backends/netease/`
  and no longer needs a Pi skill, `pi-skill`, or a separate `netease-music-cli`
  checkout. Node.js, Python 3 and mpv are the system tools; `qrencode` is
  optional and only used by QR sign-in. The login, queue and saved queues move
  to `${XDG_STATE_HOME:-~/.local/state}/netease-music`; the client passes the
  state directory to the backend, so both always agree.
  `etaf-ncm-skill-directory` became `etaf-ncm-backend-directory`, the client
  keyword `:skill-directory` became `:backend-directory`, and
  `etaf-ncm-doctor` reports the tools, the bundled scripts and the login state.

- `?` shows searchable, read-only key help inside the player without splitting
  its window or changing playback. Escape and backdrop dismissal restore the
  opening focus; command execution stays in `M-x etaf-palette`. The volume
  `=` alias is included alongside `+` in the effective binding list.
- The window and the client are separate now.  `q` (or `etaf-ncm-close`) closes
  the window and leaves the backend playing, like a client minimized to the
  tray; `Q` (or `etaf-ncm-quit`) quits the client: it stops the backend player
  before the window closes.  Exiting Emacs stops a player the app started, so
  mpv never keeps playing as an orphan, while playback the CLI started is left
  alone.
- Picking a song shows it at once: the playing marker, the title, the artist,
  the length and the queue count move to the picked row before the backend
  answers.  A status poll that still reports the previous song no longer moves
  the marker back while the play command is in flight, so double-pressing a
  row no longer flashes another song's marker on the way.
- The selection and playing highlight bars slide onto their new row on ETAF's
  shared animation clock instead of jumping, and the cursor follows the bar
  while it moves.
- The player keeps its own clear lines: one row of top padding inside each
  panel and one closing padding row inside the player bar, so a hosting
  window needs no inset and the surface stays one background at every size.
- The player lays out for the region it is given: its buffer window standing
  alone, or the window, pane or tab that embeds it.  Breakpoints, column and
  row budgets follow that region through `etaf-viewport` instead of reading
  the buffer's Emacs window, so an embedded player resizes with its host
  exactly like a standalone one.
- Every control is keyboard-operable through ETAF's shared navigation instead
  of an app keymap. `TAB` / `S-TAB` move between regions, arrows and
  `C-n` / `C-p` / `C-b` / `C-f` move inside the sidebar, chips, tabs, queue and
  player controls, the focused sliders step with `←` / `→`, and `?` opens a
  palette of all keys and controls. List navigation keys (`↑` / `↓`, `RET`,
  `Home` / `End`, `PageUp` / `PageDown`) act on the focused song list, and the
  cursor follows its selection. `etaf-ncm-mode-map` is removed; customize keys
  through the view instead.

- The player adapts to the window as one planned system instead of fixed
  breakpoints and squeezed parts. The tiers (`wide`, `medium`, `narrow`) are
  still there, but their thresholds are derived from the columns the header
  and a row actually need, the row variant is chosen by fit, and the chip
  strip shrinks its gaps and chips so no library falls off a narrow window.
  A narrow list folds the artist into the name cell and drops the album and
  badge in a defined order; a playlist or song name never disappears, and a
  name column always keeps its minimum width.
- The player bar sits one padding row above its content and none below: the
  window's echo area is the single clear line under it, so the content ends
  one row from the window edge. The top strip above the panels is gone; the
  sidebar, list header and lyric panel each keep their own one-row inset.
- The library page fills every row the window budget leaves after the header,
  the chip strip, the pane switch and the player bar; the wheel scrolls the
  window through all loaded rows and the footer labels the visible range and
  the loaded total (dropped only in a very short frame).
- The login row is now a status line: an account icon with the nickname and a
  `VIP` tag when signed in, `未登录 · L 登录` when not, and pressing it starts
  the same sign-in as `L`. The green state square is gone; the glyph rail
  shows the account icon alone with its state in the tooltip.
- The lyric and queue tabs use a tinted pill for the active tab instead of an
  underline, matching the compact pane switch.
- Header actions keep their intrinsic width, so `换一批` and `播放全部` are
  never clipped into shorter words at the wide-layout boundary.
- One type scale replaces the scattered small sizes: the frame default for
  anything a reader acts on, and `etaf-ncm-font-meta` (about 11 pt on a 14 pt
  frame) for subtitles, counters, hints and credits. Emphasis uses weight, and
  a short frame drops the subtitle and the hint rather than shrinking text.
- Cover art follows track changes immediately after the image is available,
  including consecutive songs with equally sized artwork and cached revisits.
  Playback status corrects an earlier queue reply's cover without waiting for
  the queue to refresh again.
- Opening the minibuffer (`M-x`, a completion popup or the player's own
  prompts) no longer shrinks the library page, the panes or the player bar to
  the lines the prompt borrows. The player keeps the layout it committed for
  the window and returns to the full view unchanged once the prompt closes.
- The selection and playing highlight are two overlay bars moved as retained
  host geometry. Moving the selection or changing the playing song no longer
  repaints the list plane; a row update costs content only, so a long list
  stays responsive.
- Library rows compose in flow order instead of absolute offsets: a row paint
  change (selection or playing marker) no longer re-renders the whole list
  plane, so selecting in a long library stays cheap. Wide and compact layouts
  paint identically.
- The mouse wheel scrolls a visible library window one row per tick without
  moving the selection; `j`/`k`, `RET` and clicks still select and bring the
  row back into view. Queue scrolling and its hit test are unchanged.
- Lyrics and downloaded cover art persist across restarts in a
  `media-cache.sqlite` SQLite database built with ETAF DB beside the sidebar
  snapshot. A cache hit publishes the lyric or the indexed cover file without a
  backend request; a changed cover URL or a missing file refreshes normally.
  Function clients without a snapshot path keep both in memory only.
- Sidebar libraries restore a private local snapshot before mounting, so
  cached navigation does no network or disk work even after restarting Emacs.
  Periodic refresh deduplicates in-flight requests, skips unchanged replies,
  preserves song/scroll identities and keeps old data when offline.
- Library rows retain viewport-sized slots and row-number bindings across
  scrolling and section changes. The playing glyph shares a text Host with
  the row number rather than using a hidden positioned overlay.
- Volume uses a retained numeric source for optimistic updates and replies,
  keeping the slider callback stable instead of rebuilding the player.
- Compact list/lyrics/queue tabs form one left-aligned, equal-width row.
  Only the visible pane is highlighted; the player follows without a blank row.
- Double-click starts directly on the selected song using the loaded list,
  rather than playing its first entry and issuing a later jump.
- Sidebar highlighting and library rows have independent drawing areas;
  switching cached lists updates retained text and colours.
- Row download and queue actions are visible inline; the options popup is
  removed. The `d` key downloads the selection. A downloaded row carries a
  check mark, and the backend plays the local file on the next queue instead of
  fetching a fresh stream URL and never lets the URL keepalive replace it.  The
  registry is the backend's `downloads` truth, so files downloaded from the
  command line show the same mark after `g`; downloading a song that is already
  local refreshes the file in place.
- Every interaction the app documents is now retained: play/pause, the
  heart, shuffle, repeat, the status message, the lyrics/queue switch, the
  compact pane switch and the library selection read their own reactive
  sources inside Host bindings, and measuring the scripted fixture gives
  11-90 ms with zero whole-candidate renders in either order.  Loading a new
  library now repaints through retained row slots: each visible row keeps its
  source across switches, and its title, meta, badge, time and play marker are
  prepared updates, so the library switch itself publishes no whole-candidate
  render.  The scripted benchmark reports about 300 ms for the first switch
  and about 144 ms once the row scenes exist, down from about 600 ms; the
  remaining cost is the per-row retained boundary render, which the framework
  still does once per row.  The library, the two aside variants and the player bar are
  absolutely positioned panels of the root stage; keep their anchors there
  when adding a panel whose Hosts must update in place.
- Pressing `SPC` or the play pill with an empty queue plays the selected song
  instead of sending a toggle the backend cannot act on.  Selecting a row and
  pressing play now starts that song, and the play/pause button no longer
  flashes back to paused.
- Every row stays within the frame's line height, so the canvas is never taller
  than the window and the bottom bar is not clipped. Glyphs that fell back to a
  taller font (`♪`, `♫`, `▶︎` with its variation selector, `↻`, `●`, `…`) are
  replaced with the shared SVG icons, plain text or a block; the GUI scenario
  now fails a checkpoint when any line exceeds the line height or a resize
  leaves the canvas taller than the window.
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
