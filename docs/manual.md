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
its mode line, installs `etaf-ncm-mode-map` and fills the selected window
instead of letting a display rule split the frame; it takes the window
selection. The buffer is a normal Ebox buffer: `TAB` cycles focus through the interactive
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
| `j` / `k`, `C-n` / `C-p`, `↓` / `↑` | Move the library selection, scrolling a page at the ends |
| wheel | Scroll the queue window when over the visible queue panel; elsewhere, move the library selection |
| click a row | Select it; pressing the selected row plays it |
| `RET` | Play the selected row |
| `Home` / `End` | Jump to the first / last loaded row of the library |
| `PageUp` / `PageDown` | Move the selection by one page |
| click or drag the progress bar | Seek to the position under the pointer |
| click or drag the volume slider | Set volume at the pointer, from 0 to 130% |
| click the cover / `词` / queue control | Show lyrics / lyrics / the queue, preserving the current selection and queue window |
| click a row's download / `+` icon | Download / add to queue directly; the compact layout keeps download |
| `SPC` | Pause or resume; with an empty queue it plays the selected song |
| `n` / `p` | Next / previous queue entry |
| `a` | Append the selected song to the queue |
| `d` | Download the selected song into the local library |
| `s`, `/` | Search songs (a `read-string` prompt) |
| `g` | Refresh the library, playback status, queue and account |
| `l` | Switch the side panel between the lyric and the queue |
| `v` | Switch between the library list and the side panel in a compact layout |
| `r` | Toggle list repeat (`列表循环`) |
| `z` | Toggle shuffle |
| `f` / `F` | Like / unlike the playing song |
| `+` / `=` / `-` | Volume up / down by ten |
| `,` / `.` | Seek ten seconds back / forward |
| `1`-`9` | Jump to the nth sidebar library |
| `T` | Switch between the dark and the light palette |
| `?` | Show the key reference |
| `TAB` / `S-TAB` | Cycle focus through buttons, the search field, panel tabs and visible queue entries |
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

In `medium` and `narrow` the header gains pane tabs and the player bar stacks
into three lines, dropping its cover and quality badge while keeping the track,
transport, pane controls, progress and volume. The page count follows the layout.
`v` switches between the list and the side panel there, `l` shows the lyric or
queue panel, and `etaf-ncm-show-pane` does the same from Lisp. `etaf-ncm-state`
reports the current `:layout` and `:pane`.

The queue and lyric windows also fit the panel's height. Enlarging the window
shows more entries; shrinking it keeps the playing queue entry or current lyric
line visible. Translations share the lyric's line budget.

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

Library loads request 1000 rows by default. Set `etaf-ncm-list-limit` to change
that budget; the actual request is at least `etaf-ncm-fetch-limit` (the existing
lower bound) and three visible pages. `Home`, `End`, `PageUp` and `PageDown`
navigate every loaded row, including those beyond the first 100.

The footer shows `第 X-Y 首 / 共 N 首` with the backend's total when supplied.
If the backend returns only part of a library, a second line says
`已加载 M / 共 N 首` instead of presenting that partial count as the library
size. Raise the limit and press
`g` to request more; the backend may still impose its own limit. Cached lists
retain their totals while refreshing.

## Playback and the queue

The wide player bar follows the native client's arrangement. On the left, a
cover placeholder opens the lyrics; a reported VIP badge precedes the title
and artist on one line. Small actions below add the selected song (`+`, `a`),
like the playing song (`♡`, `f`; `F` unlikes), toggle shuffle, stop, and open the
queue beside its count. The message below these actions reports command feedback.
The centre has like, previous, a prominent red play/pause pill, next and list
repeat. Elapsed time, a thin seek bar and duration sit under that cluster. The
bar's controls and icons are `etaf-ui-icon' SVGs: one optical size, one style,
and no glyph can change the row height.

On the right, quality appears only when playback status reports it: `无损` for
lossless, otherwise the supplied quality, bitrate or VIP hint. `词 ON/OFF`
indicates whether the lyrics are visible; pressing it opens that pane. The
queue control opens the queue. The speaker, slider and percentage show volume.
Clicking or releasing a drag on either slider selects the value under the
pointer. Volume changes appear immediately, then reconcile with the backend's
reply. The existing volume and seek keys still work; no new key is required.

Every playback action is a backend command; the player reports what it sent in
the message line and then re-reads playback truth, so the displayed state never
stays a guess. Transport commands show their effect immediately and reconcile
with the reply; a command that can move the queue reloads it.

A press selects a row and a press on the selected row plays it: a double click
therefore starts the song even when the first repaint took a moment. In the
daily recommendation, liked songs and private FM, playing a song row queues
the loaded songs and starts directly at that row, without playing the first
song beforehand. `n` and `p` continue through those loaded songs in order. The `播放全部` button appears
only in those libraries, where whole-list playback is supported.

Songs in search results or recent plays still play directly. A playlist, album,
artist, chart, podcast or episode row is resolved by the backend into its
playable songs. `r` controls list repeat (`列表循环`), the backend's mpv
`loop-playlist` setting.

The queue panel opens around the playing position and shows
`第 X-Y 首 / 共 N 首` using the loaded window and backend count. Roll the wheel
over the panel to reach any loaded queue entry without changing the library
selection or playback. That window stays where you scrolled through unchanged
status refreshes; a new playing entry or changed queue centres it on playback
again. Clicking an entry jumps to it, and visible entries remain reachable by
`TAB` and `RET`. The current entry is marked in the list.

## Local downloads

The row's download icon downloads it directly; the `+` icon adds it to the
queue. There is no options menu. Compact rows keep the download icon; `a`
still adds the selected song to the queue. `d` downloads the selection.
The download arrow becomes a check mark when the file is on this machine;
clicking that check downloads it again. The message line reports progress.

The backend does the downloading: it takes the best quality the account can
play, stores the file under its own download directory and registers it, so
the marker is the backend's truth, not a local guess. The Emacs player only
sends the row's id and reads the registry back, so a file downloaded from the
command line shows the same check mark after `g`.

Playback prefers the local file: when a queue is built, every registered song
whose file is still on disk is played from its path instead of fetching a new
stream URL, and the keepalive never replaces it. A downloaded song therefore
keeps playing without a network round trip and without the five-minute URL
expiry. Downloading a song that is already local refreshes the file in place.

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

`etaf-ncm-press-row` performs the list gesture a click uses:
`(etaf-ncm-press-row player 3)` selects the third row, and pressing it again
plays it. Transport commands show their effect immediately and reconcile with
the backend reply, so `etaf-ncm-state` right after `etaf-ncm-toggle-playback`
already reports the new playback state.

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

Playback status may include `:vip`, `:lossless`, `:quality`, `:bitrate` and
`:vip_hint`. Flags accept booleans, positive numbers, or `"true"` / `"1"` /
`"yes"`. Bitrate numbers above 1000 are interpreted as bits per second and
displayed as kbps; a textual bitrate hint is preserved. Missing hints produce
no quality badge. These fields describe the playing song, independently of
the selected library row.

`etaf-ncm-make-client` builds the default client: pass `:skill-directory`,
`:state-directory`, `:node-program` or `:timeout` to point it at a different
checkout, state directory, Node.js binary or request budget.

## Polling and cost

While a song is playing the player ticks once per `etaf-ncm-status-interval`
(one second by default), advancing the local clock for a smooth progress bar and
asking the backend for playback truth. A tick never overlaps the previous
request. The elapsed label and the progress fill are updated in place through
ETAF's retained Host updates, so a playing second does not republish the view;
a tick that moves the lyric line does. The player bar itself is a retained
panel: the play/pause pill, the heart, shuffle, repeat and the status message
read their own reactive sources inside Host bindings, so pressing one of them
publishes a retained update instead of rebuilding the view. The lyrics and
queue panels are two fixed-canvas variants whose visibility follows the
`:aside` source, and every library row reads the selection source in its own
paint bindings; switching panels or moving the highlight likewise publishes
retained updates. While nothing is playing it checks every `etaf-ncm-idle-poll-interval`
(fifteen seconds). A lyric is fetched only when the playing song id changes, and
the queue list is read from the backend's queue state file rather than
re-downloaded.

Library lists are cached per section and refreshed in the background: opening a
library shows the cached rows immediately, a mounted player warms the lists it
has not seen yet, and a list older than `etaf-ncm-library-refresh-interval`
(five minutes) is refreshed while the player is idle. Set
`etaf-ncm-prefetch-libraries` to nil to leave the cache to the visited
libraries only.  The refresh pauses while the player's buffer is not on screen,
backs off after a failure and stops when the backend needs a human (an expired
login), resuming after the next successful load.

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
