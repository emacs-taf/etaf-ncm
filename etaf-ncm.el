;;; etaf-ncm.el --- NetEase Cloud Music player for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0") (ebox "3.0.0"))
;; Keywords: multimedia, ui
;; URL: https://gitea.vhkd.top/geekinney/etaf-ncm

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-ncm) after adding this repository and
;; the ETAF, ETAF UI and Ebox roots to `load-path'.  The player is a complete
;; NetEase Cloud Music client for Emacs: it browses the signed-in account's
;; daily recommendation, liked songs, playlists, albums, artists, charts,
;; podcasts and recent plays, searches the catalog, drives playback through mpv,
;; shows the synchronized lyric with its translation, and edits the queue.
;;
;; A session is the unit of state.  `etaf-ncm-create' builds one, the actions
;; below drive it asynchronously, `etaf-ncm-state' reports it as plain data, and
;; `etaf-ncm-app' or `etaf-ncm-open' display it.  Every displayed value is an
;; ETAF reactive source, so a backend reply repaints the mounted player without
;; a refresh call.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list; implementations
;; and precise docstrings remain beside their definitions, and the manual
;; contains workflows.
;;
;; Function: etaf-ncm-open (&optional model)
;;;###autoload (autoload 'etaf-ncm-open "etaf-ncm" nil t)
;; Mount the player in `etaf-ncm-buffer-name' and return its buffer.
;; MODEL defaults to a session from `etaf-ncm-create', so the player opens on the
;; daily recommendation with the account, playback status and queue of the
;; backend.  A caller-provided MODEL keeps its library, selection and queue, and
;; is revived when it was displayed before.  The app fills the selected window
;; instead of letting a display rule split the frame.  The buffer gets
;; `etaf-ncm-mode-map' and hides its mode line; closing the buffer releases the
;; session's polling and pending requests, so a later `etaf-ncm-open' with the
;; same MODEL works again.
;;
;; Function: etaf-ncm-close ()
;;;###autoload (autoload 'etaf-ncm-close "etaf-ncm" nil t)
;; Unmount the player and kill its buffer.
;; Unmounting releases the session's reactive subscriptions, polling timer and
;; in-flight backend requests; the session itself stays usable for a later mount.
;;
;; Function: etaf-ncm-view (&optional model)
;;;###autoload (autoload 'etaf-ncm-view "etaf-ncm" nil t)
;; Return the player View for MODEL, defaulting to a new session.
;; Use it to embed the player in your own `etaf-mount' call, for example inside a
;; tab or a larger layout; `etaf-ncm-open' is the shortcut that also owns the
;; buffer.
;;
;; Component: etaf-ncm-app (&key model)
;; Render the mounted player for MODEL and own its session lifecycle.
;; MODEL must come from `etaf-ncm-create'.  Mounting provides the palette for its
;; subtree, starts playback polling and loads the current library; unmounting
;; disposes the session.  The Component reads every displayed value from the
;; model, so any action or backend reply repaints it; prefer `etaf-ncm-open' or
;; `etaf-ncm-view' over mounting the Component directly.
;;
;; Function: etaf-ncm-create (&key client cache-file)
;; Return a new player session that talks to CLIENT.
;; CLIENT defaults to `etaf-ncm-client-factory' when that is bound and otherwise
;; to `etaf-ncm-make-client'.  The session owns no buffer and no timer before it
;; is mounted, so it is a complete headless player for scripts and tests.  Pass a
;; CLIENT function to drive the same player from another backend. CACHE-FILE
;; optionally selects a disposable local sidebar snapshot, restored before mount.
;; The default client uses library-cache.eld in its state directory; injected
;; function clients stay in memory unless CACHE-FILE is supplied. Snapshots are
;; credential-scoped, size-bounded, atomically replaced and never evaluated.
;;
;; Function: etaf-ncm-state (app)
;; Return APP's session state as a detached plist snapshot.
;; Keys are `:section', `:title', `:subtitle', `:mode', `:query', `:items',
;; `:visible', `:window-start', `:selection', `:page-size', `:rows-total',
;; `:list-total', `:queue-rows', `:queue-start', `:lyric-rows',
;; `:status', `:queue', `:lyric', `:lyric-line', `:aside', `:theme', `:account',
;; `:downloads' (the local download registry), `:layout', `:pane', `:viewport-width' (the pixel canvas the player mounts
;; into), `:loading', `:error' and `:message'.  The snapshot copies
;; every value, so mutating it never changes the player; use it to render
;; outside ETAF or to assert behavior in tests.
;; `:status' includes normalized `:vip' and `:quality' when reported by the
;; backend; missing quality is nil. These describe the playing song.
;; `:rows-total' counts loaded library rows; `:list-total' keeps the backend's
;; total when reported and otherwise equals the loaded count.  `:queue-rows'
;; and `:lyric-rows' are panel line budgets (translations use lyric lines too);
;; `:queue-start' is the zero-based start of the loaded queue window.
;;
;; Function: etaf-ncm-refresh (app)
;; Reload APP's library, playback status, queue and account.
;; It re-resolves the window layout and re-fits the visible row count, so call it
;; after a resize.  Every request is asynchronous and a reply belonging to a
;; superseded load is dropped, which makes repeated refreshes safe.
;;
;; Function: etaf-ncm-locate (app section)
;; Show SECTION of APP's library.
;; SECTION is one of the keys in `etaf-ncm-sections': `:daily', `:fm',
;; `:liked', `:playlists', `:albums', `:artists', `:charts', `:podcasts' or
;; `:recent'.  An unknown SECTION signals `etaf-ncm-error' and leaves APP
;; unchanged.
;;
;; Function: etaf-ncm-search (app keyword &optional scope)
;; Search KEYWORD and show the results as APP's library.
;; SCOPE is `song' (the default) or `album'/`artist'/`playlist' as accepted by
;; the backend.  A blank KEYWORD signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-play (app &optional item)
;; Play ITEM, or APP's current library when ITEM is nil.
;; ITEM is a library row as reported in `etaf-ncm-state' `:items'; a row carries
;; at least `:kind' and `:id'.  A song row in the daily, liked or FM library
;; queues the loaded ids and starts at that row in one backend command.
;; Other songs play directly, while a playlist, album,
;; artist, chart or podcast is resolved by the backend into its playable songs.
;; A row without a playable target signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-add-to-queue (app item)
;; Append the song ITEM to the queue.
;; The queue is the backend's queue file, so the running mpv session keeps
;; playing; a non-song ITEM signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-download (app item)
;; Download the song ITEM into APP's local library.
;; The backend fetches the best quality the account can play, stores the file
;; under its configured download directory and registers it.  Downloaded songs
;; get a check mark in the list, and the next queue for that song plays the
;; local file instead of fetching a fresh stream URL.  A song that is already
;; downloaded is refreshed in place; a non-song ITEM signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-download-selection (app)
;; Download the library row APP's selection points at.
;; An empty library does nothing.
;;
;; Function: etaf-ncm-row-action (app index key)
;; Run action KEY on library row INDEX (counting from 1) in APP.
;; KEY is `play', `queue' or `download'; the inline icon resolves the row when
;; pressed, so a list reply that moved in between cannot act on a stale row.
;; An out-of-range INDEX or unknown KEY signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-jump-queue (app index)
;; Play the queue entry at 1-based INDEX.
;; INDEX outside the queue signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-toggle-playback (app)
;; Pause APP's playback when it is playing and resume it otherwise.
;;
;; Function: etaf-ncm-next-track (app)
;; Play the next track of the queue.
;;
;; Function: etaf-ncm-previous-track (app)
;; Play the previous track of the queue.
;;
;; Function: etaf-ncm-stop (app)
;; Stop playback and leave the queue.
;;
;; Function: etaf-ncm-set-volume (app volume)
;; Set the backend volume to VOLUME, an integer from 0 to 100.
;; The backend clamps out-of-range values; the player reports the volume the
;; backend accepted after its next status poll.
;;
;; Function: etaf-ncm-seek (app seconds)
;; Seek SECONDS from the current position, positive forward and negative back.
;;
;; Function: etaf-ncm-set-shuffle (app on)
;; Turn shuffle mode on when ON is non-nil and off otherwise.
;;
;; Function: etaf-ncm-set-repeat (app on)
;; Turn list repeat (列表循环) on when ON is non-nil and off otherwise.
;; The existing backend repeat command controls mpv's loop-playlist.
;;
;; Function: etaf-ncm-like (app &optional unlike)
;; Add the current song to the liked songs, or remove it when UNLIKE is non-nil.
;;
;; Function: etaf-ncm-move-selection (app delta)
;; Move APP's library selection by DELTA rows and keep it inside the visible page.
;; Selection stops at the first and last row; moving past a page boundary scrolls
;; the page so the new selection stays visible.
;;
;; Function: etaf-ncm-activate-selection (app)
;; Play the row APP's selection points at, doing nothing on an empty library.
;;
;; Function: etaf-ncm-press-row (app index)
;; Press library row INDEX (counting from 1): select it, or play it when it is
;; the selected row or was pressed twice in quick succession.  This is the
;; gesture a click on a list row performs, which a programmatic caller can use
;; to follow the same sentence.  An out-of-range INDEX signals `etaf-ncm-error'.
;;
;; Function: etaf-ncm-toggle-aside (app)
;; Switch APP's side panel between the lyric and the queue.
;;
;; Function: etaf-ncm-show-pane (app pane)
;; Show PANE in APP and return it.
;; PANE is `list' for the library list or `aside' for the lyric and queue panel;
;; any other PANE signals `etaf-ncm-error'.  A `wide' layout keeps every column
;; visible, so there PANE is remembered without removing anything; medium and
;; narrow layouts show that single pane.
;;
;; Variable: etaf-ncm-sections
;; Sidebar groups and their libraries, as (GROUP-NAME (SECTION LABEL ICON) ...).
;; ICON names a glyph of the shared `etaf-ui-icon' SVG set; rebind the variable
;; before mounting a session to show a different catalog of libraries, and keep
;; each SECTION accepted by `etaf-ncm-locate'.
;;
;; Variable: etaf-ncm-buffer-name
;; Buffer `etaf-ncm-open' mounts the player into.
;;
;; Variable: etaf-ncm-mode-map
;; Keymap installed by `etaf-ncm-open'.  It keeps Ebox's TAB focus cycling and
;; replaces the scrolling keys with player commands.
;;
;; Variable: etaf-ncm-page-size
;; Library rows shown at once.  `etaf-ncm-open' replaces it with the count that
;; fits the window, so the default only applies to a headless session.
;;
;; Variable: etaf-ncm-wide-columns
;; Frame width, in columns, that fits the library sidebar, the song list and the
;; side panel at the same time.  At or above this width the player uses the
;; `wide' layout: one selection in the list and the panel always visible.
;;
;; Variable: etaf-ncm-medium-columns
;; Frame width, in columns, that still fits a narrow library rail.  At or above
;; this width, but below `etaf-ncm-wide-columns', the player keeps the glyph-only
;; rail and shows a single pane; below it the libraries move into a header strip
;; and every pane uses the full width.
;;
;; Variable: etaf-ncm-fetch-limit
;; Lower bound on rows requested for one library load, retained for callers
;; that configured it before `etaf-ncm-list-limit'.
;;
;; Variable: etaf-ncm-list-limit
;; Rows requested for one library load, default 1000.  The actual request is
;; the maximum of this value, `etaf-ncm-fetch-limit' and three visible pages.
;; Backend totals stay distinct from loaded counts when the reply is partial.
;;
;; Variable: etaf-ncm-library-refresh-interval
;; Seconds after which a cached library list is refreshed in the background,
;; default 300.
;; A cached list is shown at once when a library is opened and then compared
;; with a fresh reply; this interval decides when the idle refresh is due.
;;
;; Variable: etaf-ncm-prefetch-libraries
;; Whether a mounted player warms and refreshes library lists while idle,
;; default t.
;; One list at a time is loaded in the background, so opening a library that
;; was never visited can paint from the cache; nil keeps the cache to the
;; libraries the listener actually opens.
;;
;; Variable: etaf-ncm-status-interval
;; Seconds between playback ticks while a song is playing.
;; Each tick advances the local clock for a smooth progress bar and asks the
;; backend for playback truth; requests never overlap.
;;
;; Variable: etaf-ncm-idle-poll-interval
;; Seconds between playback checks while nothing is playing.
;;
;; Variable: etaf-ncm-theme-mode
;; Palette used by `etaf-ncm-color' and `etaf-ncm-theme-defaults': `dark' or `light'.
;; A mounted player repaints when a session's `:theme' value changes, which is
;; what the player's T key does.
;;
;; Function: etaf-ncm-color (key &optional mode)
;; Return the palette color for KEY, optionally reading MODE instead of
;; `etaf-ncm-theme-mode'.
;; KEY is one of `:bg', `:panel', `:panel2', `:panel3', `:line', `:ink',
;; `:muted', `:dim', `:accent', `:accent-soft', `:gold', `:ok', `:danger',
;; `:danger-bg', `:playing', `:selected', `:meter' or `:cover'; an unknown KEY
;; signals `etaf-ncm-error'.  Views use it to stay readable in both palettes.
;;
;; Function: etaf-ncm-theme-defaults (&optional mode)
;; Return the `:ui-*' theme defaults of MODE as a property plist.
;; The list is what the mounted player provides to the ETAF UI controls in its
;; subtree, so buttons, inputs and badges follow the same palette.
;;
;; Function: etaf-ncm-make-client (&key skill-directory state-directory node-program timeout)
;; Return a client that calls the `netease-music' backend of SKILL-DIRECTORY.
;; STATE-DIRECTORY is where the backend keeps its queue and login state,
;; NODE-PROGRAM runs the backend scripts, and TIMEOUT is the seconds a request
;; may take before it fails.  Every argument defaults to the matching
;; `etaf-ncm-' variable, and the returned client is usable with
;; `etaf-ncm-client-call'.
;;
;; Variable: etaf-ncm-client-factory
;; Function of no arguments returning the client of new sessions.
;; Bind it to drive `etaf-ncm-create' with another backend, which is how the
;; acceptance scenarios play a scripted session without network or mpv.
;;
;; Function: etaf-ncm-client-call (client request callback)
;; Send REQUEST to CLIENT and call CALLBACK once with its reply.
;; REQUEST is a plist starting with `:op' (`:browse', `:search', `:lyric',
;; `:session', `:status', `:queue', `:play', `:add', `:jump', `:volume',
;; `:seek', `:pause', `:resume', `:toggle', `:next', `:previous', `:stop',
;; `:like', `:unlike', `:liked-ids', `:shuffle', `:repeat', `:queue-save' or
;; `:queue-load').
;; CALLBACK receives `(:ok DATA)' on success and `(:error MESSAGE :hint HINT)' on
;; failure, at most once.  A client that cannot answer calls it neither; a
;; session that is disposed by `etaf-ncm-cancel' drops late replies.
;;
;; Function: etaf-ncm-cancel (client)
;; Cancel CLIENT's pending requests and drop their late replies.
;;
;; Function: etaf-ncm-parse-lyric (text)
;; Parse LRC TEXT into a list of (SECONDS . LINE) pairs, earliest first.
;; Metadata tags and timestamp-only lines are skipped, so the result is directly
;; usable as the `:lines' of a lyric; an empty result means an instrumental
;; track.
;;
;; Variable: etaf-ncm-skill-directory
;; Directory of the `netease-music' backend scripts used by the default client.
;;
;; Variable: etaf-ncm-state-directory
;; Directory holding the backend's queue and login state.
;;
;; Variable: etaf-ncm-node-program
;; Program used to run the backend's Node.js scripts.
;;
;; Variable: etaf-ncm-request-timeout
;; Seconds a backend request may take before it fails with a timeout error.
;;
;; Error: etaf-ncm-error
;; Invalid player operation, for example an unknown library, an empty search
;; keyword or a row without a playable target.  Backend failures are reported in
;; the session's `:error' and `:message' instead of being signaled, because they
;; happen asynchronously while the player stays usable.

;;; Code:

(eval-and-compile
  (let ((directory (file-name-directory (or load-file-name
                                            (bound-and-true-p byte-compile-current-file)
                                            buffer-file-name))))
    (add-to-list 'load-path (expand-file-name "lisp" directory))))

(require 'etaf-ncm-theme)
(require 'etaf-ncm-service)
(require 'etaf-ncm-model)
(require 'etaf-ncm-views)
(require 'etaf-ncm-app)

(provide 'etaf-ncm)
;;; etaf-ncm.el ends here
