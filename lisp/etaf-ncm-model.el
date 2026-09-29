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
     (:daily "每日推荐" "◆")
     (:fm "私人 FM" "≈")
     (:liked "我喜欢的音乐" "♥"))
    (我的音乐
     (:playlists "我的歌单" "≡")
     (:albums "收藏专辑" "▣")
     (:artists "收藏歌手" "☺"))
    (发现
     (:charts "排行榜" "▲")
     (:podcasts "播客" "◎")
     (:recent "最近播放" "↺")))
  "Sidebar groups shown by the player.
Each group is (GROUP-NAME (SECTION LABEL GLYPH) ...); SECTION keys are accepted
by `etaf-ncm-locate'.")

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
  "Maximum rows requested from the backend for one library load."
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
          :page-size (etaf-ref etaf-ncm-page-size :name 'etaf-ncm-page-size)
          :disposed nil
          :status-in-flight nil
          :polled-at 0
          :last-tick (float-time)
          :timer nil
          :section (etaf-ref :daily :name 'etaf-ncm-section)
          :title (etaf-ref "每日推荐" :name 'etaf-ncm-title)
          :subtitle (etaf-ref "根据你的口味生成，每天更新" :name 'etaf-ncm-subtitle)
          :origin (etaf-ref '(:kind daily) :name 'etaf-ncm-origin)
          :rows (etaf-ref nil :name 'etaf-ncm-rows)
          :selection (etaf-ref 0 :name 'etaf-ncm-selection)
          :window-start (etaf-ref 0 :name 'etaf-ncm-window-start)
          :status (etaf-ref nil :name 'etaf-ncm-status)
          :clock (etaf-ref 0 :name 'etaf-ncm-clock)
          :queue (etaf-ref nil :name 'etaf-ncm-queue)
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

(defun etaf-ncm--client (model)
  "Return MODEL's backend client."
  (plist-get model :client))

(cl-defun etaf-ncm--call (model request &key on-ok on-error)
  "Send REQUEST for MODEL, routing a failure into the visible status line.
ON-OK receives the reply data and ON-ERROR the failure message.  A client that
signals while turning the request into a command is reported like any other
backend failure, so nothing reaches the caller of a player action."
  (let ((delivered nil)
        (fail (lambda (message hint)
                (etaf-ncm--write model :error message)
                (etaf-ncm--write model :message
                                 (if (and hint (not (string-empty-p hint)))
                                     (format "%s（%s）" message hint)
                                   message))
                (when on-error (funcall on-error message hint)))))
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
                      (plist-get (cddr result) :hint)))))
      (error (if delivered
                 (signal (car error) (cdr error))
               (funcall fail (error-message-string error) nil))))))

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
  "Return SECONDS as \"M:SS\" or \"0:00\"."
  (let ((seconds (if (numberp seconds) (max 0 (round seconds)) 0)))
    (format "%d:%02d" (/ seconds 60) (% seconds 60))))

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
SECTION is one of the keys in `etaf-ncm-sections'.  Loading is asynchronous:
the rows keep the current list until the backend replies, and a reply from an
earlier library is discarded.  Unknown SECTION signals `etaf-ncm-error'."
  (unless (and (symbolp section) (or (eq section :search)
                                     (etaf-ncm--section-label section)))
    (signal 'etaf-ncm-error (list (format "Unknown library: %S" section))))
  (etaf-ncm--write app :mode 'browse)
  (etaf-ncm--write app :pane 'list)
  (etaf-ncm--write app :section section)
  (etaf-ncm--write app :title (or (etaf-ncm--section-label section) "音乐库"))
  (etaf-ncm--write app :subtitle (or (cdr (assq section etaf-ncm--section-subtitles)) ""))
  (etaf-ncm--write app :origin (list :kind section))
  (etaf-ncm--load app section))

(defun etaf-ncm-search (app keyword &optional scope)
  "Search KEYWORD in APP and show the matches.
SCOPE is `song' (default) or `playlist'.  An empty KEYWORD signals
`etaf-ncm-error' instead of querying the backend."
  (let ((keyword (string-trim (or keyword ""))))
    (when (string-empty-p keyword)
      (signal 'etaf-ncm-error '("搜索关键词不能为空")))
    (etaf-ncm--write app :mode 'search)
    (etaf-ncm--write app :section :search)
    (etaf-ncm--write app :query keyword)
    (etaf-ncm--write app :title "搜索结果")
    (etaf-ncm--write app :subtitle (format "关键词：%s" keyword))
    (etaf-ncm--write app :origin nil)
    (etaf-ncm--load app (list :op :search :keyword keyword
                              :scope (or scope 'song)
                              :limit (etaf-ncm--read app :page-size)
                              :resource (if (eq scope 'playlist) :playlists :songs)))))

(defun etaf-ncm--load (app source)
  "Load SOURCE into APP, ignoring replies from superseded loads.
SOURCE is either a library key or a ready-made search request plist."
  (let* ((request (if (listp source)
                      source
                    (list :op :browse :resource source
                          :limit (max etaf-ncm-fetch-limit (* 3 (etaf-ncm--read app :page-size))))))
         (kind (or (plist-get request :resource) (plist-get request :op)))
         (generation (1+ (etaf-ncm--read app :generation))))
    (etaf-ncm--write app :generation generation)
    (etaf-ncm--write app :loading t)
    (etaf-ncm--write app :error nil)
    (etaf-ncm--call
     app request
     :on-ok (lambda (data)
              (when (= generation (etaf-ncm--read app :generation))
                (let ((rows (etaf-ncm--library-rows kind data)))
                  (etaf-ncm--write app :rows rows)
                  (etaf-ncm--write app :selection 0)
                  (etaf-ncm--write app :window-start 0)
                  (etaf-ncm--write app :loading nil)
                  (etaf-ncm--note app (format "%s · %d 项" (etaf-ncm--read app :title)
                                              (length rows))))))
     :on-error (lambda (message _hint)
                 (when (= generation (etaf-ncm--read app :generation))
                   (etaf-ncm--write app :loading nil)
                   (etaf-ncm--write app :rows nil)
                   (etaf-ncm--note app message))))))

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
ITEM is a row from the visible list, a song id, or a keyword string.  Playing a
library row replaces the queue with that song, playlist, album, artist, chart,
podcast or episode; ITEM nil replays the whole current library."
  (let ((target (etaf-ncm--target app item)))
    (etaf-ncm--command app (list :op :play :target target)
                       (format "正在播放：%s" (etaf-ncm--target-label app item)))))

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
  "Pause or resume APP depending on the playback state."
  (etaf-ncm--command app (list :op :toggle) "已切换播放状态"))

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
  "Set APP's volume to VOLUME, an integer between 0 and 130.
A value outside that range signals `etaf-ncm-error'."
  (unless (and (numberp volume) (<= 0 volume 130))
    (signal 'etaf-ncm-error (list (format "音量要在 0-130 之间：%S" volume))))
  (etaf-ncm--command app (list :op :volume :value (round volume))
                     (format "音量 %d" (round volume))))

(defun etaf-ncm-seek (app seconds)
  "Move APP's playback position by SECONDS relative to the current one."
  (unless (numberp seconds)
    (signal 'etaf-ncm-error (list (format "进度偏移必须是秒数：%S" seconds))))
  (etaf-ncm--command app (list :op :seek :seconds (round seconds))
                     (format "进度 %s%ss" (if (< seconds 0) "-" "+") (abs (round seconds)))))

(defun etaf-ncm-set-shuffle (app on)
  "Turn queue shuffling in APP ON or off."
  (etaf-ncm--command app (list :op :shuffle :on (and on t))
                     (if on "随机播放：开" "随机播放：关")))

(defun etaf-ncm-set-repeat (app on)
  "Turn single-song repeat in APP ON or off."
  (etaf-ncm--command app (list :op :repeat :on (and on t))
                     (if on "单曲循环：开" "单曲循环：关")))

(defun etaf-ncm-like (app &optional unlike)
  "Like the song playing in APP, or unlike it when UNLIKE is non-nil."
  (etaf-ncm--command app (list :op (if unlike :unlike :like))
                     (if unlike "已取消喜欢" "已加入我喜欢的音乐")))

(defun etaf-ncm--command (app request message)
  "Send REQUEST for APP and show MESSAGE once the backend accepts it."
  (etaf-ncm--call app request
                  :on-ok (lambda (_data)
                           (etaf-ncm--note app message)
                           (etaf-ncm--request-status app)
                           (etaf-ncm--request-queue app))))

(defun etaf-ncm--target (app item)
  "Return the backend play target for ITEM inside APP."
  (cond
   ((null item) (or (etaf-ncm--read app :origin) '(:kind daily)))
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
The library reload also re-fits the layout and row count to APP's window."
  (etaf-ncm--write app :error nil)
  (etaf-ncm--sync-layout app)
  (setf (plist-get app :polled-at) 0)
  (etaf-ncm--load app (if (eq (etaf-ncm--read app :mode) 'search)
                          (list :op :search
                                :keyword (etaf-ncm--read app :query)
                                :scope 'song
                                :resource :songs
                                :limit (max etaf-ncm-fetch-limit
                                            (* 3 (etaf-ncm--read app :page-size))))
                        (etaf-ncm--read app :section)))
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
  "Ask the backend for APP's playback truth."
  (setf (plist-get app :status-in-flight) t)
  (etaf-ncm--call
   app (list :op :status)
   :on-ok (lambda (data)
            (setf (plist-get app :status-in-flight) nil
                  (plist-get app :polled-at) (float-time)
                  (plist-get app :last-tick) (float-time))
            (etaf-ncm--apply-status app (etaf-ncm--normalize-status data)))
   :on-error (lambda (_message _hint)
               (setf (plist-get app :status-in-flight) nil
                     (plist-get app :polled-at) (float-time)))))

(defun etaf-ncm--apply-status (app status)
  "Publish STATUS and fetch the lyric when the song changed.
The elapsed position goes to `:clock', which changes every tick; the rest stays
in `:status', so a playing second repaints the player bar instead of every view
that reads the playback facts."
  (let* ((previous (etaf-ncm--read app :status))
         (song-id (plist-get status :song-id))
         (lyric (etaf-ncm--read app :lyric)))
    (etaf-ncm--write app :clock (or (plist-get status :elapsed) 0))
    (etaf-ncm--write app :status
                     (plist-put (copy-sequence status) :elapsed
                                (or (plist-get (etaf-ncm--read app :status) :elapsed) 0)))
    (when (and song-id (not (equal song-id (plist-get lyric :id))))
      (etaf-ncm--request-lyric app song-id))
    (when (and previous (plist-get previous :song-id)
               song-id (not (equal song-id (plist-get previous :song-id))))
      (etaf-ncm--request-queue app))))

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
            (etaf-ncm--write
             app :queue
             (list :count (or (etaf-ncm--parse-number (plist-get data :count)) 0)
                   :pos (or (etaf-ncm--parse-number (plist-get data :pos)) 0)
                   :songs (etaf-ncm--list (plist-get data :songs)))))))

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
   :on-error (lambda (_message _hint)
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
        (let* ((elapsed (+ (or (etaf-ncm--read app :clock) 0) (- now last)))
               (duration (or (plist-get (etaf-ncm--read app :status) :duration) 0)))
          (etaf-ncm--write app :clock
                           (if (> duration 0) (min elapsed duration) elapsed))))
      (when (etaf-ncm--poll-due-p app now)
        (etaf-ncm--request-status app)))))

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
  (etaf-ncm--sync-layout app)
  (add-hook 'window-size-change-functions #'etaf-ncm--window-size-change)
  (unless (plist-get app :timer)
    (setf (plist-get app :timer)
          (run-with-timer etaf-ncm-status-interval etaf-ncm-status-interval
                          (lambda () (etaf-ncm--tick app))))))

(defun etaf-ncm--dispose (app)
  "Release APP's timer and in-flight requests."
  (setf (plist-get app :disposed) t)
  (when-let* ((timer (plist-get app :timer)))
    (cancel-timer timer)
    (setf (plist-get app :timer) nil))
  (etaf-ncm-cancel (etaf-ncm--client app)))

;;; ---------------------------------------------------------------------------
;;; Keyboard navigation and panels
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--page-size-for (window &optional layout)
  "Return the library row count that fits WINDOW's height in LAYOUT.
LAYOUT is the layout the rows are rendered in: `narrow' and `medium' spend lines
on chips and pane tabs, while `wide' and an unknown LAYOUT subtract less chrome."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         (chrome (pcase layout
                   ('narrow 18)
                   ('medium 16)
                   (_ 12))))
    (max 4 (- height chrome))))

(defun etaf-ncm--window-columns (&optional window)
  "Return WINDOW's body width in columns, or the frame width when it is dead."
  (if (and window (window-live-p window))
      (window-body-width window)
    (frame-width)))

(defun etaf-ncm--viewport-options (&optional window)
  "Return mount viewport options sized for WINDOW, or nil when it is dead.
A mount without them paints at Ebox's default size, which clips the player bar
until the first resize."
  (when (and window (window-live-p window))
    (list :viewport-width (window-body-width window 'pixel)
          :viewport-height (window-body-height window))))

(defun etaf-ncm--layout-for (columns)
  "Return the layout COLUMNS columns of text can hold.
The result is `wide', `medium' or `narrow'; see `etaf-ncm-wide-columns' and
`etaf-ncm-medium-columns'."
  (cond ((>= columns etaf-ncm-wide-columns) 'wide)
        ((>= columns etaf-ncm-medium-columns) 'medium)
        (t 'narrow)))

(defun etaf-ncm--sync-layout (app &optional window)
  "Match APP's layout, pane visibility and page size to WINDOW.
WINDOW defaults to the window showing APP's buffer.  A headless session keeps
the wide layout, because it has no viewport to adapt to."
  (let* ((buffer (plist-get app :buffer))
         (window (or window
                     (and (buffer-live-p buffer) (get-buffer-window buffer t))))
         (layout (if window
                     (etaf-ncm--layout-for (etaf-ncm--window-columns window))
                   'wide))
         (size (etaf-ncm--page-size-for window layout)))
    (when (and (eq layout 'wide)
               (not (eq (etaf-ncm--read app :pane) 'list)))
      (etaf-ncm--write app :pane 'list))
    (unless (eq layout (etaf-ncm--read app :layout))
      (etaf-ncm--write app :layout layout))
    (unless (equal size (etaf-ncm--read app :page-size))
      (etaf-ncm--write app :page-size size))
    layout))

(defun etaf-ncm--window-size-change (frame)
  "Adapt every mounted player on FRAME to its new window widths.
The hook stays installed for the session: it costs one window scan per resize
and never touches a buffer without a player model."
  (when (frame-live-p frame)
    (dolist (window (window-list frame 'no-minibuf))
      (let ((buffer (window-buffer window)))
        (when (and (buffer-live-p buffer)
                   (buffer-local-value 'etaf-ncm--model buffer))
          (etaf-ncm--sync-layout (buffer-local-value 'etaf-ncm--model buffer)
                                 window))))))

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
`:page-size', `:status', `:queue', `:lyric', `:lyric-line', `:aside',
`:layout', `:pane', `:theme', `:account', `:loading', `:error' and `:message'."
  (let* ((rows (etaf-ncm--read app :rows))
         (page (etaf-ncm--page-rows app))
         (status (plist-put (copy-sequence (or (etaf-ncm--read app :status) nil))
                            :elapsed (etaf-ncm--read app :clock)))
         (lyric (etaf-ncm--read app :lyric))
         (lines (plist-get lyric :lines))
         (index (and lines (etaf-ncm--lyric-index lines (or (etaf-ncm--read app :clock) 0)))))
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
          :rows-total (length rows)
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
