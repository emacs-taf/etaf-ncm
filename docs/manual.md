# ETAF NCM manual

ETAF NCM is a NetEase Cloud Music client for Emacs. The player is a single ETAF
view: a sidebar of libraries, the library list, a side panel with the
synchronized lyric or the queue, and a playback bar. Playback itself stays in
mpv, driven by the `netease-music` backend; the player is the interface over it.

The [root entry Commentary](../etaf-ncm.el) is the authoritative list of
supported functions, variables, the app Component and the error type. This
manual describes the workflows and the contracts behind them.

## Prerequisites

- Emacs 29.1 or newer.
- The `etaf`, `etaf-ui`, `ebox` and `ecss` repositories, each on `load-path`.
- The `netease-music` backend skill (`scripts/netease-api.mjs`,
  `scripts/netease-music.sh`), Node.js and mpv, with a signed-in account. The
  backend keeps its login state and queue under its own state directory.

```elisp
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/etaf-ncm")
(require 'etaf-ncm)
```

## Opening the player

```elisp
M-x etaf-ncm-open
```

The player mounts in `etaf-ncm-buffer-name` (default `*ETAF 网易云音乐*`), hides
its mode line, installs `etaf-ncm-mode-map` and takes the window selection. The
buffer is a normal Ebox buffer: `TAB` cycles focus through the interactive
controls and `RET` activates the focused one. `M-x etaf-ncm-close` unmounts the
player and kills the buffer; the session behind it stays usable, so reopening
with the same session keeps its library, selection and queue.

Repeated `C-x b` switching away from the buffer does not close the player.
Killing the buffer directly has the same effect as `etaf-ncm-close`: mounting
and unmounting are what start and stop polling, and a session that was unmounted
is revived by its next mount.

### Keys

| Key | Action |
| --- | --- |
| `j` / `k`, `C-n` / `C-p`, `↓` / `↑`, wheel | Move the library selection, scrolling a page at the ends |
| click a row | Select it; click it again within half a second to play it |
| `RET` | Play the selected row |
| drag the progress bar | Seek to the position under the pointer |
| `SPC` | Pause or resume |
| `n` / `p` | Next / previous queue entry |
| `a` | Append the selected song to the queue |
| `s`, `/` | Search songs (a `read-string` prompt) |
| `g` | Refresh the library, playback status, queue and account |
| `l` | Switch the side panel between the lyric and the queue |
| `v` | Switch between the library list and the side panel in a compact layout |
| `r` | Toggle single-song repeat |
| `z` | Toggle shuffle |
| `f` / `F` | Like / unlike the playing song |
| `+` / `=` / `-` | Volume up / down by ten |
| `,` / `.` | Seek ten seconds back / forward |
| `1`-`9` | Jump to the nth sidebar library |
| `T` | Switch between the dark and the light palette |
| `?` | Show the key reference |
| `TAB` / `S-TAB` | Cycle focus through buttons, the search field and the panel tabs |
| `q` | Close the player buffer |

`n` and `p` intentionally replace Ebox's line scrolling: the library is
paginated to the window, so every row has a key and there is nothing to scroll
to. Resizing the frame updates the layout and re-fits the page; see
[Window layouts](#window-layouts).

### Window layouts

The player reads the width of the window that shows it and adapts, so a narrow
frame behaves like a phone instead of squeezing three columns into it:

| Width | Layout | What is visible |
| --- | --- | --- |
| `etaf-ncm-wide-columns` (106) and wider | `wide` | Library sidebar, song list and side panel at the same time |
| `etaf-ncm-medium-columns` (72) up to that width | `medium` | Glyph-only library rail, one pane at a time |
| Narrower than `etaf-ncm-medium-columns` | `narrow` | Library chips under the header, one full-width pane |

In `medium` and `narrow` the header gains pane tabs and the player bar becomes
two lines, so the library loses a few rows: the page count follows the layout.
`v` switches between the list and the side panel there, `l` shows the lyric or
queue panel, and `etaf-ncm-show-pane` does the same from Lisp. `etaf-ncm-state`
reports the current `:layout` and `:pane`.

Both width thresholds are defcustoms, so a font or a display scale that makes
the text wider only needs a different pair of numbers. A session without a
window, as in a headless batch run, keeps the `wide` layout.

## Libraries and search

The sidebar groups the backend's libraries: the daily recommendation, the
private FM, the liked songs, the user's playlists, the saved albums and artists,
the charts, the podcasts and the recent plays. Selecting one loads it and resets
the selection to its first row. `etaf-ncm-sections` holds the inventory, so a
package can rebind it to show a different catalog.

Search queries the catalog by song by default; the search library accepts a
playlist scope as well. Results behave like any other library: they can be
played, and songs can be queued.

## Playback and the queue

Every playback action is a backend command; the player reports what it sent in
the message line and then re-reads playback truth, so the displayed state never
comes from the player's own guess. A song plays directly; a playlist, album,
artist, chart, podcast or episode is resolved by the backend into its playable
songs.

The queue panel shows the entries around the playing position together with the
total count, which is the same list `netease-music queue` prints. Jumping to an
entry plays it; the current entry is marked in the list.

## Lyric, translation and theme

The lyric is fetched for the playing song id, parsed from LRC into timed lines
and shown with the line of the elapsed position emphasized. When the backend has
a translation for the song, each line shows its translation next to it. The
panel switches to the queue with `l`.

The palette has a dark and a light variant. `etaf-ncm-theme-mode` selects the
active one, `etaf-ncm-color` resolves single colours and
`etaf-ncm-theme-defaults` publishes the `:ui-*` tokens the mounted player hands
to the shared ETAF UI controls, so buttons, inputs and badges follow the same
palette. Pressing `T` changes the mode and repaints the mounted player; the
`theme` value of a session is reactive, which is what makes the subtree repaint.

## Scripting the player

A session is complete without a buffer: `etaf-ncm-create` returns a headless
player, the action functions drive it, and `etaf-ncm-state` reports what it
knows as a detached plist.

```elisp
(require 'etaf-ncm)
(let* ((player (etaf-ncm-create))
       (client (etaf-ncm-make-client)))
  (plist-put player :client client)
  (etaf-ncm-refresh player)
  (while (plist-get (etaf-ncm-state player) :loading)
    (sit-for 0.05))
  (etaf-ncm-move-selection player 2)
  (etaf-ncm-activate-selection player)
  (plist-get (etaf-ncm-state player) :status))
```

`etaf-ncm-state` copies every value, so reading it can never change the player
and asserting against it is safe. Requests are asynchronous: an action returns
after sending its request, and the reply updates the state. Loading carries a
generation counter, so a reply from a superseded library or search is dropped
instead of overwriting the newer result.

To embed the player in a larger layout, mount the view yourself:

```elisp
(let* ((player (etaf-ncm-create))
       (buffer (get-buffer-create "*my-music*")))
  (plist-put player :buffer buffer)
  (etaf-mount buffer (etaf-ncm-view player)
              (list :viewport-width 1200 :viewport-height 40))
  (pop-to-buffer buffer))
```

`etaf-ncm-view` returns the View; `etaf-mount` owns the runtime. Unmounting the
runtime disposes the session's polling, subscriptions and pending requests.

## Custom backends

The player talks to a *client*, a function or a structure that accepts a request
plist and a callback. `etaf-ncm-client-factory` is the function of no arguments
that new sessions use, so binding it is enough to drive the whole player from
another backend:

```elisp
(setq etaf-ncm-client-factory
      (lambda ()
        (lambda (request callback)
          (funcall callback
                   (pcase (plist-get request :op)
                     (:browse (list :ok (my-songs)))
                     (:status (list :ok (my-status)))
                     (_ (list :ok (list :ok t))))))))
(etaf-ncm-open)
```

The reply is `(:ok DATA)` on success and `(:error MESSAGE :hint HINT)` on
failure, delivered at most once. A backend failure never signals: it lands in
the session's `:error` and `:message`, so a missing network or a stopped mpv
leaves the player usable and `g` retries. Only invalid player operations, such
as an unknown library, a blank search keyword or a row without a playable
target, signal `etaf-ncm-error`; the entry Commentary lists those cases.

`etaf-ncm-make-client` builds the default client: pass `:skill-directory`,
`:state-directory`, `:node-program` or `:timeout` to point it at a different
checkout, state directory, Node.js binary or request budget.

## Polling and cost

While a song is playing the player ticks once per `etaf-ncm-status-interval`
(one second by default), advancing the local clock for a smooth progress bar and
asking the backend for playback truth. A tick never overlaps the previous
request. While nothing is playing it checks every
`etaf-ncm-idle-poll-interval` (fifteen seconds). A lyric is fetched only when
the playing song id changes, and the queue list is read from the backend's queue
state file rather than re-downloaded.

Unmounting cancels the timer and drops late replies, so a closed player costs
nothing. A long-running Emacs that keeps a player mounted only pays the poll it
selected.

## Troubleshooting

| Symptom | Cause and remedy |
| --- | --- |
| The message line shows `netease-music skill script is missing: ...` | `etaf-ncm-skill-directory` does not point at the skill; set it or install the skill. |
| The message line shows the backend error | Login, Node.js or mpv is the usual cause. Run `netease-music status` in a shell, then press `g`. |
| Every library is empty | The backend replied with an error; check `:error` in `etaf-ncm-state`. |
| The progress bar jumps instead of moving | Only `:elapsed` is interpolated locally; the backend is the truth, so a slow backend shows its own pace. |
| The window shows fewer rows after a resize | Press `g`; the page count is re-fitted on refresh. |
| The lyric panel says `这首歌没有歌词` | The track has no lyric, which is normal for instrumental music. |
