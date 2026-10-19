;;; etaf-ncm-app.el --- Application shell of the NetEase Cloud Music player -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one player model to the Views.  `etaf-ncm-app'
;; is the only place that reads the model's reactive sources, so a backend
;; reply or a key press repaints the whole player in one place, and it owns the
;; session lifecycle: the palette is provided for its subtree, playback polling
;; starts on mount, and the session's timer and in-flight requests are released
;; on unmount.
;;
;; Every key is a `:keys' binding of the View, so an embedded player keeps them
;; and `?' lists them in ETAF's read-only help modal.  `etaf-ncm-open' adds what a
;; Component cannot own by itself: the buffer name, the wheel bindings and the
;; window-fitting page size.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ncm-theme)
(require 'etaf-ncm-service)
(require 'etaf-ncm-model)
(require 'etaf-ncm-views)

;;; ---------------------------------------------------------------------------
;;; Buffer state and wheel bindings
;;; ---------------------------------------------------------------------------

(defcustom etaf-ncm-buffer-name "*ETAF 网易云音乐*"
  "Buffer opened by `etaf-ncm-open'."
  :type 'string
  :group 'etaf-ncm)

(defvar etaf-ncm--model nil
  "Player model a key command acts on.
Key commands bind it to their session, so an embedded player shares the
buffer-free commands; other commands use the opened player's state.")

(defun etaf-ncm--current-model ()
  "Return the model of the current player buffer."
  (or etaf-ncm--model
      (etaf-app-state)
      (user-error "Current buffer is not an etaf-ncm player")))

;;; ---------------------------------------------------------------------------
;;; Model to View projections
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--view-entries (model)
  "Return MODEL's visible library rows as list entries."
  (pcase-let* ((`(,rows ,start ,_total) (etaf-ncm--page-rows model))
               (playing (plist-get (etaf-ncm--read model :status) :song-id)))
    (cl-loop for row in rows
             for index from start
             collect (list :index (1+ index)
                           :row row
                           :playing (and playing
                                         (eq (plist-get row :kind) :song)
                                         (equal (plist-get row :id) playing))))))

(defun etaf-ncm--view-status (model)
  "Return MODEL's playback status, or an empty status plist."
  (let ((status (or (etaf-ncm--read model :status)
                    (list :state 'idle :duration 0 :volume 0
                          :queue-pos 0 :queue-count 0 :shuffle nil :repeat nil))))
    (plist-put (copy-sequence status) :elapsed (etaf-ncm--clock model))))

(defun etaf-ncm--status-source (model key)
  "Return a retained projection of MODEL's status field KEY."
  (etaf-computed (lambda () (plist-get (etaf-ncm--read model :status) key))
                 :test #'equal :name (intern (format "ncm-status-%s" key))))

(defun etaf-ncm--lyric-panel (model)
  "Return MODEL's lyric window as props for the lyrics View.
Each visible line is (SECONDS TEXT ORDINAL); the ordinal is its position in
the parsed lyric, so the View keeps one stable key per line even when a real
LRC repeats a timestamp."
  (let* ((lyric (etaf-ncm--read model :lyric))
         (lines (plist-get lyric :lines))
         (budget (etaf-ncm--read model :lyric-rows))
         (trans (and (> budget 1) (plist-get lyric :trans)))
         (size (if trans (/ budget 2) budget))
         (elapsed (etaf-ncm--read model :position-ref))
         (index (and lines (etaf-ncm--lyric-index lines elapsed)))
         (window (and lines
                      (etaf-ncm--lyric-window lines index size)))
         (start (car window))
         (visible (cl-loop for line in (cdr window)
                           for ordinal from start
                           collect (list (car line) (cdr line) ordinal))))
    (list :lines visible
          :cells (if visible
                     (cl-loop for line in visible
                              append (append (list (list :text (nth 1 line)
                                                         :current (equal (car line) (car (nth index lines)))))
                                             (when-let* ((translation (cl-assoc (car line) trans :test #'=)))
                                               (list (list :text (cdr translation) :translation t)))))
                   (list (list :text (if (plist-get lyric :loading) "正在取歌词..." "这首歌没有歌词"))))
          :current (and lines (car (nth index lines)))
          :position (and index (1+ index))
          :total (and lines (length lines))
          :trans (delq nil (mapcar (lambda (line)
                                    (cl-assoc (car line) trans :test #'=)) visible))
          :loading (plist-get lyric :loading))))

(defun etaf-ncm--queue-panel (model)
  "Return MODEL's queue entries around the playing track."
  (let* ((queue (etaf-ncm--read model :queue))
         (songs (etaf-ncm--list (plist-get queue :songs)))
         (size (etaf-ncm--read model :queue-rows))
         (pos (or (plist-get queue :pos) 0))
         (start (etaf-ncm--queue-window-start model)))
    (list :count (or (plist-get queue :count) 0)
          :pos pos
          :entries (cl-loop for song in (seq-subseq songs start
                                                    (min (length songs) (+ start size)))
                            for index from start
                            collect (list :index (1+ index)
                                          :name (or (plist-get song :name) "")
                                          :right (etaf-ncm--format-duration
                                                  (plist-get song :ms))
                                          :current (= (1+ index) pos))))))

(defun etaf-ncm--search-text (model text)
  "Search TEXT in MODEL, reporting an empty keyword in the player line."
  (etaf-ncm--write model :query (or text ""))
  (if (string-empty-p (string-trim (or text "")))
      (etaf-ncm--write model :message "输入关键词后开始搜索")
    (condition-case error
        (etaf-ncm-search model text)
      (etaf-ncm-error (etaf-ncm--write model :message (error-message-string error))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--next-item ()
  "Move the library selection down."
  (interactive)
  (etaf-ncm-move-selection (etaf-ncm--current-model) 1))

(defun etaf-ncm--previous-item ()
  "Move the library selection up."
  (interactive)
  (etaf-ncm-move-selection (etaf-ncm--current-model) -1))

(defun etaf-ncm--queue-hit-p (xy columns rows layout pane aside)
  "Return non-nil when text-cell position XY hits the visible queue panel.
COLUMNS and ROWS describe the event window; LAYOUT, PANE and ASIDE describe
the player.  This geometry is independent of point and the selected window."
  (and (eq aside 'queue)
       (or (eq layout 'wide) (eq pane 'aside))
       (consp xy) (numberp (car xy)) (numberp (cdr xy))
       (<= (pcase layout
             ('wide (max 0 (- columns etaf-ncm-layout-aside-columns)))
             ('medium etaf-ncm-layout-rail-columns)
             (_ 0))
           (car xy))
       (< (car xy) columns)
       (<= 0 (cdr xy))
       (< (cdr xy) (etaf-ncm-layout-aside-rows layout rows))))

(defun etaf-ncm--wheel (event delta)
  "Scroll the queue or library window by DELTA at EVENT's position.
A wheel over the visible queue panel moves that window; elsewhere a visible
library window scrolls while its selection stays where it is, so a gesture can
browse rows without losing the row arrows and presses still act on."
  (let* ((position (event-start event))
         (window (posn-window position)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let* ((model (etaf-ncm--current-model))
               (pixels (posn-x-y position))
               (xy (and (consp pixels)
                        (cons (/ (float (car pixels)) (window-font-width window))
                              (/ (float (cdr pixels)) (window-font-height window))))))
          (cond
           ((and (null (posn-area position))
                 (etaf-ncm--queue-hit-p
                  xy (window-body-width window) (window-body-height window)
                  (etaf-ncm--read model :layout) (etaf-ncm--read model :pane)
                  (etaf-ncm--read model :aside)))
            (etaf-ncm--scroll-queue model delta))
           ((etaf-ncm--list-shown-p model)
            (etaf-ncm--scroll-list model delta))))))))

(defun etaf-ncm--first-item ()
  "Select the first row of the library."
  (interactive)
  (etaf-ncm-move-selection (etaf-ncm--current-model)
                           (- (plist-get (etaf-ncm-state (etaf-ncm--current-model)) :selection))))

(defun etaf-ncm--last-item ()
  "Select the last row of the library."
  (interactive)
  (let* ((app (etaf-ncm--current-model))
         (state (etaf-ncm-state app)))
    (etaf-ncm-move-selection app (- (1- (or (plist-get state :rows-total) 1))
                                    (plist-get state :selection)))))

(defun etaf-ncm--next-page ()
  "Select one page further down the library."
  (interactive)
  (let* ((app (etaf-ncm--current-model))
         (state (etaf-ncm-state app)))
    (etaf-ncm-move-selection app (or (plist-get state :page-size) 10))))

(defun etaf-ncm--previous-page ()
  "Select one page further up the library."
  (interactive)
  (let* ((app (etaf-ncm--current-model))
         (state (etaf-ncm-state app)))
    (etaf-ncm-move-selection app (- (or (plist-get state :page-size) 10)))))

(defun etaf-ncm--activate ()
  "Play or open the selected library row."
  (interactive)
  (etaf-ncm-activate-selection (etaf-ncm--current-model)))

(defun etaf-ncm--toggle-playback ()
  "Pause or resume the current song."
  (interactive)
  (etaf-ncm-toggle-playback (etaf-ncm--current-model)))

(defun etaf-ncm--next-track ()
  "Play the next track in the queue."
  (interactive)
  (etaf-ncm-next-track (etaf-ncm--current-model)))

(defun etaf-ncm--previous-track ()
  "Play the previous track in the queue."
  (interactive)
  (etaf-ncm-previous-track (etaf-ncm--current-model)))

(defun etaf-ncm--add-to-queue ()
  "Append the selected song to the queue."
  (interactive)
  (let ((model (etaf-ncm--current-model)))
    (condition-case error
        (etaf-ncm-add-to-queue model (etaf-ncm--selected-row model))
      (etaf-ncm-error (etaf-ncm--write model :message (error-message-string error))))))

(defun etaf-ncm--download ()
  "Download the selected library row into the local library."
  (interactive)
  (etaf-ncm-download-selection (etaf-ncm--current-model)))

(defun etaf-ncm-open-cover ()
  "Open the current track's album art in the system image viewer.
A terminal cannot show the original pixels inside the buffer, so this opens
the cached artwork at full size."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (file (etaf-ncm--read model :cover-file)))
    (unless (and (stringp file) (file-readable-p file))
      (user-error "当前歌曲没有可读取的封面"))
    (call-process (if (eq system-type 'darwin) "open" "xdg-open") nil 0 nil file)))

(defun etaf-ncm--search ()
  "Ask for a keyword and search it."
  (interactive)
  (etaf-ncm--search-text (etaf-ncm--current-model)
                         (read-string "搜索歌曲、歌手、歌单或专辑：")))

(defun etaf-ncm-login (&optional app)
  "Sign in to the backend with a phone number and an SMS verification code.
APP defaults to the mounted player or the one in the current buffer.  The
phone number is read in the minibuffer, with the number the backend remembers
as the default; once the backend reports the code went out, the minibuffer
asks for it.  On success the backend stores the cookie and the player reloads
its account and libraries."
  (interactive)
  (let* ((app (or app
                  etaf-ncm--model
                  (etaf-app-state etaf-ncm-buffer-name)
                  (user-error "没有打开的网易云音乐播放器")))
         (stored (etaf-ncm--stored-phone (etaf-ncm--client app)))
         (phone (string-trim
                 (read-string (if stored
                                  (format "手机号（回车用上次 %s）：" stored)
                                "手机号：")
                              nil nil stored))))
    (when (string-empty-p phone)
      (user-error "需要手机号"))
    (etaf-ncm--login-send
     app phone
     (lambda (result)
       (when (eq (car result) :ok)
         (condition-case nil
             (let ((code (string-trim (read-string "短信验证码（收到后输入）："))))
               (if (string-empty-p code)
                   (etaf-ncm--note app "没有输入验证码，登录未完成；再按 L 重来")
                 (etaf-ncm--login-finish app phone code nil)))
           (quit (etaf-ncm--note app "登录已取消（验证码没输入）"))))))))

(defun etaf-ncm--refresh ()
  "Reload the library, playback status, queue and account."
  (interactive)
  (etaf-ncm-refresh (etaf-ncm--current-model)))

(defun etaf-ncm--toggle-aside ()
  "Switch the side panel between the lyrics and the queue."
  (interactive)
  (etaf-ncm-toggle-aside (etaf-ncm--current-model)))

(defun etaf-ncm--toggle-pane ()
  "Show the library list or the lyrics and queue panel.
In a wide layout, which shows both, this keeps the library list focused."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (showing (eq (etaf-ncm--read model :pane) 'aside)))
    (etaf-ncm-show-pane model (if showing 'list 'aside))))

(defun etaf-ncm--toggle-repeat ()
  "Turn list repeat (列表循环) on or off."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (on (not (plist-get (etaf-ncm--view-status model) :repeat))))
    (etaf-ncm-set-repeat model on)))

(defun etaf-ncm--toggle-shuffle ()
  "Turn shuffle mode on or off."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (on (not (plist-get (etaf-ncm--view-status model) :shuffle))))
    (etaf-ncm-set-shuffle model on)))

(defun etaf-ncm--like ()
  "Add the current song to the liked songs."
  (interactive)
  (etaf-ncm-like (etaf-ncm--current-model)))

(defun etaf-ncm--unlike ()
  "Remove the current song from the liked songs."
  (interactive)
  (etaf-ncm-like (etaf-ncm--current-model) t))

(defun etaf-ncm--volume-up ()
  "Raise the volume by ten."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (volume (or (etaf-ncm--flag-value model :volume) 0)))
    (etaf-ncm-set-volume model (min 100 (+ volume 10)))))

(defun etaf-ncm--volume-down ()
  "Lower the volume by ten."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (volume (or (etaf-ncm--flag-value model :volume) 0)))
    (etaf-ncm-set-volume model (max 0 (- volume 10)))))

(defun etaf-ncm--seek-back ()
  "Seek ten seconds backwards."
  (interactive)
  (etaf-ncm-seek (etaf-ncm--current-model) -10))

(defun etaf-ncm--seek-forward ()
  "Seek ten seconds forwards."
  (interactive)
  (etaf-ncm-seek (etaf-ncm--current-model) 10))

(defun etaf-ncm--toggle-theme ()
  "Switch the player between the dark and light palette."
  (interactive)
  (let ((model (etaf-ncm--current-model)))
    (setq etaf-ncm-theme-mode (if (eq etaf-ncm-theme-mode 'dark) 'light 'dark))
    (etaf-ncm--write model :theme (etaf-ncm-theme-defaults etaf-ncm-theme-mode))
    (etaf-ncm--write model :message
                     (format "外观：%s" (if (eq etaf-ncm-theme-mode 'dark)
                                           "深色"
                                         "浅色")))))

(defun etaf-ncm--locate-index (index)
  "Show the sidebar library at 1-based position INDEX."
  (interactive "p")
  (let ((entry (nth (1- index) (apply #'append (mapcar #'cdr etaf-ncm-sections))))
        (model (etaf-ncm--current-model)))
    (if entry
        (etaf-ncm-locate model (car entry))
      (etaf-ncm--write model :message (format "没有第 %s 个音乐库" index)))))

(defun etaf-ncm--key-command (session command)
  "Return COMMAND as a key command acting on SESSION.
Binding the session lets an embedded player share the buffer-free commands."
  (lambda ()
    (interactive)
    (let ((etaf-ncm--model session))
      (call-interactively command))))

(defun etaf-ncm--keys (session)
  "Return the player-wide `:keys' of SESSION's root.
Arrows, RET and Tab stay with the focused region, so a focus group, a range
or the library list keeps them; `?' opens the read-only ETAF key help."
  (append
   (mapcar
    (lambda (entry)
      (list (car entry) (etaf-ncm--key-command session (nth 1 entry)) (nth 2 entry)))
    '(("SPC" etaf-ncm--toggle-playback "播放 / 暂停")
      ("n" etaf-ncm--next-track "下一首")
      ("p" etaf-ncm--previous-track "上一首")
      ("a" etaf-ncm--add-to-queue "选中歌曲加入队列")
      ("d" etaf-ncm--download "下载选中歌曲")
      ("s" etaf-ncm--search "搜索")
      ("/" etaf-ncm--search "搜索")
      ("g" etaf-ncm--refresh "刷新")
      ("i" etaf-ncm--toggle-aside "切换歌词 / 队列")
      ("v" etaf-ncm--toggle-pane "切换列表 / 面板")
      ("r" etaf-ncm--toggle-repeat "列表循环")
      ("z" etaf-ncm--toggle-shuffle "随机播放")
      ("c" etaf-ncm-open-cover "在系统查看器打开封面")
      ("f" etaf-ncm--like "喜欢")
      ("F" etaf-ncm--unlike "取消喜欢")
      ("+" etaf-ncm--volume-up "音量 +10")
      ("=" etaf-ncm--volume-up "音量 +10")
      ("-" etaf-ncm--volume-down "音量 -10")
      ("," etaf-ncm--seek-back "快退 10 秒")
      ("." etaf-ncm--seek-forward "快进 10 秒")
      ("L" etaf-ncm-login "短信登录")
      ("T" etaf-ncm--toggle-theme "切换深浅色")
      ("q" etaf-ncm-close "关闭窗口（音乐继续）")
      ("Q" etaf-ncm-quit "退出客户端（停止音乐）")))
   ;; The renderer scrolls the buffer on the wheel; the player scrolls the
   ;; queue or library window under the pointer instead.
   (mapcar (lambda (entry)
             (let ((delta (cdr entry)))
               (list (car entry)
                     (lambda (event)
                       (interactive "e")
                       (let ((etaf-ncm--model session))
                         (etaf-ncm--wheel event delta))))))
           '(("<wheel-up>" . -1) ("<wheel-down>" . 1)))
   (cl-loop for entry in (apply #'append (mapcar #'cdr etaf-ncm-sections))
            for index from 1 to 9
            collect (let ((index index))
                      (list (number-to-string index)
                            (lambda ()
                              (interactive)
                              (let ((etaf-ncm--model session))
                                (etaf-ncm--locate-index index)))
                            (format "音乐库：%s" (nth 1 entry)))))))

(defun etaf-ncm--list-keys (session)
  "Return the library list's `:keys' for SESSION.
The list is one focus stop whose directions move the selection through its
`:on-direction' handler, not the focus."
  (mapcar
   (lambda (entry)
     (list (car entry) (etaf-ncm--key-command session (nth 1 entry)) (nth 2 entry)))
   '(("C-n" etaf-ncm--next-item nil)
     ("C-p" etaf-ncm--previous-item nil)
     ("<home>" etaf-ncm--first-item "第一行")
     ("<end>" etaf-ncm--last-item "最后一行")
     ("<next>" etaf-ncm--next-page "下一页")
     ("<prior>" etaf-ncm--previous-page "上一页")
     ("RET" etaf-ncm--activate "播放选中行"))))

(defun etaf-ncm--queue-step (session delta)
  "Move queue focus by DELTA cells in SESSION, scrolling past the pool edge."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (ref (etaf-focused-host-ref runtime))
         (name (and (symbolp ref) (symbol-name ref)))
         (index (and name (string-prefix-p "ncm-queue-cell-" name)
                     (string-to-number (substring name 15))))
         (visible (length (plist-get (etaf-ncm--queue-panel session) :entries)))
         (target (and index (+ index delta))))
    (cond ((null index) (etaf-focus-within runtime 'ncm-queue))
          ((and (>= target 0) (< target visible))
           (etaf-focus runtime (intern (format "ncm-queue-cell-%d" target))))
          (t (etaf-ncm--scroll-queue session delta)))))

(defun etaf-ncm--queue-keys (session)
  "Return the queue group's `:keys' for SESSION.
The queue is one focus group whose directions move the selection through its
`:on-direction' handler."
  (let ((page (lambda (sign)
                (lambda ()
                  (interactive)
                  (etaf-ncm--scroll-queue
                   session (* sign (max 1 (etaf-ncm--read session :queue-rows))))))))
    (list (list "C-n" (lambda () (interactive) (etaf-ncm--queue-step session 1)))
          (list "C-p" (lambda () (interactive) (etaf-ncm--queue-step session -1)))
          (list "<next>" (funcall page 1) "队列下一页")
          (list "<prior>" (funcall page -1) "队列上一页"))))

(defun etaf-ncm--reveal-selection (session)
  "Put point on SESSION's selection bar while the library list has focus.
The list is one focus stop, so the cursor follows the selection bar."
  (when-let* ((buffer (plist-get session :buffer))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer))
              ((eq (etaf-focused-host-ref runtime) 'ncm-list))
              (bounds (etaf-host-ref-bounds runtime 'ncm-list-selection)))
    (with-current-buffer buffer
      (goto-char (car bounds))
      (dolist (window (get-buffer-window-list buffer nil t))
        (set-window-point window (car bounds))))))

(defun etaf-ncm--settle-focus (session)
  "Keep keyboard focus inside a visible region of SESSION.
Hiding a pane clears the focus inside it; the shown pane then receives it:
the library list, else the queue at its playing entry, else the lyric tabs."
  (when-let* ((buffer (plist-get session :buffer))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer)))
    (with-current-buffer buffer
      (unless (etaf-focused-host-ref runtime)
        (ignore-errors
          (cond ((and (etaf-ncm--aside-shown-p session)
                      (or (eq (etaf-ncm--read session :pane) 'aside)
                          (not (etaf-ncm--list-shown-p session))))
                 (etaf-focus-within runtime (if (eq (etaf-ncm--read session :aside) 'queue)
                                                'ncm-aside-queue
                                              'ncm-aside-lyrics)))
                ((etaf-ncm--list-shown-p session) (etaf-focus runtime 'ncm-list))))))))

;;; ---------------------------------------------------------------------------
;;; Application Component and entry points
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm-app (&key model)
  "Render the player for MODEL and own its session lifecycle.
MODEL must come from `etaf-ncm-create'.  Mounting provides the palette for the
subtree, starts playback polling and loads the current library; unmounting
releases the polling timer and the session's pending backend requests."
  :bindings ((session (or model
                          (signal 'etaf-ncm-error
                                  '("etaf-ncm-app needs the :model from `etaf-ncm-create'"))))
             (palette (etaf-ncm--ref session :theme))
             (cover-file (etaf-ncm--ref session :cover-file))
             (track-title (etaf-ncm--status-source session :title))
             (track-artist (etaf-ncm--status-source session :artist))
             (track-vip (etaf-ncm--status-source session :vip))
             (track-quality (etaf-ncm--status-source session :quality))
             (track-duration (etaf-ncm--status-source session :duration))
             (queue-count (etaf-ncm--status-source session :queue-count))
             (position (etaf-ncm--ref session :position-ref))
             (lyric-panel (etaf-computed (lambda () (etaf-ncm--lyric-panel session)) :test #'equal))
             (queue-panel (etaf-computed (lambda () (etaf-ncm--queue-panel session)) :test #'equal))
             ;; The transport glyph reads the retained state source directly;
             ;; the view never reads the state itself, so a toggle publishes a
             ;; prepared text update instead of re-rendering the app.
             (playing (etaf-computed
                       (lambda ()
                         (eq (etaf-value (etaf-ncm--ref session :state-ref)) 'playing))))
             ;; Callbacks are instance values, not per-render closures: a
             ;; re-render that passes a new function object to a keyed child
             ;; would make that child render again for nothing.
             (on-locate (lambda (section) (etaf-ncm-locate session section)))
             (on-search (lambda (text) (etaf-ncm--search-text session text)))
             (on-play-library (lambda () (etaf-ncm-play session)))
             (on-refresh (lambda () (etaf-ncm-refresh session)))
             (on-press-row (lambda (index) (etaf-ncm-press-row session index)))
             (on-row-action (lambda (index key)
                              (etaf-ncm-row-action session index key)))
             (on-switch-aside (lambda (panel)
                                (etaf-ncm--write session :aside panel)
                                ;; The tab row belongs to the aside variant
                                ;; that just hid; continue on the shown one.
                                (etaf-next-tick
                                 (lambda ()
                                   (when-let* ((runtime (etaf-runtime-for-buffer
                                                         (plist-get session :buffer))))
                                     (ignore-errors
                                       (etaf-focus-within
                                        runtime (intern (format "ncm-aside-%s" panel)))))))))
             (keys (etaf-ncm--keys session))
             (list-keys (etaf-ncm--list-keys session))
             (queue-keys (etaf-ncm--queue-keys session))
             (list-direction
              (lambda (direction)
                (let ((etaf-ncm--model session))
                  (pcase direction
                    ('down (etaf-ncm--next-item) 'handled)
                    ('up (etaf-ncm--previous-item) 'handled)
                    (_ 'release)))))
             (queue-direction
              (lambda (direction)
                (pcase direction
                  ('down (etaf-ncm--queue-step session 1) 'handled)
                  ('up (etaf-ncm--queue-step session -1) 'handled)
                  (_ 'release))))
             (on-list-focus (lambda () (etaf-ncm--reveal-selection session)))
             (on-jump-queue (lambda (index) (etaf-ncm-jump-queue session index)))
             (on-show-pane (lambda (target) (etaf-ncm-show-pane session target)))
             (on-show-aside (lambda (target)
                              (etaf-ncm--write session :aside target)
                              (etaf-ncm-show-pane session 'aside)))
             (on-toggle (lambda () (etaf-ncm-toggle-playback session)))
             (on-next (lambda () (etaf-ncm-next-track session)))
             (on-previous (lambda () (etaf-ncm-previous-track session)))
             (on-stop (lambda () (etaf-ncm-stop session)))
             (on-like (lambda ()
                        ;; The heart is a toggle: a press on a liked song
                        ;; removes the like.  The retained like source, not the
                        ;; last repainted status, is the current reading.
                        (etaf-ncm-like session
                                       (and (etaf-ncm--flag-value session :liked) t))))
             (on-add (lambda ()
                       (when-let* ((row (etaf-ncm--selected-row session)))
                         (etaf-ncm-add-to-queue session row))))
             (on-lyrics (lambda ()
                          (etaf-batch
                            (etaf-ncm--write session :aside 'lyrics)
                            (etaf-ncm-show-pane session 'aside))))
             (on-queue (lambda ()
                         (etaf-batch
                           (etaf-ncm--write session :aside 'queue)
                           (etaf-ncm-show-pane session 'aside))))
             (on-volume (lambda (percent) (etaf-ncm-set-volume session percent)))
             (on-seek (lambda (seconds) (etaf-ncm-seek-to session seconds)))
             (on-shuffle (lambda ()
                           (etaf-ncm-set-shuffle
                            session
                            (not (etaf-ncm--flag-value session :shuffle)))))
             (on-repeat (lambda ()
                          (etaf-ncm-set-repeat
                           session
                           (not (etaf-ncm--flag-value session :repeat)))))
             ;; Aside and pane sources are read inside Host bindings, so a panel
             ;; switch publishes retained visibility and paint instead of
             ;; re-rendering the app.
             (lyrics-visible (etaf-computed
                              (lambda ()
                                (and (eq (etaf-value (etaf-ncm--ref session :aside)) 'lyrics)
                                     (etaf-ncm--aside-shown-p session)))))
             (queue-visible (etaf-computed
                             (lambda ()
                               (and (eq (etaf-value (etaf-ncm--ref session :aside)) 'queue)
                                    (etaf-ncm--aside-shown-p session)))))
             (pane-list (etaf-computed
                         (lambda ()
                           (eq (etaf-value (etaf-ncm--ref session :pane)) 'list))))
             (list-visible (etaf-computed
                            (lambda () (etaf-ncm--list-shown-p session))))
             ;; The lyric panel's album line follows the selection through a
             ;; retained source the model writes, so a row move repaints only
             ;; that text instead of re-rendering the aside.
             (selected-album (etaf-ncm--ref session :selected-album))
             (on-login (lambda ()
                         (unless (etaf-ncm--read session :account)
                           (etaf-ncm-login session)))))
  :setup
  (progn
    (etaf-theme-provide palette)
    ;; The mounted player lays out for the region it is given: its own
    ;; buffer window when it stands alone, or the host window, pane or tab
    ;; that embeds it (see `etaf-viewport').
    ;; A watcher, not an effect: the sync reads the values it writes, and
    ;; an effect would rerun on its own writes and undo a pane chosen in a
    ;; wide layout.
    (etaf-watch #'etaf-viewport
                (lambda (viewport _old)
                  (when viewport
                    (etaf-ncm--sync-viewport session viewport))
                  nil)
                :immediate t)
    ;; The two overlay bars follow line targets through `etaf-transition':
    ;; a selection or playback move slides each bar on the shared clock, so
    ;; only the damaged rows repaint.  The Scope owns both runs and stops
    ;; them on unmount.
    (let* ((lines (etaf-ncm--list-highlights session))
           (selection-target (etaf-ref (car lines) :name 'ncm-selection-target))
           (playing-target (etaf-ref (cdr lines) :name 'ncm-playing-target))
           (selection-bar (etaf-transition selection-target
                                           :duration 0.15 :easing 'ease-out
                                           :name 'ncm-selection-bar))
           (playing-bar (etaf-transition playing-target
                                         :duration 0.15 :easing 'ease-out
                                         :name 'ncm-playing-bar)))
      (setf (plist-get session :highlight-targets)
            (cons selection-target playing-target))
      (etaf-watch selection-bar
                  (lambda (line _old)
                    (etaf-ncm--apply-highlight-geometry
                     session 'ncm-list-selection line)
                    (etaf-next-tick (lambda () (etaf-ncm--reveal-selection session))))
                  :name 'ncm-selection-bar-move)
      (etaf-watch playing-bar
                  (lambda (line _old)
                    (etaf-ncm--apply-highlight-geometry
                     session 'ncm-list-playing line))
                  :name 'ncm-playing-bar-move))
    (etaf-watch-effect
     (lambda ()
       (etaf-ncm--schedule-list-highlights session
                                           (etaf-ncm--list-highlights session))))
    (etaf-watch (lambda () (list (etaf-value pane-list) (etaf-value list-visible)
                                 (etaf-value lyrics-visible) (etaf-value queue-visible)))
                (lambda (&rest _)
                  (etaf-next-tick (lambda () (etaf-ncm--settle-focus session))))
                :flush 'post :test #'equal)
    (etaf-on-mounted
     (lambda ()
       (etaf-ncm--start session)
       (etaf-ncm-refresh session)
       (etaf-next-tick (lambda () (etaf-ncm--settle-focus session)))))
    (etaf-on-unmounted
     (lambda ()
       (etaf-ncm--dispose session))))
  :view
  (flex :position 'relative :flex-direction 'column :width 'stretch :height 'stretch
        ;; The shell paints no margin of its own: one clear line at the top is
        ;; the panels' own top padding and one under the player belongs to the
        ;; player bar, so the surface stays one background at every size.
        :color (etaf-ncm-color :ink) :bgcolor (etaf-ncm-color :bg)
        :keys keys :aria-label "网易云音乐"
        :help '("音乐由独立的 mpv 后端播放；查看帮助不会暂停播放或改变队列。"
                "关闭窗口后音乐继续，退出客户端才会停止播放。登录过期时可重新登录并刷新曲库。")
    (box :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'wide)
       :model session
       :height (if-let* ((rows (etaf-ncm--read session :window-rows)))
                   (list 'lh (etaf-ncm-layout-aside-rows
                              (etaf-ncm--read session :layout) rows))
                 '(% 100))
       :groups etaf-ncm-sections
       :on-locate on-locate
       :on-login on-login)
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'medium)
       :compact t
       :model session
       :height (if-let* ((rows (etaf-ncm--read session :window-rows)))
                   (list 'lh (etaf-ncm-layout-aside-rows
                              (etaf-ncm--read session :layout) rows))
                 '(% 100))
       :groups etaf-ncm-sections
       :on-locate on-locate
       :on-login on-login)
      (etaf-ncm--view-list-panel
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :visible list-visible
        (etaf-ncm--view-header
         :model session
         :layout (etaf-ncm--read session :layout)
         :columns (etaf-ncm--read session :columns)
         :short (etaf-ncm-layout-short-p (etaf-ncm--read session :window-rows))
         :on-search on-search
         :on-play-library on-play-library
         :on-refresh on-refresh)
        (etaf-ncm--view-chips
         :if (eq (etaf-ncm--read session :layout) 'narrow)
         :model session
         :columns (etaf-ncm--read session :columns)
         :groups etaf-ncm-sections
         :on-locate on-locate)
        (flex :position 'absolute :z-index 0
              ;; The banner starts where the page starts: under the header in
              ;; every tier, and under the chip strip in the narrow one.
              :left (list 'ch (if (etaf-ncm--compact-layout-p session) 1 2))
              :top (list 'lh (1- (etaf-ncm-layout-list-top
                                  (etaf-ncm--read session :layout))))
              :visibility (if (etaf-ncm--read session :error) 'visible 'hidden)
              :width (list 'ch (etaf-ncm-layout-list-columns
                                (etaf-ncm--read session :layout)
                                (etaf-ncm--read session :columns)))
              ;; Long failures used to be clipped to one third of the bar; the
              ;; banner wraps them across the library width instead.
              :height (list 'lh (etaf-ncm--notice-lines
                                (etaf-ncm--read session :message)
                                (etaf-ncm--read session :layout)
                                (etaf-ncm--read session :columns)))
              :align-items 'start :padding '((lh 0) (ch 1))
              :background-color (etaf-ncm-color :danger-bg)
              :color (etaf-ncm-color :danger)
          (box :height 'stretch :overflow 'hidden :wrap-mode 'word
            (text (expr (or (etaf-ncm--reactive-text (etaf-ncm--ref session :message)) "")))))
        (etaf-ncm--view-list
         :model session
         :compact (etaf-ncm--compact-layout-p session)
         :selection (etaf-ncm--ref session :selection)
         :keys list-keys :on-direction list-direction :on-focus on-list-focus
         :on-press on-press-row
         :on-action on-row-action))
      (etaf-ncm--view-aside
       :kind 'lyrics :visible lyrics-visible
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :title track-title :artist track-artist :album selected-album :cover cover-file
       :projection lyric-panel :rows (etaf-ncm--read session :lyric-rows)
       :on-switch on-switch-aside)
      (etaf-ncm--view-aside
       :kind 'queue :visible queue-visible
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :projection queue-panel :rows (etaf-ncm--read session :queue-rows)
       :queue-keys queue-keys
       :queue-direction queue-direction
       :on-switch on-switch-aside
       :on-jump on-jump-queue)
    (etaf-ncm--view-pane-tabs
     :if (etaf-ncm--compact-layout-p session)
     :pane-list pane-list
     :lyrics lyrics-visible
     :queue queue-visible
     :on-pane on-show-pane
     :on-aside on-show-aside)
    ;; The bar reserves five lines; the positioned host in flow and the
    ;; absolute panel inside is the retained publication address, so a control
    ;; toggle updates its Hosts without a view rebuild.
    (box :position 'relative :z-index 0 :width 'stretch
         :height (list 'lh etaf-ncm-layout-bar-rows)
         :flex-shrink 0
      (etaf-ncm--view-player
       :compact (etaf-ncm--compact-layout-p session)
       :title track-title :artist track-artist :vip track-vip :quality track-quality
       :cover cover-file
       :playing playing
       :elapsed position :duration track-duration
       :volume (etaf-ncm--ref session :volume-ref)
       :shuffle (etaf-ncm--ref session :shuffle-ref)
       :liked (etaf-ncm--ref session :liked-ref)
       :repeat (etaf-ncm--ref session :repeat-ref)
       :message (etaf-ncm--ref session :message)
       :lyrics lyrics-visible
       :queue-count queue-count
       :on-toggle on-toggle
       :on-next on-next
       :on-previous on-previous
       :on-stop on-stop
       :on-like on-like
       :on-add on-add
       :on-lyrics on-lyrics
       :on-queue on-queue
       :on-volume on-volume
       :on-seek on-seek
       :on-shuffle on-shuffle
       :on-repeat on-repeat))))

(defun etaf-ncm-view (&optional model)
  "Return the player View for MODEL.
MODEL defaults to a new session, exactly as `etaf-ncm-open' creates one; pass a
session from `etaf-ncm-create' to embed the player in your own mount."
  (etaf-view (etaf-ncm-app :model (or model (etaf-ncm-create)))))

(defun etaf-ncm--list-highlights (app)
  "Return APP's (SELECTION-LINE . PLAYING-LINE) inside the visible page.
Lines count from zero; -1 keeps that bar clipped off the page."
  (let* ((slots (plist-get app :row-slots))
         (size (min (max 1 (etaf-ncm--read app :page-size)) (length slots)))
         (selection (- (etaf-ncm--read app :selection)
                       (etaf-ncm--read app :window-start)))
         (played (plist-get (etaf-ncm--read app :status) :song-id))
         (playing -1))
    (dotimes (index size)
      (let ((value (etaf-value (aref slots index))))
        (when (and value played (equal (plist-get value :id) played))
          (setq playing index))))
    (cons (if (and (>= selection 0) (< selection size)) selection -1)
          playing)))

(defun etaf-ncm--apply-highlight-geometry (app host line)
  "Move APP's HOST bar to LINE through the retained geometry boundary.
One `:top' translation repaints only the damaged rows of the list plane."
  (when-let* ((buffer (plist-get app :buffer))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer))
              ((numberp line)))
    (ignore-errors
      (etaf-runtime-update-host-geometry runtime host :top (list 'lh line)))))

(defun etaf-ncm--apply-list-highlights (app &optional lines)
  "Move APP's highlight bars to LINES, defaulting to the current page.
Each bar is one retained host geometry update: a `:top' translation that
never republishes the list plane."
  (let ((lines (or lines (plist-get app :highlight-lines))))
    (when lines
      (etaf-ncm--apply-highlight-geometry app 'ncm-list-selection (car lines))
      (etaf-ncm--apply-highlight-geometry app 'ncm-list-playing (cdr lines))
      (etaf-ncm--reveal-selection app))))

(defun etaf-ncm--schedule-list-highlights (app lines)
  "Move APP's highlight bars to LINES.
Line changes are the only reason to schedule: a slot write that leaves both
bars where they are must not publish geometry.  With animation targets, the
shared clock slides each bar from where it is, and the move stays outside the
reactive batch that reported the change; a model without targets (for example
a session driven headlessly) applies the geometry at once."
  (unless (equal lines (plist-get app :highlight-lines))
    (setf (plist-get app :highlight-lines) lines)
    (let ((targets (plist-get app :highlight-targets)))
      (if targets
          (etaf-batch
            (etaf-set-value (car targets) (car lines))
            (etaf-set-value (cdr targets) (cdr lines)))
        (etaf-ncm--apply-list-highlights app lines)))))

(defun etaf-ncm-open (&optional model)
  "Open the NetEase Cloud Music player and return its buffer.
MODEL defaults to a session from `etaf-ncm-create', so the player opens on the
daily recommendation with the signed-in account, queue and playback status of
the backend.  A caller-provided MODEL keeps its library, queue and selection."
  (interactive)
  (let* ((model (or model (etaf-ncm-create)))
         ;; Ebox paints whole character cells, so a window body that is not
         ;; a whole number of cells keeps a sub-cell remainder at its edge;
         ;; the canvas background shows the palette there.  ETAF chooses the
         ;; display-safe viewport from the visible window, so the player
         ;; passes no geometry of its own.
         (buffer (etaf-app-open
                  etaf-ncm-buffer-name (etaf-ncm-view model)
                  :state model
                  :background (lambda () (plist-get (etaf-ncm--read model :theme) :ui-bg))
                  ;; Mount-time focus and highlight work reads the buffer.
                  :on-fit (lambda (_window) (plist-put model :buffer (current-buffer))))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (etaf-ncm--apply-list-highlights model (etaf-ncm--list-highlights model))
    buffer))

(defun etaf-ncm-close ()
  "Unmount the player and kill its buffer."
  (interactive)
  (when (etaf-app-state etaf-ncm-buffer-name)
    (etaf-app-close etaf-ncm-buffer-name)))

(defun etaf-ncm-quit ()
  "Stop the backend player and close the client.
Unlike `etaf-ncm-close', which only closes the window and lets the backend
keep playing, quitting ends the playback too: the stop runs before the
buffer is killed, so a later `etaf-ncm-open' starts from a stopped player.
The backend keeps its queue files, so `back' can still bring the queue
back."
  (interactive)
  (setq etaf-ncm--player-owner nil)
  (when-let* ((model (or etaf-ncm--model (etaf-app-state etaf-ncm-buffer-name))))
    (etaf-ncm--stop-synchronously (etaf-ncm--client model)))
  (etaf-ncm-close))

;; The backend player is an external mpv process: exiting Emacs must not
;; leave it playing.  The hook only stops a player this Emacs started (see
;; `etaf-ncm--player-owner'), so playback the CLI started keeps running.
(add-hook 'kill-emacs-hook #'etaf-ncm--stop-player-on-exit)

(provide 'etaf-ncm-app)
;;; etaf-ncm-app.el ends here
