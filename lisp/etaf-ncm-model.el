;;; etaf-ncm-model.el --- Player state and backend actions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns everything a player session remembers: the selected library,
;; the visible rows, the keyboard selection, the playback status, the queue and
;; the lyric.  Every mutable value is an ETAF reactive source, so a View that
;; reads it repaints when a backend reply arrives; every backend request is
;; asynchronous and its reply is dropped when it belongs to a superseded load.
;;
;; The model is independent of any buffer: `etaf-ncm-create' plus the public
;; actions drive a complete session headlessly, which is how the acceptance
;; scenarios exercise it with a fake client.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ncm-service)
(require 'etaf-ncm-theme)

(defconst etaf-ncm-sections
  '((推荐
     (:daily "每日推荐" star)
     (:fm "私人 FM" radio)
     (:liked "我喜欢的音乐" heart))
    (我的音乐
     (:playlists "我的歌单" list)
     (:albums "收藏专辑" disc)
     (:artists "收藏歌手" account))
    (发现
     (:charts "排行榜" chart)
     (:podcasts "播客" mic)
     (:recent "最近播放" clock)))
  "Sidebar groups shown by the player.
Each group is (GROUP-NAME (SECTION LABEL ICON) ...); SECTION keys are accepted
by `etaf-ncm-locate', and ICON names an entry of the shared SVG icon set.")

(defconst etaf-ncm--section-subtitles
  '((:daily . "根据你的口味生成，每天更新")
    (:fm . "没听过的歌，一直放下去")
    (:liked . "你点过红心的歌")
    (:playlists . "收藏和自己建的歌单")
    (:albums . "收藏过的专辑")
    (:artists . "关注的歌手")
    (:charts . "飙升榜、新歌榜和各类榜单")
    (:podcasts . "订阅的播客节目")
    (:recent . "最近一周听过什么"))
  "One-line explanation shown under each library title.")

(defcustom etaf-ncm-page-size 24
  "Library rows shown at once.
`etaf-ncm-open' replaces this with the number that fits the window, so the
player fills the frame it is given; the default only applies to a headless
model created by `etaf-ncm-create'."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-wide-columns 106
  "Frame width, in columns, that fits all three player columns.
At or above this width the player shows the library sidebar, the song list and
its side panel at the same time (`wide' layout).  Between
`etaf-ncm-medium-columns' and this width it keeps a narrow library rail and
shows one pane at a time; below it the libraries become a header strip."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-medium-columns 72
  "Frame width, in columns, that still fits a library rail.
At or above this width the player keeps a narrow glyph-only library rail
(`medium' layout); below it the libraries move into a strip under the header
(`narrow' layout) and every pane uses the full width."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-fetch-limit 100
  "Lower bound on rows requested from the backend for one library load.
The request also respects `etaf-ncm-list-limit' and three visible pages."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-list-limit 1000
  "Rows requested from the backend for a library load.
The request uses at least `etaf-ncm-fetch-limit' and three visible pages.
When the backend reports more rows than it returns, the footer shows both the
loaded count and the total; navigation covers the loaded rows."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-status-interval 1.0
  "Seconds between playback ticks while a song is playing.
Each tick advances the local clock for a smooth progress bar and asks the
backend for playback truth; requests never overlap."
  :type 'number
  :group 'etaf-ncm)

(defcustom etaf-ncm-idle-poll-interval 15
  "Seconds between playback checks while nothing is playing."
  :type 'number
  :group 'etaf-ncm)

(defcustom etaf-ncm-library-refresh-interval 300
  "Seconds after which a cached library list is refreshed in the background.
A cached list is shown immediately when a library is opened, then refreshed;
the cache is a display shortcut, never the source of truth."
  :type 'number
  :group 'etaf-ncm)

(defcustom etaf-ncm-prefetch-libraries t
  "Whether a mounted player warms the library cache in the background.
One not-yet-cached sidebar list is loaded at a time while the player is idle,
so opening a library rarely waits for the network."
  :type 'boolean
  :group 'etaf-ncm)

;;; ---------------------------------------------------------------------------
;;; Construction and reactive access
;;; ---------------------------------------------------------------------------

(cl-defun etaf-ncm-create (&key client)
  "Create a player session that talks to CLIENT.
CLIENT defaults to `etaf-ncm-client-factory' when that is bound, and otherwise
to `etaf-ncm-make-client'.  The session owns no buffer and no timer until it is
mounted by `etaf-ncm-app' or started by `etaf-ncm-refresh'; it is also a
complete headless player for tests and other Lisp callers."
  (let ((client (or client
                    (if etaf-ncm-client-factory
                        (funcall etaf-ncm-client-factory)
                      (etaf-ncm-make-client)))))
    (list :client client
          :buffer nil
          :mounted-width nil
          :page-size (etaf-ref etaf-ncm-page-size :name 'etaf-ncm-page-size)
          :queue-rows (etaf-ref etaf-ncm-page-size :name 'etaf-ncm-queue-rows)
          :lyric-rows (etaf-ref (max 0 (- etaf-ncm-page-size 7))
                               :name 'etaf-ncm-lyric-rows)
          :disposed nil
          :status-in-flight nil
          :polled-at 0
          :last-tick (float-time)
          :timer nil
          :last-press nil
          :play-generation 0
          :list-cache (etaf-list-cache-create :grace 3)
          :list-key nil
          :section (etaf-ref :daily :name 'etaf-ncm-section)
          :title (etaf-ref "每日推荐" :name 'etaf-ncm-title)
          :subtitle (etaf-ref "根据你的口味生成，每天更新" :name 'etaf-ncm-subtitle)
          :origin (etaf-ref '(:kind :daily) :name 'etaf-ncm-origin)
          :rows (etaf-ref nil :name 'etaf-ncm-rows)
          :list-total (etaf-ref 0 :name 'etaf-ncm-list-total)
          :selection (etaf-ref 0 :name 'etaf-ncm-selection)
          :window-start (etaf-ref 0 :name 'etaf-ncm-window-start)
          :status (etaf-ref nil :name 'etaf-ncm-status)
          ;; The displayed position is not reactive: a playing second changes it
          ;; and is shown through the player bar's retained Hosts, so a write
          ;; here would republish the whole view once per second.
          :clock 0
          ;; (wall-clock . target) of a seek the backend has not applied yet.
          :seek-guard (etaf-ref nil :name 'etaf-ncm-seek-guard)
          :queue (etaf-ref nil :name 'etaf-ncm-queue)
          ;; Nil follows playback; a wheel gesture pins a loaded window until
          ;; the playing entry or queue contents change.
          :queue-start (etaf-ref nil :name 'etaf-ncm-queue-start)
          :lyric (etaf-ref nil :name 'etaf-ncm-lyric)
          :aside (etaf-ref 'lyrics :name 'etaf-ncm-aside)
          :theme (etaf-ref (etaf-ncm-theme-defaults) :name 'etaf-ncm-theme)
          :account (etaf-ref nil :name 'etaf-ncm-account)
          :query (etaf-ref "" :name 'etaf-ncm-query)
          :mode (etaf-ref 'browse :name 'etaf-ncm-mode)
          :layout (etaf-ref 'wide :name 'etaf-ncm-layout)
          :pane (etaf-ref 'list :name 'etaf-ncm-pane)
          :loading (etaf-ref nil :name 'etaf-ncm-loading)
          :error (etaf-ref nil :name 'etaf-ncm-error)
          :message (etaf-ref nil :name 'etaf-ncm-message)
          :generation (etaf-ref 0 :name 'etaf-ncm-generation))))

(defun etaf-ncm--ref (model key)
  "Return MODEL's reactive source named KEY."
  (plist-get model key))

(defun etaf-ncm--read (model key)
  "Return MODEL's current value for KEY, tracked while rendering."
  (etaf-value (etaf-ncm--ref model key)))

(defun etaf-ncm--write (model key value)
  "Publish VALUE as MODEL's new value for KEY; return VALUE.
A write that would not change the reading is skipped: the player re-renders on
every write, and a status tick that repeats the previous reading (an idle
poll, a reply that matches the local clock) would otherwise repaint the whole
view for nothing."
  (let ((ref (etaf-ncm--ref model key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

(defun etaf-ncm--update (model key function &rest arguments)
  "Publish (FUNCTION OLD-READING ARGUMENTS ...) as MODEL's value for KEY."
  (apply #'etaf-update-value (etaf-ncm--ref model key) function arguments))

(defun etaf-ncm--clock (app)
  "Return APP's displayed playback position in seconds."
  (or (plist-get app :clock) 0))

(defun etaf-ncm--set-clock (app seconds)
  "Store SECONDS as APP's displayed position without publishing.
Display goes through `etaf-ncm--publish-clock'."
  (setf (plist-get app :clock) seconds))

(defun etaf-ncm--ratio (value total)
  "Return VALUE/TOTAL clamped to the closed interval from zero to one."
  (let ((total (if (and (numberp total) (> total 0)) total 1)))
    (max 0.0 (min 1.0 (/ (float (or value 0)) total)))))

(defconst etaf-ncm--clock-host 'ncm-elapsed
  "Retained Host that shows the played position on the player bar.")

(defconst etaf-ncm--meter-host 'ncm-meter
  "Retained Host that fills the player bar's progress meter.")

(defconst etaf-ncm--reply-volatile-keys '(:elapsed :as-of)
  "Status fields that move with every backend reply, not with the track.")

(defun etaf-ncm--runtime (app)
  "Return APP's mounted runtime, or nil when nothing displays APP."
  (let ((buffer (plist-get app :buffer)))
    (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer))))

(defun etaf-ncm--meter-percent (app seconds)
  "Return the progress meter fill for SECONDS in APP, as a percentage."
  (let ((duration (or (plist-get (etaf-ncm--read app :status) :duration) 0)))
    (* 100.0 (etaf-ncm--ratio seconds duration))))

(defun etaf-ncm--meter-width (ratio)
  "Return the fractional filled width at RATIO."
  (list '% (* 100.0 (etaf-ncm--ratio ratio 1))))

(defun etaf-ncm--clock-line (app)
  "Return the lyric line index APP shows for its displayed position, or nil."
  (let* ((lyric (etaf-ncm--read app :lyric))
         (lines (plist-get lyric :lines)))
    (and lines (etaf-ncm--lyric-index lines (etaf-ncm--clock app)))))

(defun etaf-ncm--update-clock-hosts (app seconds)
  "Replace APP's elapsed label and progress fill with SECONDS.
Both writes go through ETAF's retained Host boundary, so a playing second
publishes without a View publication or layout work.  Return nil when APP has
no mounted Runtime; the caller then republishes instead.  A rejected write
signals through ETAF rather than being reported as a missing display."
  (when-let* ((runtime (etaf-ncm--runtime app)))
    (etaf-runtime-update-host-contents
     runtime (list (cons etaf-ncm--clock-host (etaf-ncm--format-seconds seconds))))
    (etaf-runtime-update-host-geometries
     runtime (list (cons etaf-ncm--meter-host
                        (list :width (list '% (round (etaf-ncm--meter-percent app seconds)))))))
    t))

(defun etaf-ncm--republish-clock (app seconds)
  "Publish APP's whole view with SECONDS as the displayed position.
Writing the status is what republishes: the view renders the playback facts
and the position together, so the bar, the lyric panel and every reader of
`:status' agree again."
  (etaf-ncm--write app :status
                   (plist-put (copy-sequence (or (etaf-ncm--read app :status) (list)))
                              :elapsed seconds)))

(defun etaf-ncm--publish-clock (app seconds)
  "Show SECONDS as APP's displayed playback position.
A playing second changes only the position, so the elapsed label and the
progress meter are replaced through their retained Hosts and the view is left
for the moments that really change it: a new lyric line, a seek, or a reply
that carries more than a new position."
  (let ((line (etaf-ncm--clock-line app)))
    (etaf-ncm--set-clock app seconds)
    (if (or (not (eql line (etaf-ncm--clock-line app)))
            (not (etaf-ncm--update-clock-hosts app seconds)))
        (etaf-ncm--republish-clock app seconds))))

(defun etaf-ncm--status-steady (status)
  "Return STATUS without the fields that move with every backend reply."
  (let ((copy (copy-sequence status)))
    (dolist (key etaf-ncm--reply-volatile-keys)
      (setq copy (plist-put copy key nil)))
    copy))

(defun etaf-ncm--status-steady-p (previous status)
  "Return non-nil when STATUS only moves PREVIOUS's volatile fields.
A steady reply reports a new position and measurement time for the same track,
so the player bar updates in place instead of republishing the whole view."
  (and previous
       (equal (etaf-ncm--status-steady previous)
              (etaf-ncm--status-steady status))))

(defun etaf-ncm--client (model)
  "Return MODEL's backend client."
  (plist-get model :client))

(cl-defun etaf-ncm--call (model request &key on-ok on-error)
  "Send REQUEST for MODEL, routing a failure into the visible status line.
ON-OK receives the reply data; ON-ERROR the failure message, its hint and the
backend's error code.  A client that
signals while turning the request into a command is reported like any other
backend failure, so nothing reaches the caller of a player action."
  (let ((delivered nil)
        (fail (lambda (message hint code)
                (etaf-ncm--write model :error message)
                (etaf-ncm--write model :message
                                 (if (and hint (not (string-empty-p hint)))
                                     (format "%s（%s）" message hint)
                                   message))
                (when on-error (funcall on-error message hint code)))))
    (condition-case error
        (etaf-ncm-client-call
         (etaf-ncm--client model) request
         (lambda (result)
           (setq delivered t)
           (if (eq (car result) :ok)
               (progn
                 (etaf-ncm--write model :error nil)
                 (when on-ok (funcall on-ok (cadr result))))
             (funcall fail (or (cadr result) "请求失败")
                      (plist-get (cddr result) :hint)
                      (plist-get (cddr result) :code)))))
      (error (if delivered
                 (signal (car error) (cdr error))
               (funcall fail (error-message-string error) nil nil))))))

(defun etaf-ncm--note (model text)
  "Show TEXT as the player's status line message."
  (etaf-ncm--write model :message text))

;;; ---------------------------------------------------------------------------
;;; Formatting helpers
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--format-duration (milliseconds)
  "Return MILLISECONDS as \"M:SS\" or an empty string."
  (let ((seconds (and (numberp milliseconds) (/ (round milliseconds) 1000))))
    (if (and seconds (> seconds 0))
        (format "%d:%02d" (/ seconds 60) (% seconds 60))
      "")))

(defun etaf-ncm--format-seconds (seconds)
  "Return SECONDS as \"MM:SS\" or \"00:00\"."
  (let ((seconds (if (numberp seconds) (max 0 (round seconds)) 0)))
    (format "%02d:%02d" (/ seconds 60) (% seconds 60))))

(defun etaf-ncm--truthy-string-p (value)
  "Return non-nil when VALUE is the backend's \"true\"."
  (and (stringp value) (string= (downcase (string-trim value)) "true")))

(defun etaf-ncm--parse-number (value)
  "Return VALUE as a number, or nil when it is empty or not numeric."
  (cond ((numberp value) value)
        ((eq value :false) nil)
        ((not (stringp value)) nil)
        (t (let ((text (string-trim value)))
             (and (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)
                  (string-to-number text))))))

;;; ---------------------------------------------------------------------------
;;; Library loading
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--section-label (section)
  "Return the sidebar label of SECTION, or nil."
  (seq-some (lambda (group)
              (when-let* ((entry (assq section (cdr group))))
                (nth 1 entry)))
            etaf-ncm-sections))

(defun etaf-ncm-locate (app section)
  "Show library SECTION in APP and load its rows.
SECTION is one of the keys in `etaf-ncm-sections'.  A cached list is shown at
once and refreshed in the background; the first visit waits for the backend,
and a reply from an earlier library is discarded.  Unknown SECTION signals
`etaf-ncm-error'."
  (unless (and (symbolp section) (or (eq section :search)
                                     (etaf-ncm--section-label section)))
    (signal 'etaf-ncm-error (list (format "Unknown library: %S" section))))
  (let* ((key (list :browse section))
         (same-p (equal key (plist-get app :list-key))))
    (etaf-batch
      (etaf-ncm--write app :mode 'browse)
      (etaf-ncm--write app :pane 'list)
      (etaf-ncm--write app :section section)
      (etaf-ncm--write app :title (or (etaf-ncm--section-label section) "音乐库"))
      (etaf-ncm--write app :subtitle (or (cdr (assq section etaf-ncm--section-subtitles)) ""))
      (etaf-ncm--write app :origin (list :kind section))
      (setf (plist-get app :list-key) key)
      (etaf-ncm--show-cached-list app key same-p))
    (etaf-ncm--load app key (etaf-ncm--browse-request app section)
                    (and (etaf-ncm--list-entry app key) t) same-p)))

(defun etaf-ncm-search (app keyword &optional scope)
  "Search KEYWORD in APP and show the matches.
SCOPE is `song' (default) or `playlist'.  An empty KEYWORD signals
`etaf-ncm-error' instead of querying the backend."
  (let* ((keyword (string-trim (or keyword "")))
         (scope (or scope 'song)))
    (when (string-empty-p keyword)
      (signal 'etaf-ncm-error '("搜索关键词不能为空")))
    (let ((key (list :search keyword scope))
          (request (list :op :search :keyword keyword
                         :scope scope
                         :limit (etaf-ncm--read app :page-size)
                         :resource (if (eq scope 'playlist) :playlists :songs)))
          (same-p (equal (list :search keyword scope)
                         (plist-get app :list-key))))
      (etaf-batch
        (etaf-ncm--write app :mode 'search)
        (etaf-ncm--write app :section :search)
        (etaf-ncm--write app :query keyword)
        (etaf-ncm--write app :title "搜索结果")
        (etaf-ncm--write app :subtitle (format "关键词：%s" keyword))
        (etaf-ncm--write app :origin nil)
        (setf (plist-get app :list-key) key)
        (etaf-ncm--show-cached-list app key same-p))
      (etaf-ncm--load app key request (and (etaf-ncm--list-entry app key) t)
                      same-p))))

(defun etaf-ncm--browse-request (app section)
  "Return the backend browse REQUEST for APP's SECTION."
  (list :op :browse :resource section
        :limit (max etaf-ncm-list-limit etaf-ncm-fetch-limit
                    (* 3 (etaf-ncm--read app :page-size)))))

(defun etaf-ncm--list-entry (app key)
  "Return APP's cached library list for KEY, or nil."
  (etaf-list-cache-entry (plist-get app :list-cache) key))

(defun etaf-ncm--store-list (app key rows total)
  "Cache ROWS and TOTAL for KEY in APP."
  (etaf-list-cache-put (plist-get app :list-cache) key rows total))

(defun etaf-ncm--show-cached-list (app key keep-position-p)
  "Show APP's cached rows for KEY when one exists, without a loading state.
KEEP-POSITION-P leaves the reader where they are, for a refresh of the list
they are already looking at."
  (let ((entry (etaf-ncm--list-entry app key)))
    (etaf-batch
      (etaf-ncm--write app :rows (plist-get entry :rows))
      (etaf-ncm--write app :list-total (or (plist-get entry :total) 0))
      (if keep-position-p
          (etaf-ncm--clamp-list-position app)
        (etaf-ncm--write app :selection 0)
        (etaf-ncm--write app :window-start 0))
      (etaf-ncm--write app :loading nil))))

(defun etaf-ncm--clamp-list-position (app)
  "Keep APP's selection and page inside its current rows."
  (let* ((total (length (etaf-ncm--read app :rows)))
         (size (max 1 (etaf-ncm--read app :page-size))))
    (etaf-ncm--write app :selection
                     (max 0 (min (max 0 (1- total))
                                 (etaf-ncm--read app :selection))))
    (etaf-ncm--write app :window-start
                     (max 0 (min (etaf-ncm--read app :window-start)
                                 (max 0 (- total size)))))))

(defun etaf-ncm--load (app key request &optional background keep-position-p)
  "Load REQUEST for APP, caching its rows under KEY.
BACKGROUND requests leave the visible loading state to the foreground load
they refresh: their reply replaces the cache and repaints only while KEY is
still the visible list, without resetting the reader's position.
KEEP-POSITION-P also keeps the position of a foreground reload of the list the
reader is already looking at."
  (let ((generation (1+ (etaf-ncm--read app :generation)))
        (kind (or (plist-get request :resource) (plist-get request :op))))
    (unless background
      (etaf-ncm--write app :generation generation)
      (etaf-ncm--write app :loading t)
      (etaf-ncm--write app :error nil))
    (etaf-ncm--call
     app request
     :on-ok (lambda (data)
              (let* ((rows (etaf-ncm--library-rows kind data))
                     (total (or (etaf-ncm--parse-number (plist-get data :total))
                                (length rows))))
                (etaf-ncm--store-list app key rows total)
                (etaf-list-cache-note-success (plist-get app :list-cache))
                (if background
                    (progn
                      (etaf-list-cache-set-busy (plist-get app :list-cache) nil)
                      (when (equal key (plist-get app :list-key))
                        (etaf-batch
                          (etaf-ncm--write app :rows rows)
                          (etaf-ncm--write app :list-total total)
                          (etaf-ncm--clamp-list-position app))))
                  (when (and (= generation (etaf-ncm--read app :generation))
                             (equal key (plist-get app :list-key)))
                    (etaf-batch
                      (etaf-ncm--write app :rows rows)
                      (etaf-ncm--write app :list-total total)
                      (if keep-position-p
                          (etaf-ncm--clamp-list-position app)
                        (etaf-ncm--write app :selection 0)
                        (etaf-ncm--write app :window-start 0))
                      (etaf-ncm--write app :loading nil)
                      (etaf-ncm--note app (format "%s · %d 项"
                                                  (etaf-ncm--read app :title)
                                                  (length rows))))))))
     :on-error (lambda (message _hint code)
                 (etaf-list-cache-note-failure (plist-get app :list-cache) code)
                 (if background
                     (etaf-list-cache-set-busy (plist-get app :list-cache) nil)
                   (when (and (= generation (etaf-ncm--read app :generation))
                              (equal key (plist-get app :list-key)))
                     (etaf-ncm--write app :loading nil)
                     (etaf-ncm--write app :rows nil)
                     (etaf-ncm--write app :list-total 0)
                     (etaf-ncm--note app message)))))))

(defun etaf-ncm--cache-visible-p (app)
  "Return non-nil when APP's buffer can be seen, or the session is headless.
A mounted player that no window shows pauses its background library refresh:
nobody is looking at it, so the network can wait until it is shown again."
  (let ((buffer (plist-get app :buffer)))
    (or (null buffer)
        (and (buffer-live-p buffer)
             (get-buffer-window buffer t)))))

(defun etaf-ncm--background-list (app now)
  "Return the (KEY . REQUEST) APP should refresh in the background, or nil.
The stalest cached list is refreshed first; when every sidebar list is still
fresh, one not-yet-cached list is warmed so opening it can use the cache.
`etaf-list-cache' owns that order, the freshness interval and the quiet period
after the session starts; this function only maps a section to its request."
  (when (and etaf-ncm-prefetch-libraries
             (etaf-ncm--cache-visible-p app)
             (not (etaf-ncm--read app :loading)))
    (let* ((sections (mapcar #'car (apply #'append (mapcar #'cdr etaf-ncm-sections))))
           (pairs (mapcar (lambda (section) (cons (list :browse section) section))
                          sections))
           (key (etaf-list-cache-next (plist-get app :list-cache)
                                      (mapcar #'car pairs)
                                      now etaf-ncm-library-refresh-interval)))
      (when key
        (let ((section (cdr (assq key pairs))))
          (cons key (list :request (etaf-ncm--browse-request app section))))))))

(defun etaf-ncm--refresh-background-list (app now)
  "Start one stale background library refresh for APP, when one is due."
  (when-let* ((next (etaf-ncm--background-list app now)))
    (etaf-list-cache-set-busy (plist-get app :list-cache) t)
    (etaf-ncm--load app (car next) (plist-get (cdr next) :request) t)))

(defun etaf-ncm--library-rows (kind data)
  "Map backend DATA of KIND into library rows."
  (pcase kind
    ((or :daily :liked :fm :recent :search :songs)
     (etaf-ncm--song-rows (plist-get data :songs)))
    (:playlists (etaf-ncm--playlist-rows (plist-get data :playlists)))
    (:charts (etaf-ncm--chart-rows (plist-get data :charts)))
    (:albums (etaf-ncm--album-rows (plist-get data :albums)))
    (:artists (etaf-ncm--artist-rows (plist-get data :artists)))
    (:podcasts (etaf-ncm--podcast-rows (plist-get data :podcasts)))
    (_ nil)))

(defun etaf-ncm--song-rows (songs)
  "Return SONG plists as playable rows."
  (cl-loop for song in (etaf-ncm--list songs)
           for id = (etaf-ncm--parse-number (plist-get song :id))
           when id
           collect (list :kind :song
                         :id id
                         :name (etaf-ncm--string (plist-get song :name))
                         :subtitle (etaf-ncm--string (plist-get song :artist))
                         :meta (etaf-ncm--string (plist-get song :album))
                         :badge (if (eq t (plist-get song :vip)) "VIP" nil)
                         :right (etaf-ncm--format-duration
                                 (etaf-ncm--parse-number (plist-get song :ms)))
                         :plays (etaf-ncm--parse-number (plist-get song :plays)))))

(defun etaf-ncm--playlist-rows (playlists)
  "Return PLAYLIST plists as rows that play the whole list."
  (cl-loop for playlist in (etaf-ncm--list playlists)
           for id = (etaf-ncm--parse-number (plist-get playlist :id))
           when id
           collect (list :kind :playlist
                         :id id
                         :name (etaf-ncm--string (plist-get playlist :name))
                         :subtitle (etaf-ncm--string (plist-get playlist :creator))
                         :meta (format "%s 首"
                                       (or (etaf-ncm--parse-number
                                            (plist-get playlist :count)) 0))
                         :badge (cond ((eq t (plist-get playlist :sub)) "收藏")
                                      ((etaf-ncm--parse-number
                                        (plist-get playlist :special)) "喜欢")
                                      (t nil))
                         :right "")))

(defun etaf-ncm--chart-rows (charts)
  "Return CHART plists as rows that play the whole chart."
  (cl-loop for chart in (etaf-ncm--list charts)
           for id = (etaf-ncm--parse-number (plist-get chart :id))
           when id
           collect (list :kind :chart
                         :id id
                         :name (etaf-ncm--string (plist-get chart :name))
                         :subtitle (etaf-ncm--string (plist-get chart :freq))
                         :meta (format "%s 首"
                                       (or (etaf-ncm--parse-number
                                            (plist-get chart :count)) 0))
                         :badge nil :right "")))

(defun etaf-ncm--album-rows (albums)
  "Return ALBUM plists as rows that play the whole album."
  (cl-loop for album in (etaf-ncm--list albums)
           for id = (etaf-ncm--parse-number (plist-get album :id))
           when id
           collect (list :kind :album
                         :id id
                         :name (etaf-ncm--string (plist-get album :name))
                         :subtitle (etaf-ncm--string (plist-get album :artist))
                         :meta (format "%s 首"
                                       (or (etaf-ncm--parse-number
                                            (plist-get album :size)) 0))
                         :badge nil :right "")))

(defun etaf-ncm--artist-rows (artists)
  "Return ARTIST plists as rows that play the artist's popular songs."
  (cl-loop for artist in (etaf-ncm--list artists)
           for id = (etaf-ncm--parse-number (plist-get artist :id))
           when id
           collect (list :kind :artist
                         :id id
                         :name (etaf-ncm--string (plist-get artist :name))
                         :subtitle "歌手"
                         :meta (format "%s 张专辑"
                                       (or (etaf-ncm--parse-number
                                            (plist-get artist :albums)) 0))
                         :badge nil :right "")))

(defun etaf-ncm--podcast-rows (podcasts)
  "Return PODCAST plists as rows that play the latest episodes."
  (cl-loop for podcast in (etaf-ncm--list podcasts)
           for id = (etaf-ncm--parse-number (plist-get podcast :id))
           when id
           collect (list :kind :podcast
                         :id id
                         :name (etaf-ncm--string (plist-get podcast :name))
                         :subtitle (etaf-ncm--string (plist-get podcast :dj))
                         :meta (format "%s 期"
                                       (or (etaf-ncm--parse-number
                                            (plist-get podcast :episodes)) 0))
                         :badge nil :right "")))

;;; ---------------------------------------------------------------------------
;;; Playback
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-play (app &optional item)
  "Play ITEM in APP, or the current library when ITEM is nil.
ITEM is a library row, a song id, or a keyword string.  A song row in a
playable library queues that library, then jumps to its loaded-list position
after playback succeeds.  Other targets play directly.  ITEM nil replays the
whole current library."
  (let* ((target (etaf-ncm--target app item))
         (origin (etaf-ncm--playable-origin app))
         (rows (etaf-ncm--read app :rows))
         (index (and origin (listp item) (eq (plist-get item :kind) :song)
                     (or (cl-position item rows :test #'eq)
                         (cl-position item rows :test #'equal))))
         (generation (cl-incf (plist-get app :play-generation)))
         (message (format "正在播放：%s" (etaf-ncm--target-label app item))))
    (etaf-ncm--command
     app (list :op :play :target (if index origin target)) message
     (when index
       (lambda ()
         ;; A late list reply must not jump over a newer play request or
         ;; restart a session that was closed while the list was loading.
         (when (and (= generation (plist-get app :play-generation))
                    (not (plist-get app :disposed)))
           (etaf-ncm--command app (list :op :jump :index (1+ index)) message)))))))

(defun etaf-ncm--playable-origin (app)
  "Return APP's origin when the backend can play it as a whole list."
  (let ((origin (etaf-ncm--read app :origin)))
    (and (assq (plist-get origin :kind) etaf-ncm--play-commands) origin)))

(defun etaf-ncm-add-to-queue (app item)
  "Append ITEM to APP's queue without interrupting the current song."
  (let ((id (etaf-ncm--item-id item)))
    (unless id
      (signal 'etaf-ncm-error '("只能把单曲加入队列")))
    (etaf-ncm--command app (list :op :add :id id)
                       (format "已加入队列：%s" (etaf-ncm--item-name item)))))

(defun etaf-ncm-jump-queue (app index)
  "Play queue entry INDEX (counting from 1) in APP."
  (etaf-ncm--command app (list :op :jump :index index)
                     (format "切到队列第 %s 首" index)))

(defun etaf-ncm-toggle-playback (app)
  "Pause or resume APP, or start APP's selected song when nothing is loaded.
The toggle reaches the backend as one command, and a queue the backend
reports as empty has nothing to toggle: the selection plays instead, which is
what a person expects after selecting a song and pressing SPC or the play
pill.  Before any status has arrived the toggle is sent unchanged, so an
app still reading a pending session never starts a library item instead."
  (let* ((status (etaf-ncm--read app :status))
         (loaded (or (null status)
                     (not (equal (or (plist-get status :title) "") ""))
                     (> (or (plist-get status :queue-count) 0) 0))))
    (if loaded
        (etaf-ncm--command app (list :op :toggle) "已切换播放状态")
      (if-let* ((row (etaf-ncm--selected-row app)))
          (etaf-ncm-play app row)
        (etaf-ncm--note app "先选中一首歌再播放")))))

(defun etaf-ncm-next-track (app)
  "Play the next song in APP's queue."
  (etaf-ncm--command app (list :op :next) "下一首"))

(defun etaf-ncm-previous-track (app)
  "Play the previous song in APP's queue."
  (etaf-ncm--command app (list :op :previous) "上一首"))

(defun etaf-ncm-stop (app)
  "Stop playback in APP and keep the queue."
  (etaf-ncm--command app (list :op :stop) "已停止播放"))

(defun etaf-ncm-set-volume (app volume)
  "Set APP's volume to VOLUME, an integer between 0 and 100.
The bar's fill and the percentage label share this scale.  A value outside
that range signals `etaf-ncm-error'."
  (unless (and (numberp volume) (<= 0 volume 100))
    (signal 'etaf-ncm-error (list (format "音量要在 0-100 之间：%S" volume))))
  (etaf-ncm--command app (list :op :volume :value (round volume))
                     (format "音量 %d" (round volume))))

(defun etaf-ncm-seek (app seconds)
  "Move APP's playback position by SECONDS relative to the current one.
The target stays displayed for a short window: an asynchronous backend keeps
reporting the old position until mpv applies the seek, and without the guard
the progress bar jumps back and forth around the click."
  (unless (numberp seconds)
    (signal 'etaf-ncm-error (list (format "进度偏移必须是秒数：%S" seconds))))
  (etaf-ncm--write app :seek-guard
                   (cons (+ (float-time) 3.0)
                         (max 0 (+ (etaf-ncm--clock app) (round seconds)))))
  (etaf-ncm--command app (list :op :seek :seconds (round seconds))
                     (format "进度 %s%ss" (if (< seconds 0) "-" "+") (abs (round seconds)))))

(defun etaf-ncm-set-shuffle (app on)
  "Turn queue shuffling in APP ON or off."
  (etaf-ncm--command app (list :op :shuffle :on (and on t))
                     (if on "随机播放：开" "随机播放：关")))

(defun etaf-ncm-set-repeat (app on)
  "Turn list repeat (列表循环) in APP ON or off."
  (etaf-ncm--command app (list :op :repeat :on (and on t))
                     (if on "列表循环：开" "列表循环：关")))

(defun etaf-ncm-like (app &optional unlike)
  "Like the song playing in APP, or unlike it when UNLIKE is non-nil.
The heart flips before the backend answers; a failed request puts the
previous state back, and the reply reconciles it with measured facts."
  (let ((previous (plist-get (or (etaf-ncm--read app :status) (list)) :liked)))
    (etaf-ncm--note app (if unlike "已取消喜欢" "已加入我喜欢的音乐"))
    (etaf-ncm--optimistic-status
     app (lambda (status) (plist-put status :liked (not unlike))))
    (etaf-ncm--call app (list :op (if unlike :unlike :like))
                    :on-ok (lambda (_data) (etaf-ncm--request-status app))
                    :on-error (lambda (_message _hint _code)
                                (etaf-ncm--optimistic-status
                                 app (lambda (status)
                                       (plist-put status :liked previous)))))))

(defconst etaf-ncm--queue-commands '(:play :next :previous :jump :stop :add)
  "Commands whose reply can move the queue, which is then reloaded.")

(defun etaf-ncm--optimistic-status (app update)
  "Publish UPDATE over APP's displayed playback status.
A transport command shows its local effect before the backend confirms it; the
reply then replaces that guess with measured facts."
  (etaf-ncm--write app :status
                   (funcall update
                            (copy-sequence (or (etaf-ncm--read app :status)
                                               (list))))))

(defun etaf-ncm--optimistic-command (app request)
  "Publish REQUEST's locally known effect in APP before its reply arrives."
  (pcase (plist-get request :op)
    (:toggle
     (etaf-ncm--optimistic-status
      app (lambda (status)
            (plist-put status :state
                       (if (eq (plist-get status :state) 'playing)
                           'paused
                         'playing)))))
    (:stop
     (etaf-ncm--optimistic-status
      app (lambda (status) (plist-put status :state 'stopped))))
    (:play
     (let ((id (let ((target (plist-get request :target)))
                 (and (eq (plist-get target :kind) :song)
                      (plist-get target :id)))))
       (etaf-ncm--set-clock app 0)
       (etaf-ncm--optimistic-status
        app (lambda (status)
              (setq status (plist-put status :state 'playing))
              (setq status (plist-put status :elapsed 0))
              (if id (plist-put status :song-id id) status)))))
    (:volume
     (etaf-ncm--optimistic-status
      app (lambda (status)
            (plist-put status :volume (plist-get request :value)))))
    (:shuffle
     (etaf-ncm--optimistic-status
      app (lambda (status)
            (plist-put status :shuffle (plist-get request :on)))))
    (:repeat
     (etaf-ncm--optimistic-status
      app (lambda (status)
            (plist-put status :repeat (plist-get request :on)))))
    (_ nil)))

(defun etaf-ncm--command (app request message &optional on-ok)
  "Send REQUEST for APP, showing MESSAGE and its local effect immediately.
The backend reply reconciles the optimistic state; only a command that can
move the queue reloads it.  ON-OK, when given, continues a command sequence
instead of reconciling an intermediate playback state."
  (when (memq (plist-get request :op) '(:next :previous :stop :jump))
    (cl-incf (plist-get app :play-generation)))
  (etaf-batch
    (etaf-ncm--note app message)
    (etaf-ncm--optimistic-command app request))
  (etaf-ncm--call app request
                  :on-ok (lambda (_data)
                           (if on-ok
                               (funcall on-ok)
                             (etaf-batch
                               (etaf-ncm--request-status app)
                               (when (memq (plist-get request :op)
                                           etaf-ncm--queue-commands)
                                 (etaf-ncm--request-queue app)))))))

(defconst etaf-ncm--double-press-window 1.0
  "Seconds within which a second press on the same row counts as a double press.
The window is generous on purpose: publishing a selection can take a moment,
and the gesture must not depend on how long the previous press took.")

(defun etaf-ncm--press-row (app entry)
  "Select the row of ENTRY in APP, or play it when it was pressed twice.
ENTRY is a list entry as `etaf-ncm--view-entries' builds it.  A press on the
row that is already selected plays it: the gesture then does not depend on a
second press arriving inside a timing window, which a slow repaint can miss."
  (let* ((row (plist-get entry :row))
         (id (plist-get row :id))
         (now (float-time))
         (last (plist-get app :last-press))
         (selection (etaf-ncm--read app :selection))
         (index (max 0 (1- (or (plist-get entry :index) 1))))
         (delta (- index selection))
         (repeat-p (and last (equal (car last) id)
                        (< (- now (cdr last)) etaf-ncm--double-press-window))))
    (setf (plist-get app :last-press)
          (unless (or repeat-p (= index selection)) (cons id now)))
    (etaf-batch
      (if (or repeat-p (= index selection))
          (etaf-ncm-play app row)
        (progn
          (etaf-ncm-move-selection app delta)
          (etaf-ncm--note app (format "已选中：%s（再点一次播放）"
                                      (or (plist-get row :name) "这一行"))))))))

(defun etaf-ncm-press-row (app index)
  "Press library row INDEX (counting from 1) in APP.
Select the row, or play it when it is the selected row or was pressed twice in
quick succession; this is the gesture a click on a list row performs.  An
out-of-range INDEX signals `etaf-ncm-error'."
  (let ((row (nth (1- index) (etaf-ncm--read app :rows))))
    (unless row
      (signal 'etaf-ncm-error (list (format "没有第 %s 行" index))))
    (etaf-ncm--press-row app (list :row row :index index))))

(defun etaf-ncm-seek-to (app seconds)
  "Seek APP to the absolute position SECONDS.
The player bar's range component reports absolute positions, while the backend
seeks by offset: show the target immediately, then ask for the difference."
  (unless (numberp seconds)
    (signal 'etaf-ncm-error (list (format "进度目标必须是秒数：%S" seconds))))
  (let* ((current (etaf-ncm--clock app))
         (target (max 0 seconds))
         (last (plist-get app :seek-commit)))
    ;; A range press reports its commit once, but a duplicated pointer event
    ;; must not apply the same seek twice.
    (unless (and last (equal (car last) target)
                 (< (- (float-time) (cdr last)) 0.8))
      (plist-put app :seek-commit (cons target (float-time)))
      (etaf-ncm--set-clock app target)
      (etaf-ncm--republish-clock app target)
      (etaf-ncm-seek app (round (- target current))))))

(defun etaf-ncm--target (app item)
  "Return the backend play target for ITEM inside APP."
  (cond
   ((null item) (or (etaf-ncm--read app :origin) '(:kind :daily)))
   ((listp item)
    (let ((kind (plist-get item :kind))
          (id (plist-get item :id)))
      (if (memq kind '(:song :playlist :album :artist :chart :podcast :episode))
          (list :kind kind :id id)
        (signal 'etaf-ncm-error (list (format "不能播放这一行：%S" item))))))
   ((numberp item) (list :kind :song :id item))
   ((and (stringp item) (not (string-empty-p (string-trim item))))
    (list :kind :query :id (string-trim item)))
   (t (signal 'etaf-ncm-error (list (format "不能播放：%S" item))))))

(defun etaf-ncm--target-label (app item)
  "Return a human label for ITEM in APP, used in the status line."
  (cond
   ((null item)
    (or (etaf-ncm--section-label (etaf-ncm--read app :section))
        (format "%s" (etaf-ncm--read app :origin))))
   ((listp item) (or (plist-get item :name) "选中项"))
   (t (format "%s" item))))

(defun etaf-ncm--item-id (item)
  "Return ITEM's song id when ITEM names a song."
  (when (and (listp item) (eq (plist-get item :kind) :song))
    (plist-get item :id)))

(defun etaf-ncm--item-name (item)
  "Return ITEM's display name."
  (cond ((listp item) (or (plist-get item :name) "这一项"))
        ((numberp item) (format "%s" item))
        (t (format "%s" item))))

;;; ---------------------------------------------------------------------------
;;; Playback status, queue and lyric
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-refresh (app)
  "Reload APP's library, playback status, queue and account.
The library reload also re-fits the layout and row count to APP's window; it
refreshes the list the view already shows, so the reader's position is kept."
  (etaf-ncm--write app :error nil)
  (etaf-ncm--sync-layout app)
  (setf (plist-get app :polled-at) 0)
  (if (eq (etaf-ncm--read app :mode) 'search)
      (let* ((query (etaf-ncm--read app :query))
             (key (list :search query 'song)))
        (setf (plist-get app :list-key) key)
        (etaf-ncm--load app key
                        (list :op :search :keyword query :scope 'song
                              :resource :songs
                              :limit (max etaf-ncm-fetch-limit
                                          (* 3 (etaf-ncm--read app :page-size))))
                        nil t))
    (let* ((section (etaf-ncm--read app :section))
           (key (list :browse section)))
      (setf (plist-get app :list-key) key)
      (etaf-ncm--load app key (etaf-ncm--browse-request app section) nil t)))
  (etaf-ncm--request-status app)
  (etaf-ncm--request-queue app)
  (etaf-ncm--request-account app))

(defun etaf-ncm--request-account (app)
  "Load APP's account display name."
  (etaf-ncm--call app (list :op :session)
                  :on-ok (lambda (data)
                           (etaf-ncm--write app :account
                                            (list :nick (etaf-ncm--string (plist-get data :nick))
                                                  :uid (etaf-ncm--parse-number (plist-get data :uid))
                                                  :vip (plist-get data :vip)
                                                  :logged-in (eq t (plist-get data :loggedIn)))))))

(defun etaf-ncm--request-status (app)
  "Ask the backend for APP's playback truth.
The reply carries the position measured when the backend answered, so the
round trip is added back before publishing it: without that the lyric line and
the progress bar run one backend latency behind the song."
  (setf (plist-get app :status-in-flight) t
        (plist-get app :requested-at) (float-time))
  (etaf-ncm--call
   app (list :op :status)
   :on-ok (lambda (data)
            (let* ((now (float-time))
                   (trip (- now (or (plist-get app :requested-at) now)))
                   (status (etaf-ncm--normalize-status data))
                   (elapsed (or (plist-get status :elapsed) 0)))
              (setf (plist-get app :status-in-flight) nil
                    (plist-get app :polled-at) now
                    (plist-get app :last-tick) now)
              (etaf-ncm--apply-status
               app (plist-put status :elapsed (+ elapsed trip)))))
   :on-error (lambda (_message _hint _code)
               (setf (plist-get app :status-in-flight) nil
                     (plist-get app :polled-at) (float-time)))))

(defun etaf-ncm--apply-status (app status)
  "Publish STATUS and fetch the lyric when the song changed.
A reply that only moves the position is displayed through
`etaf-ncm--publish-clock', so a playing second does not republish the view; a
reply that carries new playback facts publishes `:status'."
  (let* ((previous (etaf-ncm--read app :status))
         (song-id (plist-get status :song-id))
         (lyric (etaf-ncm--read app :lyric))
         (elapsed (or (plist-get status :elapsed) 0)))
    ;; A seek that mpv has not applied yet must not drag the bar back: keep
    ;; showing the requested target until the backend reaches it or the guard
    ;; expires.
    (let ((guard (etaf-ncm--read app :seek-guard)))
      (when guard
        (let ((until (car guard)) (target (cdr guard)))
          (cond ((and (< (float-time) until)
                      (> (abs (- (or elapsed 0) target)) 1))
                 (setq elapsed target)
                 (setq status (plist-put status :elapsed target)))
                ((or (>= (float-time) until)
                     (<= (abs (- (or elapsed 0) target)) 1))
                 (etaf-ncm--write app :seek-guard nil))))))
    ;; The backend status carries no like state; carry the one this session
    ;; knows into the same-song comparison and keep it for the new status.
    (setq status (plist-put status :liked
                            (and previous
                                 (equal song-id (plist-get previous :song-id))
                                 (plist-get previous :liked))))
    (if (etaf-ncm--status-steady-p previous status)
        (etaf-ncm--publish-clock app elapsed)
      (etaf-ncm--set-clock app elapsed)
      (etaf-ncm--write app :status status))
    (when (and song-id (not (equal song-id (plist-get lyric :id))))
      (etaf-ncm--request-lyric app song-id))
    (when (and previous
               (or (not (equal (plist-get status :queue-pos)
                               (plist-get previous :queue-pos)))
                   (and (plist-get previous :song-id) song-id
                        (not (equal song-id (plist-get previous :song-id))))))
      (etaf-ncm--request-queue app))))

(defun etaf-ncm--status-flag (value)
  "Read a boolean or numeric status flag VALUE supplied by the backend."
  (or (eq value t) (and (numberp value) (> value 0))
      (and (stringp value) (member (downcase value) '("true" "1" "yes")))))

(defun etaf-ncm--status-quality (data)
  "Return DATA's supplied quality label, or nil when no hint was reported."
  (let ((quality (string-trim (etaf-ncm--string (plist-get data :quality))))
        (bitrate (plist-get data :bitrate))
        (hint (string-trim (etaf-ncm--string (plist-get data :vip_hint)))))
    (cond ((or (etaf-ncm--status-flag (plist-get data :lossless))
               (member (downcase quality) '("lossless" "flac" "无损"))) "无损")
          ((not (string-empty-p quality)) quality)
          ((and bitrate (not (string-empty-p (etaf-ncm--string bitrate))))
           (let ((number (etaf-ncm--parse-number bitrate)))
             (if number
                 (format "%g kbps" (if (> number 1000) (/ number 1000.0) number))
               (etaf-ncm--string bitrate))))
          ((not (string-empty-p hint)) hint)
          ((etaf-ncm--status-flag (plist-get data :vip)) "VIP"))))

(defun etaf-ncm--normalize-status (data)
  "Return the backend playback DATA as the player's status plist."
  (let* ((position (etaf-ncm--string (plist-get data :queue_pos)))
         (parts (split-string position "/" t)))
    (list :title (etaf-ncm--string (plist-get data :title))
          :artist (etaf-ncm--string (plist-get data :artist))
          :song-id (etaf-ncm--parse-number (plist-get data :song_id))
          :state (intern (or (etaf-ncm--string (plist-get data :state)) "idle"))
          :elapsed (or (etaf-ncm--parse-number (plist-get data :elapsed)) 0)
          :duration (or (etaf-ncm--parse-number (plist-get data :duration)) 0)
          :volume (or (etaf-ncm--parse-number (plist-get data :volume)) 0)
          :vip (and (etaf-ncm--status-flag (plist-get data :vip)) t)
          :quality (etaf-ncm--status-quality data)
          :queue-pos (or (etaf-ncm--parse-number (car parts)) 0)
          :queue-count (or (etaf-ncm--parse-number (cadr parts)) 0)
          :shuffle (etaf-ncm--truthy-string-p (plist-get data :shuffle))
          :repeat (etaf-ncm--truthy-string-p (plist-get data :repeat))
          :as-of (etaf-ncm--string (plist-get data :as_of)))))

(defun etaf-ncm--request-queue (app)
  "Load APP's queue count, index and track list."
  (etaf-ncm--call
   app (list :op :queue :limit 200)
   :on-ok (lambda (data)
            (let ((previous (etaf-ncm--read app :queue))
                  (queue (list :count (or (etaf-ncm--parse-number
                                          (plist-get data :count)) 0)
                               :pos (or (etaf-ncm--parse-number
                                         (plist-get data :pos)) 0)
                               :songs (etaf-ncm--list (plist-get data :songs)))))
              (etaf-batch
                (unless (and (equal (plist-get previous :pos) (plist-get queue :pos))
                             (equal (plist-get previous :songs) (plist-get queue :songs)))
                  (etaf-ncm--write app :queue-start nil))
                (etaf-ncm--write app :queue queue))))))

(defun etaf-ncm--request-lyric (app song-id)
  "Fetch the lyric of SONG-ID for APP."
  (etaf-ncm--write app :lyric (list :id song-id :lines nil :trans nil :loading t))
  (etaf-ncm--call
   app (list :op :lyric :id song-id)
   :on-ok (lambda (data)
            (when (equal song-id (plist-get (etaf-ncm--read app :lyric) :id))
              (etaf-ncm--write app :lyric
                               (list :id song-id
                                     :lines (etaf-ncm-parse-lyric (plist-get data :lyric))
                                     :trans (etaf-ncm-parse-lyric (plist-get data :trans))
                                     :loading nil))))
   :on-error (lambda (_message _hint _code)
               (when (equal song-id (plist-get (etaf-ncm--read app :lyric) :id))
                 (etaf-ncm--write app :lyric
                                  (list :id song-id :lines nil :trans nil :loading nil))))))

(defun etaf-ncm--playing-p (app)
  "Return non-nil when APP currently plays audio."
  (eq (plist-get (etaf-ncm--read app :status) :state) 'playing))

(defun etaf-ncm--tick (app)
  "Advance APP's local clock and poll the backend when due.
While a status request is on its way the clock is left alone: the reply is the
truth and writing a local guess first would repaint the whole view twice a
second for the same second."
  (unless (plist-get app :disposed)
    (let ((now (float-time))
          (last (or (plist-get app :last-tick) 0)))
      (setf (plist-get app :last-tick) now)
      (when (and (etaf-ncm--playing-p app)
                 (not (etaf-ncm--poll-due-p app now)))
        (let* ((elapsed (+ (etaf-ncm--clock app) (- now last)))
               (duration (or (plist-get (etaf-ncm--read app :status) :duration) 0)))
          (etaf-ncm--publish-clock
           app (if (> duration 0) (min elapsed duration) elapsed))))
      (when (etaf-ncm--poll-due-p app now)
        (etaf-ncm--request-status app))
      (etaf-ncm--refresh-background-list app now))))

(defun etaf-ncm--poll-due-p (app now)
  "Return non-nil when APP should ask the backend for status at NOW."
  (and (not (plist-get app :status-in-flight))
       (or (etaf-ncm--playing-p app)
           (> (- now (or (plist-get app :polled-at) 0))
              etaf-ncm-idle-poll-interval))))

(defun etaf-ncm--start (app)
  "Start APP's playback polling; remounting a disposed session revives it."
  (setf (plist-get app :disposed) nil
        (plist-get app :polled-at) 0
        (plist-get app :last-tick) (float-time))
  (etaf-list-cache-start (plist-get app :list-cache))
  (etaf-ncm--sync-layout app)
  (add-hook 'window-size-change-functions #'etaf-ncm--window-size-change)
  (unless (plist-get app :timer)
    (setf (plist-get app :timer)
          (run-with-timer etaf-ncm-status-interval etaf-ncm-status-interval
                          (lambda () (etaf-ncm--tick app))))))

(defun etaf-ncm--dispose (app)
  "Release APP's timer and in-flight requests."
  (setf (plist-get app :disposed) t)
  (etaf-list-cache-disarm (plist-get app :list-cache))
  (cl-incf (plist-get app :play-generation))
  (when-let* ((timer (plist-get app :timer)))
    (cancel-timer timer)
    (setf (plist-get app :timer) nil))
  (etaf-ncm-cancel (etaf-ncm--client app)))

;;; ---------------------------------------------------------------------------
;;; Keyboard navigation and panels
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm--reserved-lines 2
  "Lines the player bar keeps clear above and below itself.
The bar reads as a floating surface: one padding row separates it from the
library above and one closes the window below it (the bar's own vertical
padding).  The page size must leave both out of its row budget, or the bar's
last row is pushed past the window edge.")

(defun etaf-ncm--page-size-for (window &optional layout)
  "Return the library row count that fits WINDOW's height in LAYOUT.
LAYOUT is the layout the rows are rendered in: `narrow' and `medium' spend lines
on chips and pane tabs, while `wide' and an unknown LAYOUT subtract less chrome.
Extra lines stay clear; see `etaf-ncm--reserved-lines'."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         (chrome (+ etaf-ncm--reserved-lines
                    (pcase layout
                      ('narrow 19)
                      ('medium 17)
                      (_ 13)))))
    (max 4 (- height chrome))))

(defun etaf-ncm--window-columns (&optional window)
  "Return WINDOW's body width in columns, or the frame width when it is dead."
  (if (and window (window-live-p window))
      (window-body-width window)
    (frame-width)))

(defun etaf-ncm--viewport-options (&optional window)
  "Return mount viewport options sized for WINDOW, or nil when it is dead.
A mount without them paints at Ebox's default size, which clips the player bar
until the first resize.  The width is the window's body width in pixels, not a
whole number of cells, so the player's background reaches the window edge
instead of stopping one sub-cell short of it.  The player also blanks the
truncation slot, so a remaining sub-cell cannot surface as a truncation glyph."
  (when (and window (window-live-p window))
    (list :viewport-width (window-body-width window t)
          :viewport-height (window-body-height window))))

(defun etaf-ncm--layout-for (columns)
  "Return the layout COLUMNS columns of text can hold.
The result is `wide', `medium' or `narrow'; see `etaf-ncm-wide-columns' and
`etaf-ncm-medium-columns'."
  (cond ((>= columns etaf-ncm-wide-columns) 'wide)
        ((>= columns etaf-ncm-medium-columns) 'medium)
        (t 'narrow)))

(defun etaf-ncm--body-rows-for (height layout)
  "Return the body height below HEIGHT lines of player chrome in LAYOUT.
The root padding, three player lines and its border stay outside the body;
compact layouts also have a two-line pane switch and its border."
  (max 0 (- height etaf-ncm--reserved-lines 4
            (if (eq layout 'wide) 0 3))))

(defun etaf-ncm--sync-layout (app &optional window)
  "Match APP's layout, pane visibility and row budgets to WINDOW.
WINDOW defaults to the window showing APP's buffer.  A headless session keeps
the wide layout, because it has no viewport to adapt to."
  (let* ((buffer (plist-get app :buffer))
         (window (or window
                     (and (buffer-live-p buffer) (get-buffer-window buffer t))))
         (layout (if window
                     (etaf-ncm--layout-for (etaf-ncm--window-columns window))
                   'wide))
         (size (etaf-ncm--page-size-for window layout))
         (height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         ;; Aside padding, tabs with their border, and the queue heading.
         (queue-rows (max 0 (- (etaf-ncm--body-rows-for height layout) 7))))
    (etaf-batch
      (when (eq layout 'wide)
        (etaf-ncm--write app :pane 'list))
      (etaf-ncm--write app :layout layout)
      (etaf-ncm--write app :page-size size)
      (etaf-ncm--write app :queue-rows queue-rows)
      ;; The lyric cover, spacer and footer take seven more lines than the
      ;; queue heading.  Translations share this budget with lyric lines.
      (etaf-ncm--write app :lyric-rows (max 0 (- queue-rows 7))))
    layout))

(defvar etaf-ncm--resize-timer nil
  "Pending trailing task that applies the latest window sizes.")

(defvar etaf-ncm--resize-frames nil
  "Frames whose window sizes changed since the last applied batch.")

(defvar etaf-ncm--resize-settle-delay 0.12
  "Seconds of quiet after the last resize event before applying a layout.
Applying the layout writes library, layout and page-size readings, and every
write republishes the whole view.  Dragging an edge fires far more events than
one publication costs, so apply once the drag settles instead of per event.")

(defun etaf-ncm--window-size-change (frame)
  "Record FRAME's size change; apply it once the resize settles."
  (when (frame-live-p frame)
    (cl-pushnew frame etaf-ncm--resize-frames)
    (when etaf-ncm--resize-timer
      (cancel-timer etaf-ncm--resize-timer))
    (setq etaf-ncm--resize-timer
          (run-at-time etaf-ncm--resize-settle-delay nil
                       #'etaf-ncm--window-size-change-apply))))

(defun etaf-ncm--settle-canvas (app window)
  "Repaint APP's canvas at WINDOW's settled size.
A player mounted before the window manager finished resizing its frame keeps the
canvas it painted at mount: Ebox records the window's width in its render state
while the painted rows still belong to the old viewport, so its own resize path
sees nothing to do.  Repainting once at a neighbouring width and once at the
real width replaces that stale canvas.  A session without a mounted view, or a
rejected repaint, is left alone."
  (let* ((buffer (plist-get app :buffer))
         (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
         (live (and window (window-live-p window)))
         (width (and live (* (window-body-width window) (window-font-width window))))
         (height (and live (window-body-height window)))
         (mounted (plist-get app :mounted-width)))
    (when (and runtime width height mounted (> width mounted))
      (condition-case nil
          (progn
            (etaf-runtime-refit runtime (max 1 (1- width)) height)
            (etaf-runtime-refit runtime width height)
            (setf (plist-get app :mounted-width) width))
        (error nil)))))

(defun etaf-ncm--window-size-change-apply ()
  "Adapt every mounted player to its window's settled size."
  (setq etaf-ncm--resize-timer nil)
  (let ((frames (prog1 (nreverse etaf-ncm--resize-frames)
                  (setq etaf-ncm--resize-frames nil))))
    (dolist (frame frames)
      (when (frame-live-p frame)
        (dolist (window (window-list frame 'no-minibuf))
          (let ((buffer (window-buffer window)))
            (when (and (buffer-live-p buffer)
                       (buffer-local-value 'etaf-ncm--model buffer))
              (let* ((model (buffer-local-value 'etaf-ncm--model buffer))
                     (layout (etaf-ncm--read model :layout))
                     (settled (etaf-ncm--sync-layout model window)))
                ;; A window that grew across a layout boundary is the case a
                ;; mount that preceded the frame resize leaves painted at the
                ;; old canvas; a smaller change keeps the ordinary path.
                (unless (eq layout settled)
                  (etaf-ncm--settle-canvas model window))))))))))

(defun etaf-ncm--compact-layout-p (app)
  "Return non-nil when APP shows one pane at a time."
  (not (eq (etaf-ncm--read app :layout) 'wide)))

(defun etaf-ncm--list-shown-p (app)
  "Return non-nil when APP's library list fits in the frame."
  (or (not (etaf-ncm--compact-layout-p app))
      (eq (etaf-ncm--read app :pane) 'list)))

(defun etaf-ncm--aside-shown-p (app)
  "Return non-nil when APP's lyrics and queue panel fits in the frame."
  (or (not (etaf-ncm--compact-layout-p app))
      (eq (etaf-ncm--read app :pane) 'aside)))

(defun etaf-ncm--page-rows (app)
  "Return the visible slice of APP's rows as (ROWS START TOTAL)."
  (let* ((rows (etaf-ncm--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-ncm--read app :page-size)))
         (start (max 0 (min (etaf-ncm--read app :window-start)
                            (max 0 (- total size))))))
    (list (seq-subseq rows start (min total (+ start size))) start total)))

(defun etaf-ncm--queue-window-start (app)
  "Return the clamped start of APP's loaded queue window, counting from zero.
A nil scroll position centres the window on the playing entry."
  (let* ((queue (etaf-ncm--read app :queue))
         (size (etaf-ncm--read app :queue-rows))
         (total (length (plist-get queue :songs)))
         (start (or (etaf-ncm--read app :queue-start)
                    (- (max 0 (1- (or (plist-get queue :pos) 0))) (/ size 2)))))
    (max 0 (min start (max 0 (- total size))))))

(defun etaf-ncm--scroll-queue (app delta)
  "Move APP's loaded queue window by DELTA rows without changing playback."
  (let* ((total (length (plist-get (etaf-ncm--read app :queue) :songs)))
         (size (etaf-ncm--read app :queue-rows)))
    (etaf-ncm--write app :queue-start
                     (max 0 (min (+ (etaf-ncm--queue-window-start app) delta)
                                 (max 0 (- total size)))))))

(defun etaf-ncm-move-selection (app delta)
  "Move APP's list selection by DELTA rows and keep it inside the page."
  (let* ((rows (etaf-ncm--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-ncm--read app :page-size))))
    (when (> total 0)
      (let ((selection (max 0 (min (1- total)
                                   (+ (etaf-ncm--read app :selection) delta))))
            (start (etaf-ncm--read app :window-start)))
        (cond ((< selection start) (setq start selection))
              ((>= selection (+ start size)) (setq start (- (1+ selection) size))))
        (etaf-ncm--write app :selection selection)
        (etaf-ncm--write app :window-start (max 0 start))))))

(defun etaf-ncm--selected-row (app)
  "Return the row APP's selection points at, or nil."
  (nth (etaf-ncm--read app :selection) (etaf-ncm--read app :rows)))

(defun etaf-ncm-activate-selection (app)
  "Play the row selected in APP."
  (when-let* ((row (etaf-ncm--selected-row app)))
    (etaf-ncm-play app row)))

(defun etaf-ncm-toggle-aside (app)
  "Switch APP's side panel between lyrics and the queue and show it.
In a compact layout, where only one pane fits, this also brings the panel to
the front; `etaf-ncm-show-pane' returns to the library list."
  (etaf-ncm--write app :aside (if (eq (etaf-ncm--read app :aside) 'lyrics) 'queue 'lyrics))
  (unless (eq (etaf-ncm--read app :layout) 'wide)
    (etaf-ncm--write app :pane 'aside)))

(defun etaf-ncm-show-pane (app pane)
  "Show PANE in APP.
PANE is `list' for the library list or `aside' for the lyric and queue panel.
A wide layout shows every column at once, so there PANE is remembered but does
not remove anything from the frame."
  (unless (memq pane '(list aside))
    (signal 'etaf-ncm-error (list (format "Unknown pane: %S" pane))))
  (etaf-ncm--write app :pane pane)
  pane)

(defun etaf-ncm--lyric-index (lines elapsed)
  "Return the index in LINES that ELAPSED seconds falls into."
  (let ((index 0)
        (position 0))
    (while (and (< position (length lines))
                (<= (car (nth position lines)) elapsed))
      (setq index position
            position (1+ position)))
    index))

;;; ---------------------------------------------------------------------------
;;; Detached state for callers and tests
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-state (app)
  "Return APP's session state as a detached plist.
The snapshot is a copy: mutating it never changes the player.  Keys are
`:section', `:title', `:subtitle', `:mode', `:query', `:items' (the library
rows), `:visible' (the rows on the current page), `:selection', `:window-start',
`:page-size', `:rows-total' (loaded count), `:list-total' (backend total or the
loaded count), `:queue-rows', `:queue-start' (zero-based loaded window start),
`:lyric-rows' (display lines including translations), `:status', `:queue',
`:lyric', `:lyric-line', `:aside',
`:layout', `:pane', `:viewport-width' (the pixel canvas the player paints),
`:theme', `:account', `:loading', `:error' and `:message'."
  (let* ((rows (etaf-ncm--read app :rows))
         (page (etaf-ncm--page-rows app))
         (status (plist-put (copy-sequence (or (etaf-ncm--read app :status) nil))
                            :elapsed (etaf-ncm--clock app)))
         (lyric (etaf-ncm--read app :lyric))
         (lines (plist-get lyric :lines))
         (index (and lines (etaf-ncm--lyric-index lines (etaf-ncm--clock app)))))
    (list :section (etaf-ncm--read app :section)
          :title (etaf-ncm--read app :title)
          :subtitle (etaf-ncm--read app :subtitle)
          :mode (etaf-ncm--read app :mode)
          :query (etaf-ncm--read app :query)
          :items (mapcar #'copy-sequence rows)
          :visible (mapcar #'copy-sequence (nth 0 page))
          :window-start (nth 1 page)
          :selection (etaf-ncm--read app :selection)
          :page-size (etaf-ncm--read app :page-size)
          :viewport-width (plist-get app :mounted-width)
          :rows-total (length rows)
          :list-total (etaf-ncm--read app :list-total)
          :queue-rows (etaf-ncm--read app :queue-rows)
          :queue-start (etaf-ncm--queue-window-start app)
          :lyric-rows (etaf-ncm--read app :lyric-rows)
          :status (and status (copy-sequence status))
          :queue (let ((queue (etaf-ncm--read app :queue)))
                   (when queue
                     (list :count (plist-get queue :count)
                           :pos (plist-get queue :pos)
                           :current (nth (max 0 (1- (or (plist-get queue :pos) 0)))
                                         (etaf-ncm--list (plist-get queue :songs)))
                           :songs (mapcar #'copy-sequence
                                          (etaf-ncm--list (plist-get queue :songs))))))
          :lyric (and lyric
                      (list :id (plist-get lyric :id)
                            :lines (length lines)
                            :index (and index (1+ index))
                            :line (and lines index (cdr (nth index lines)))
                            :loading (plist-get lyric :loading)))
          :lyric-line (and lines index (cdr (nth index lines)))
          :aside (etaf-ncm--read app :aside)
          :layout (etaf-ncm--read app :layout)
          :pane (etaf-ncm--read app :pane)
          :theme (etaf-ncm--read app :theme)
          :account (let ((account (etaf-ncm--read app :account)))
                     (and account (copy-sequence account)))
          :loading (etaf-ncm--read app :loading)
          :error (etaf-ncm--read app :error)
          :message (etaf-ncm--read app :message))))

(provide 'etaf-ncm-model)
;;; etaf-ncm-model.el ends here
