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

- Session (model): current library, rows, selection, page, message, error,
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
  (`:page-size`) and, on a wide frame, forces `:pane` back to `list`.
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
- Transport commands publish their local effect before the backend answers: the
  play/pause state, the volume, the shuffle and repeat flags and the message
  line change immediately, and the reply reconciles them with measured facts.
  Only a command that can move the queue reloads it.
- Every library list is cached under its section (or search keyword).  Opening
  a library shows the cached rows at once and refreshes the list in the
  background; a mounted player warms the lists it has not seen yet, one at a
  time, and refreshes `etaf-ncm-library-refresh-interval`-second-old entries
  while it is idle.  The background reply never moves the reader's selection.

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
  strip, tab the panes and give the player bar a second line.
- `row`/`column` are flow containers; participation properties
  (`:flex-grow`, `:flex-basis`) require a flex or grid parent, and `:flex-basis`
  units follow the parent's main axis (lh/vh/% in a column, px/ch in a row).
- Song rows use a grid so columns align; the list is paginated to the window
  instead of scrolled, because Ebox has no programmatic scroll API and every row
  must stay reachable by keyboard.
- Progress and volume meters are boxes with fractional widths rather than
  block-character text, which keeps them smooth at any window width.
