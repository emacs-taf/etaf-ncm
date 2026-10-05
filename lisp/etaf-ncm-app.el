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
;; `etaf-ncm-open' adds what a Component cannot own by itself: the buffer name,
;; the buffer-local keymap, and the window-fitting page size.

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
;;; Buffer state and keymap
;;; ---------------------------------------------------------------------------

(defcustom etaf-ncm-buffer-name "*ETAF 网易云音乐*"
  "Buffer opened by `etaf-ncm-open'."
  :type 'string
  :group 'etaf-ncm)

(defvar-local etaf-ncm--model nil
  "Player model shown by the current buffer's runtime.")

(defvar etaf-ncm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'etaf-ncm--next-item)
    (define-key map (kbd "k") #'etaf-ncm--previous-item)
    (define-key map (kbd "C-n") #'etaf-ncm--next-item)
    (define-key map (kbd "C-p") #'etaf-ncm--previous-item)
    (define-key map (kbd "<down>") #'etaf-ncm--next-item)
    (define-key map (kbd "<up>") #'etaf-ncm--previous-item)
    ;; The event position chooses between the library and the queue window.
    (define-key map (kbd "<wheel-up>") #'etaf-ncm--wheel-up)
    (define-key map (kbd "<wheel-down>") #'etaf-ncm--wheel-down)
    ;; Jumping around a long library: first, last and by whole pages.
    (define-key map (kbd "<home>") #'etaf-ncm--first-item)
    (define-key map (kbd "<end>") #'etaf-ncm--last-item)
    (define-key map (kbd "<next>") #'etaf-ncm--next-page)
    (define-key map (kbd "<prior>") #'etaf-ncm--previous-page)
    (define-key map (kbd "RET") #'etaf-ncm--activate)
    (define-key map (kbd "SPC") #'etaf-ncm--toggle-playback)
    (define-key map (kbd "n") #'etaf-ncm--next-track)
    (define-key map (kbd "p") #'etaf-ncm--previous-track)
    (define-key map (kbd "a") #'etaf-ncm--add-to-queue)
    (define-key map (kbd "d") #'etaf-ncm--download)
    (define-key map (kbd "s") #'etaf-ncm--search)
    (define-key map (kbd "/") #'etaf-ncm--search)
    (define-key map (kbd "g") #'etaf-ncm--refresh)
    (define-key map (kbd "q") #'etaf-ncm-close)
    (define-key map (kbd "l") #'etaf-ncm--toggle-aside)
    (define-key map (kbd "v") #'etaf-ncm--toggle-pane)
    (define-key map (kbd "r") #'etaf-ncm--toggle-repeat)
    (define-key map (kbd "z") #'etaf-ncm--toggle-shuffle)
    (define-key map (kbd "f") #'etaf-ncm--like)
    (define-key map (kbd "F") #'etaf-ncm--unlike)
    (define-key map (kbd "+") #'etaf-ncm--volume-up)
    (define-key map (kbd "=") #'etaf-ncm--volume-up)
    (define-key map (kbd "-") #'etaf-ncm--volume-down)
    (define-key map (kbd ",") #'etaf-ncm--seek-back)
    (define-key map (kbd ".") #'etaf-ncm--seek-forward)
    (define-key map (kbd "T") #'etaf-ncm--toggle-theme)
    (define-key map (kbd "?") #'etaf-ncm--help)
    (dotimes (index 9)
      (define-key map (kbd (number-to-string (1+ index)))
        (lambda ()
          (interactive)
          (etaf-ncm--locate-index (1+ index)))))
    map)
  "Keymap of the buffer opened by `etaf-ncm-open'.
It keeps Ebox's TAB focus cycling and RET activation, and replaces the
scrolling keys with player commands: n/p switch tracks, SPC pauses, and
j/k move the library selection.")

(defvar etaf-ncm--command-maps
  (list (cons 'etaf-ncm--model
              (let ((map (make-sparse-keymap)))
                (define-key map [wheel-up] #'etaf-ncm--wheel-up)
                (define-key map [wheel-down] #'etaf-ncm--wheel-down)
                ;; These collide with the renderer's own minor-mode map, which
                ;; outranks the major-mode map in a mounted buffer.  The player
                ;; overrides exactly its documented commands and leaves TAB,
                ;; the remaining scrolling keys and mouse events to the
                ;; renderer.
                (define-key map (kbd "n") #'etaf-ncm--next-track)
                (define-key map (kbd "p") #'etaf-ncm--previous-track)
                (define-key map (kbd "d") #'etaf-ncm--download)
                (define-key map (kbd "SPC") #'etaf-ncm--toggle-playback)
                (define-key map (kbd "<next>") #'etaf-ncm--next-page)
                (define-key map (kbd "<prior>") #'etaf-ncm--previous-page)
                (define-key map (kbd "RET") #'etaf-ncm--activate)
                (define-key map (kbd "q") #'etaf-ncm-close)
                map)))
  "Command bindings that take precedence over the renderer's minor-mode map.
The alist is enabled only in an opened player buffer; TAB still reaches the
renderer's focus cycling.")

(defun etaf-ncm--current-model ()
  "Return the model of the current player buffer."
  (or etaf-ncm--model
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
             ('wide (max 0 (- columns (cadr etaf-ncm--aside-width))))
             ('medium (cadr etaf-ncm--rail-width))
             (_ 0))
           (car xy))
       (< (car xy) columns)
       (<= 0 (cdr xy))
       (< (cdr xy) (etaf-ncm--body-rows-for rows layout))))

(defun etaf-ncm--wheel (event delta)
  "Scroll the queue or library window by DELTA at EVENT's position.
A wheel over the visible queue panel moves that window; elsewhere a visible
library window scrolls while its selection stays where it is, so a gesture can
browse rows without losing the row j/k and presses still act on."
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

(defun etaf-ncm--wheel-up (event)
  "Scroll the queue or library window one row up at EVENT."
  (interactive "e")
  (etaf-ncm--wheel event -1))

(defun etaf-ncm--wheel-down (event)
  "Scroll the queue or library window one row down at EVENT."
  (interactive "e")
  (etaf-ncm--wheel event 1))

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
  "Activate the focused control, or play the selected library row.
The renderer activates the Host under point, which is what a click or TAB
leaves there; j/k only move the selection, so fall back to it."
  (interactive)
  (condition-case nil
      (etaf-activate)
    (user-error
     (etaf-ncm-activate-selection (etaf-ncm--current-model)))))

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

(defun etaf-ncm--search ()
  "Ask for a keyword and search it."
  (interactive)
  (etaf-ncm--search-text (etaf-ncm--current-model)
                         (read-string "搜索歌曲、歌手、歌单或专辑：")))

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
                                         "浅色")))
    (when-let* ((buffer (plist-get model :buffer)))
      (with-current-buffer buffer (etaf-ncm--remap-canvas-face)))))

(defun etaf-ncm--remap-canvas-face ()
  "Paint this buffer's unpainted cells with the palette background.
Ebox paints whole character cells, so a window body that is not a whole number
of cells keeps a sub-cell remainder at its right or bottom edge.  Remapping the
default face shows the player background there instead of the frame's."
  (face-remap-set-base 'default (list :background (etaf-ncm-color :bg))))

(defun etaf-ncm--locate-index (index)
  "Show the sidebar library at 1-based position INDEX."
  (interactive "p")
  (let ((entry (nth (1- index) (apply #'append (mapcar #'cdr etaf-ncm-sections))))
        (model (etaf-ncm--current-model)))
    (if entry
        (etaf-ncm-locate model (car entry))
      (etaf-ncm--write model :message (format "没有第 %s 个音乐库" index)))))

(defun etaf-ncm--help ()
  "Show the player's key bindings."
  (interactive)
  (message
   (concat "j/k 选择 · 滚轮滚动列表 · 单击选中 · 双击播放 · RET 播放 · SPC 暂停 · n/p 切歌 · a 加入队列 · d 下载 · s 搜索 · g 刷新"
           " · l 歌词/队列 · v 列表/面板 · 1-9 音乐库 · +/- 音量 · ,/. 快退快进"
           " · 队列内滚轮翻动队列 · f/F 喜欢 · r 列表循环 · z 随机 · T 深浅色 · q 关闭")))

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
                                (etaf-ncm--write session :aside panel)))
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
             (selected-album (etaf-ncm--ref session :selected-album)))
  :setup
  (progn
    (etaf-theme-provide palette)
    (etaf-watch-effect
     (lambda ()
       (etaf-ncm--schedule-list-highlights session
                                           (etaf-ncm--list-highlights session))))
    (etaf-on-mounted
     (lambda ()
       (etaf-ncm--start session)
       (etaf-ncm-refresh session)))
    (etaf-on-unmounted
     (lambda ()
       (etaf-ncm--dispose session))))
  :view
  (flex :position 'relative :flex-direction 'column :width '(vw 100) :height '(vh 100)
        ;; One clear line above the chrome keeps the header off the window
        ;; edge; the layout budget already reserves the root padding.
        :padding-top '(lh 1)
        ;; Rows that show symbol glyphs (the state dot, the transport icons, the
        ;; sidebar glyphs) render a little taller than the frame's line height
        ;; because their fallback font has larger metrics.  Keep the last line
        ;; clear so those extra pixels land in empty space instead of below the
        ;; window, which clipped the player bar's control row.
        :padding-bottom '(lh 0)
        :color (etaf-ncm-color :ink) :bgcolor (etaf-ncm-color :bg)
    (box :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'wide)
       :model session
       :height (if-let* ((rows (etaf-ncm--read session :window-rows)))
                   (list 'lh (max 1 (- rows 7))) '(% 100))
       :groups etaf-ncm-sections
       :on-locate on-locate)
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'medium)
       :compact t
       :model session
       :height (if-let* ((rows (etaf-ncm--read session :window-rows)))
                   (list 'lh (max 1 (- rows 7))) '(% 100))
       :groups etaf-ncm-sections
       :on-locate on-locate)
      (etaf-ncm--view-list-panel
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :visible list-visible
        (etaf-ncm--view-header
         :model session
         :compact (etaf-ncm--compact-layout-p session)
         :on-search on-search
         :on-play-library on-play-library
         :on-refresh on-refresh)
        (etaf-ncm--view-chips
         :if (eq (etaf-ncm--read session :layout) 'narrow)
         :model session
         :groups etaf-ncm-sections
         :on-locate on-locate)
        (flex :position 'absolute :z-index 0 :left '(ch 0)
              :top (list 'lh (pcase (etaf-ncm--read session :layout) ('wide 2) ('narrow 6) (_ 3)))
              :visibility (if (etaf-ncm--read session :error) 'visible 'hidden)
              :width 'stretch :height '(lh 1)
              :align-items 'center :padding '((lh 0) (ch 1))
              :background-color (etaf-ncm-color :danger-bg)
              :color (etaf-ncm-color :danger)
          (box :height '(lh 1) :overflow 'hidden
            (text (expr (or (etaf-ncm--reactive-text (etaf-ncm--ref session :message)) "")))))
        (etaf-ncm--view-list
         :model session
         :compact (etaf-ncm--compact-layout-p session)
         :selection (etaf-ncm--ref session :selection)
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
       :on-switch on-switch-aside
       :on-jump on-jump-queue)
    (etaf-ncm--view-pane-tabs
     :if (etaf-ncm--compact-layout-p session)
     :pane-list pane-list
     :lyrics lyrics-visible
     :queue queue-visible
     :on-pane on-show-pane
     :on-aside on-show-aside)
    ;; The bar reserves six lines (five in compact layouts); the positioned host
    ;; in flow and the absolute panel inside is the retained publication
    ;; address, so a control toggle updates its Hosts without a view rebuild.
    (box :position 'relative :z-index 0 :width 'stretch
         :height (if (etaf-ncm--compact-layout-p session) '(lh 5) '(lh 6))
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

(defun etaf-ncm--apply-list-highlights (app &optional lines)
  "Move APP's highlight bars to LINES, defaulting to the current page.
Each bar is one retained host geometry update: a `:top' translation that
never republishes the list plane."
  (setf (plist-get app :highlight-timer) nil)
  (let ((lines (or lines (plist-get app :highlight-lines))))
    (when-let* ((buffer (plist-get app :buffer))
                ((buffer-live-p buffer))
                (runtime (etaf-runtime-for-buffer buffer))
                (lines lines))
      (ignore-errors
        (etaf-runtime-update-host-geometry runtime 'ncm-list-selection
                                           :top (list 'lh (car lines)))
        (etaf-runtime-update-host-geometry runtime 'ncm-list-playing
                                           :top (list 'lh (cdr lines)))))))

(defun etaf-ncm--schedule-list-highlights (app lines)
  "Coalesce APP's highlight-bar move to LINES onto the next tick.
Line changes are the only reason to schedule: a slot write that leaves both
bars where they are must not publish geometry.  Deferring keeps the move out
of the reactive batch that reported the change."
  (unless (equal lines (plist-get app :highlight-lines))
    (setf (plist-get app :highlight-lines) lines)
    (when (plist-get app :highlight-timer)
      (cancel-timer (plist-get app :highlight-timer)))
    (setf (plist-get app :highlight-timer)
          (run-at-time 0 nil #'etaf-ncm--apply-list-highlights app))))

(defun etaf-ncm-open (&optional model)
  "Open the NetEase Cloud Music player and return its buffer.
MODEL defaults to a session from `etaf-ncm-create', so the player opens on the
daily recommendation with the signed-in account, queue and playback status of
the backend.  A caller-provided MODEL keeps its library, queue and selection."
  (interactive)
  (let* ((model (or model (etaf-ncm-create)))
         (buffer (get-buffer-create etaf-ncm-buffer-name)))
    (plist-put model :buffer buffer)
    (with-current-buffer buffer
      (setq-local etaf-ncm--model model)
      (setq-local truncate-lines t)
      ;; The player is an absolutely positioned canvas: a horizontal window
      ;; scroll (C-e on a wide row, a narrower resize with point off screen)
      ;; would shift every region, so never let redisplay auto-scroll it.
      (setq-local auto-hscroll-mode nil)
      (setq-local mode-line-format nil)
      (setq-local emulation-mode-map-alists
                  (cons 'etaf-ncm--command-maps
                        (remq 'etaf-ncm--command-maps emulation-mode-map-alists)))
      ;; The player owns every column it paints.  A sub-cell rounding
      ;; remainder must not surface as Emacs's truncation glyph, so keep the
      ;; truncation slot blank instead of advertising a cut line.
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table))
      (etaf-ncm--remap-canvas-face)
      (use-local-map etaf-ncm-mode-map))
    ;; A native text app owns the window it was opened from: a general
    ;; `display-buffer' rule must not split the frame into a playground-style
    ;; pane, so open in the selected window and let the app fill it.
    (let ((display-buffer-overriding-action '((display-buffer-same-window))))
      (pop-to-buffer buffer))
    ;; The layout, page size and viewport come from the window that shows
    ;; the player, so the first paint already fits it.  The player adapts to
    ;; later resizes as well (see `etaf-ncm--sync-layout').
    (etaf-ncm--sync-layout model (selected-window))
    ;; Let ETAF choose its display-safe viewport from the visible window.
    ;; Passing the raw window body width overrides that policy and forces a
    ;; full refit on the first input when the renderer reserves its margins.
    (etaf-mount buffer (etaf-ncm-view model))
    (let ((runtime (etaf-runtime-for-buffer buffer)))
      (plist-put model :mounted-width (car (etaf-runtime-viewport runtime)))
      (etaf-runtime-flush runtime))
    (etaf-ncm--apply-list-highlights model (etaf-ncm--list-highlights model))
    buffer))

(defun etaf-ncm-close ()
  "Unmount the player and kill its buffer."
  (interactive)
  (when-let* ((runtime (etaf-runtime-for-buffer etaf-ncm-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-ncm-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-ncm-app)
;;; etaf-ncm-app.el ends here
