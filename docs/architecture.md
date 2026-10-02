# ETAF NCM architecture

ETAF NCM is one ETAF application built on the Ebox layout engine and the shared
ETAF UI controls. It is an interface over the `netease-music` backend, not a
player: mpv owns playback, the backend owns queue and login state, the package
owns presentation and interaction.

## Modules

| File | Responsibility |
| --- | --- |
| `etaf-ncm-theme.el` | Palettes, `etaf-ncm-color`, `etaf-ncm-theme-defaults` and the mode selection. No ETAF dependency beyond the token plist it produces. |
| `etaf-ncm-service.el` | The backend client: request translation to skill commands, child processes, timeouts, cookie injection, reply decoding, queue state reading, LRC parsing. |
| `etaf-ncm-model.el` | One session: reactive sources, library loading, search, every playback and queue action, selection and paging, status polling, dispose. |
| `etaf-ncm-views.el` | Pure presentational Components: sidebar, header, list, lyrics, queue, aside, player bar. They receive values and callbacks only. |
| `etaf-ncm-app.el` | The `etaf-ncm-app` Component (session lifecycle, theme provision, the only place that reads reactive sources), its keymap, its commands and the buffer entry points. |
| `etaf-ncm.el` | The package entry: public API Commentary, `load-path` bootstrap for `lisp/`, requires and `provide`. |

Dependency direction is one way: `theme` ← `service` ← `model` ← `views` ←
`app`. A lower layer never calls into a higher one, and only `app` knows about
buffers, windows and keymaps.

## Data flow

```
key or mouse ─▶ app command ─▶ model action ─▶ client request ─▶ skill process
                                                     │
      view tree ◀─ app Component ◀─ reactive sources ◀┘ reply callback
```

1. A command reads the buffer's session (`etaf-ncm--model`), calls a public
   model action and returns. Nothing blocks.
2. The action writes the intent (selection, message, loading) into reactive
   sources and sends a request through the client.
3. The reply callback writes the result into the sources. Loading carries a
   generation counter, so a reply from a superseded library or search is
   discarded instead of overwriting newer data.
4. `etaf-ncm-app` subscribes to the sources it displays. A write repaints only
   the subscribed subtree, so a status tick never re-renders the sidebar.

The model never touches a buffer, and the views never touch a source. That is
what makes a headless session (`etaf-ncm-create` + actions + `etaf-ncm-state`)
behave exactly like the mounted player, and what the acceptance scenarios rely
on.

## State ownership

- Session (model): current library, loaded rows, backend total, selection, page,
  queue window and panel row budgets, message, error,
  pending generations, poll timer, `:theme`, `:aside`, `:layout` and `:pane`.
- Backend state directory: login cookie, queue file, saved queues. The player
  reads the queue tracks from that file and takes the current index from the
  backend command, so a stale file cannot invent a playing position.
- mpv: playback itself. The player never assumes a command succeeded; after a
  playback command it re-reads status and queue.

## Window layouts

Ebox has no media or container queries, so the responsive behaviour lives in the
model and is expressed by the view:

- `etaf-ncm--sync-layout` measures the window showing the player buffer and
  resolves `etaf-ncm-wide-columns` / `etaf-ncm-medium-columns` into one of
  `wide`, `medium` or `narrow`. It writes `:layout`, the layout page count
  (`:page-size`), `:queue-rows` and `:lyric-rows`, and, on a wide frame, forces
  `:pane` back to `list`. The panel budgets subtract the root padding, player
  bar, compact pane switch, aside padding, tabs and each panel's own heading.
  Lyrics reserve room for the cover and footer; translations share the budget.
  Opening fits after choosing the display window, including a newly split one.
- `etaf-ncm--window-size-change` is installed on `window-size-change-functions`
  once per session; resizing re-resolves the layout, and it ignores buffers
  without a model.
- The view reads `:layout` and `:pane` while it renders, so one ref write
  repaints header, sidebar, panes and player consistently. Views never read the
  model themselves: `etaf-ncm-app` passes values, and every pane switch goes
  through `etaf-ncm-show-pane`.
- A session without a window (headless) keeps `wide`, which keeps scripted and
  test sessions independent of the frame they run in.

## Lifecycle

Mounting the app (`etaf-ncm-open`, `etaf-ncm-view` + `etaf-mount`) provides the
palette to the subtree, subscribes the Component, starts polling and loads the
library. Unmounting disposes the session: the timer is cancelled and every
in-flight request of the client is dropped, so late replies never reach a
disposed session. A disposed session is revived by the next mount, which is what
makes close-and-reopen keep the library, selection and queue.

Reading a session (`etaf-ncm-state`) always returns copies. Callers can therefore
hold snapshots without keeping the player alive or accidentally mutating it.

## Interaction feedback

- A press on a row selects it; a press on the row that is already selected
  plays it.  The gesture does not consult a timing window, so a slow repaint
  cannot turn a double click into two selections.
- A song row belonging to a playable origin (`:daily`, `:liked`, `:fm`) sends
  `:play` for that origin, then `:jump` with its captured 1-based loaded-list
  index from the successful callback. Reconciliation waits for the jump reply.
  A failed list request never jumps; another play, skip, stop, queue jump or
  disposal suppresses the pending continuation. Search, recent and list-of-lists
  rows retain their individual targets. The header receives `on-play-all` only when the origin
  kind is in the service's play-command table.
- The queue projection uses `:queue-rows` and a zero-based `:queue-start`.
  A nil stored start centres the loaded window on the playing entry. A wheel
  gesture stores an explicit clamped start; unchanged queue replies preserve
  it, and a new position or changed songs restores following playback. Counts
  come from the backend, while the displayed range comes from loaded entries.
  The wheel's event window and pixel position select the target. A pure
  text-cell rectangle test uses the same body budget and the view's aside/rail
  widths, and excludes a hidden pane and the player bar. An app-local emulation
  map overrides only wheel events above the renderer's minor-mode bindings.
  Other wheel positions keep moving the library selection. Queue entries
  retain their press callback, focusable button role and normal TAB/RET bindings.
- Transport commands publish their local effect before the backend answers: the
  play/pause state, the volume, the shuffle and repeat flags and the message
  line change immediately, and the reply reconciles them with measured facts.
  Only a command that can move the queue reloads it.
- Every library list is cached under its section (or search keyword) through
  ETAF's `etaf-list-cache`, which owns the freshness interval, the candidate
  order and the one-at-a-time rule.  Opening a library shows the cached rows at
  once and refreshes the list in the background. Cache entries keep both normalized rows and the backend total;
  even an unchanged row list can publish a new total. A foreground reply must
  match both the load generation and the current list key. A mounted player
  warms the lists it has not seen yet, one at a time, and refreshes
  `etaf-ncm-library-refresh-interval`-second-old entries
  while it is idle.  The refresh pauses while the player's buffer is not on
  screen, backs off after a failure and stops when the backend needs a human
  (an expired login), resuming after the next successful load.  The background
  reply never moves the reader's selection.

Browse requests take the maximum of `etaf-ncm-list-limit` (1000), the existing
`etaf-ncm-fetch-limit` and three pages. The public snapshot preserves
`:rows-total` as the loaded count and exposes `:list-total` as the reported
total, falling back to the loaded count when absent. Selection and page bounds
use only loaded rows; the footer uses one-based visible indices and explicitly
labels a partial load on a second line, so the loaded count stays readable in
compact panes. The list uses a flex spacer to keep this footer inside its own
height; the player bar and pane tabs do not shrink when space is tight.
List repeat (`列表循环`) uses the existing `:repeat` request, which controls
mpv's `loop-playlist`.

## Player bar composition

The wide bar is a three-column grid. The left column reuses the cover Component
and groups the status VIP flag, title/artist, small actions, queue count and
command message. The centre stacks a single transport cluster over the seek
line. The right column groups a status-derived quality badge, lyric visibility,
queue access and volume. Compact layouts compose the same parts into three
rows, omitting the cover and quality badge. A symbol font is resolved once per
transport instance for the filled play/pause circle, with a Unicode fallback.
Bottom padding reserves room for the symbol fonts' taller metrics; the panel
and list budgets use the same reservation.

All action and gesture callbacks belong to the app's `:bindings`. Child Views
receive those stable functions and never allocate a render-time callback.
The cover and lyric action reveal the lyric pane; queue access reveals the
queue pane without changing either library selection or the stored queue window.
Status normalization preserves supplied VIP and quality hints; it never infers
the playing song's quality from the currently selected row.

Seek and volume are `etaf-range' Components: the pointer-to-ratio conversion
uses the host's painted pixels through ETAF's public measurement and Host-bound
APIs, and never leaves the app. A click and a released drag commit the pointed
value; motion reports a live value and cancellation commits nothing. Volume
routes through the existing optimistic command and reply reconciliation path,
retaining the 0–130 range.

## Polling policy

- Playing: one tick per `etaf-ncm-status-interval` (1 s). The tick advances the
  local clock for a smooth progress bar, asks the backend for playback truth and
  never overlaps the previous request (`:status-in-flight`).  While a request is
  on its way the tick leaves the clock alone: the reply is the truth and a local
  guess would repaint the view for the same second.
- The moving position lives in the session's `:clock` slot, not in a reactive
  source: a playing second replaces the elapsed label and the progress meter
  through their retained Hosts, so it commits one batched Ebox publication
  instead of repainting the view.  A tick that crosses a lyric line republishes,
  because the panel's current line moves with it.  `etaf-ncm-state` merges the
  clock back into the reported `:status`, which keeps the public snapshot shape
  unchanged.
- The progress bar is an `etaf-range': a flow track paints the rail and gives
  the row its measurable width, and an absolutely positioned fill overlay above
  it carries the played fraction. A playing second updates the elapsed label
  (`etaf-runtime-update-host-contents') and the fill's width percentage
  (`etaf-runtime-update-host-geometries'), both ETAF public retained updates:
  no View publication, no per-tick layout pass, and an absolutely positioned
  Host is the one shape Ebox accepts a width update on. The next ordinary View
  publication supplies the same clock geometry.
- Idle: one check per `etaf-ncm-idle-poll-interval` (15 s).
- A lyric is fetched only when the playing song id changes.
- The queue list is read from the backend's queue file, not re-downloaded.

Costs are therefore bounded by the poll the session selected, and zero when no
player is mounted.

## Measuring repaint cost

An update is only as cheap as the nodes it invalidates, and two numbers decide
whether a change to the player is affordable:

- Count layout passes per write: advise `ebox--render-layout-in-context` with a
  counter, perform one ref write, and read the count.  A `:status` write used to
  cause 19 to 40 passes; a retained clock tick causes none, because it replaces
  two Hosts in one batched Ebox publication.
- Sample the process CPU while the demo plays.  Paused playback is the baseline
  (0 %) and every playing second is the retained clock update, so a change that
  removes a whole-view repaint from the tick shows up directly.

- Run `emacs -Q --batch -L . -L lisp -L tests -L ../../etaf -L ../../etaf-ui
  -L ../../ebox -L ../../ecss -l benchmarks/update-cost.el` for the same numbers
  as a benchmark: a selection write republishes the whole view (about 250 ms at
  twelve rows with a byte-compiled framework), while a clock tick inside one
  lyric line commits a retained update (about 25 ms).

`benchmarks/update-phases.el` splits one update into its phases.  Its reading is
that the tree walks are cheap (about 5 ms for 5587 child enumerations) while
`ebox-commit`'s own candidate work costs about 73 ms, the surface projection
around the layout about 34 ms and the layout itself about 42 ms: the candidate
rebuilds the tree per update instead of reusing the published one, and that is
where the smoothness work starts.

The cost is the whole tree being laid out again on every update, and it is
where the remaining work sits: ETAF hands Ebox a complete tree per update and
Ebox lays all of it out instead of reusing the subtrees that did not change.
Byte compilation removes roughly half of it (an interpreted framework doubles
every number here), which is why the benchmark must run compiled.

## Backend contract

`etaf-ncm-client-call` accepts a request plist and a callback; a client is either
a subprocess client from `etaf-ncm-make-client` or a plain function of two
arguments, which is what tests and the demo inject. Replies are `(:ok DATA)` or
`(:error MESSAGE :hint HINT)`, delivered at most once.

Two failure classes are kept apart on purpose:

- Backend failures (network, login, mpv, a missing script, a signal raised while
  translating a request) land in the session's `:error` and `:message`. The
  player stays mounted and `g` retries.
- Invalid player operations (unknown library, blank search keyword, unplayable
  row, out-of-range volume) signal `etaf-ncm-error` immediately, because they are
  programming or input errors rather than backend state.

The default client runs the skill's scripts as child processes with the stored
cookie in the child environment (`process-environment` is bound around
`make-process`; that function has no `:environment` keyword). Each request has a
timeout, and unmounting deletes the processes.

## Rendering notes

- The layout is a column flex root: header, body (list + aside) and a full-width
  player bar; the compact layouts drop the sidebar for a library rail or a chip
  strip, tab the panes and stack the player bar into three lines.
- `row`/`column` are flow containers; participation properties
  (`:flex-grow`, `:flex-basis`) require a flex or grid parent, and `:flex-basis`
  units follow the parent's main axis (lh/vh/% in a column, px/ch in a row).
- Song rows use a grid so columns align; the list is paginated to the window
  instead of scrolled, because Ebox has no programmatic scroll API and every row
  must stay reachable by keyboard.
- Progress and volume keep the played fraction as a percentage width on the
  fill overlay, so the bar never rounds the ratio to a count of blocks and a
  retained update can replace it without a layout pass.
