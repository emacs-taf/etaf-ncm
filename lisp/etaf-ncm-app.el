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
    (define-key map (kbd "s") #'etaf-ncm--search)
    (define-key map (kbd "/") #'etaf-ncm--search)
    (define-key map (kbd "g") #'etaf-ncm--refresh)
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

(defvar etaf-ncm--wheel-maps
  (list (cons 'etaf-ncm--model
              (let ((map (make-sparse-keymap)))
                (define-key map [wheel-up] #'etaf-ncm--wheel-up)
                (define-key map [wheel-down] #'etaf-ncm--wheel-down)
                map)))
  "Wheel bindings that take precedence over the renderer's minor-mode map.
Only wheel events are overridden, so TAB and focused RET activation still
reach the renderer.  The alist is enabled only in an opened player buffer.")

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
               (selection (etaf-ncm--read model :selection))
               (playing (plist-get (etaf-ncm--read model :status) :song-id)))
    (cl-loop for row in rows
             for index from start
             collect (list :index (1+ index)
                           :row row
                           :selected (= index selection)
                           :playing (and playing
                                         (eq (plist-get row :kind) :song)
                                         (equal (plist-get row :id) playing))))))

(defun etaf-ncm--view-status (model)
  "Return MODEL's playback status, or an empty status plist."
  (let ((status (or (etaf-ncm--read model :status)
                    (list :state 'idle :duration 0 :volume 0
                          :queue-pos 0 :queue-count 0 :shuffle nil :repeat nil))))
    (plist-put (copy-sequence status) :elapsed (etaf-ncm--clock model))))

(defun etaf-ncm--lyric-panel (model)
  "Return MODEL's lyric window as props for the lyrics View."
  (let* ((lyric (etaf-ncm--read model :lyric))
         (lines (plist-get lyric :lines))
         (budget (etaf-ncm--read model :lyric-rows))
         (trans (and (> budget 1) (plist-get lyric :trans)))
         (size (if trans (/ budget 2) budget))
         (elapsed (etaf-ncm--clock model))
         (index (and lines (etaf-ncm--lyric-index lines elapsed)))
         (window (and lines
                      (etaf-ncm--lyric-window lines index size)))
         (visible (cdr window)))
    (list :lines visible
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
  "Move the queue window or library selection by DELTA at EVENT's position."
  (let* ((position (event-start event))
         (window (posn-window position)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let* ((model (etaf-ncm--current-model))
               (pixels (posn-x-y position))
               (xy (and (consp pixels)
                        (cons (/ (float (car pixels)) (window-font-width window))
                              (/ (float (cdr pixels)) (window-font-height window))))))
          (if (and (null (posn-area position))
                   (etaf-ncm--queue-hit-p
                    xy (window-body-width window) (window-body-height window)
                    (etaf-ncm--read model :layout) (etaf-ncm--read model :pane)
                    (etaf-ncm--read model :aside)))
              (etaf-ncm--scroll-queue model delta)
            (etaf-ncm-move-selection model delta)))))))

(defun etaf-ncm--wheel-up (event)
  "Scroll the queue or select the previous library row at EVENT."
  (interactive "e")
  (etaf-ncm--wheel event -1))

(defun etaf-ncm--wheel-down (event)
  "Scroll the queue or select the next library row at EVENT."
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
  "Play the selected library row."
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
         (volume (or (plist-get (etaf-ncm--view-status model) :volume) 0)))
    (etaf-ncm-set-volume model (min 130 (+ volume 10)))))

(defun etaf-ncm--volume-down ()
  "Lower the volume by ten."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (volume (or (plist-get (etaf-ncm--view-status model) :volume) 0)))
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

(defun etaf-ncm--help ()
  "Show the player's key bindings."
  (interactive)
  (message
   (concat "j/k 或滚轮选择 · 单击选中 · 双击播放 · RET 播放 · SPC 暂停 · n/p 切歌 · a 加入队列 · s 搜索 · g 刷新"
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
             ;; Callbacks are instance values, not per-render closures: a
             ;; re-render that passes a new function object to a keyed child
             ;; would make that child render again for nothing.
             (on-locate (lambda (section) (etaf-ncm-locate session section)))
             (on-search (lambda (text) (etaf-ncm--search-text session text)))
             (on-play-library (lambda () (etaf-ncm-play session)))
             (on-refresh (lambda () (etaf-ncm-refresh session)))
             (on-press-row (lambda (index) (etaf-ncm-press-row session index)))
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
             (on-like (lambda () (etaf-ncm-like session)))
             (on-volume (lambda (delta)
                          (etaf-ncm-set-volume
                           session
                           (max 0 (min 130 (+ (or (plist-get (etaf-ncm--view-status session)
                                                             :volume)
                                                  0)
                                              delta))))))
             (on-seek (lambda (seconds) (etaf-ncm-seek session seconds)))
             (on-seek-drag (lambda (gesture) (etaf-ncm--drag-seek session gesture)))
             (on-shuffle (lambda ()
                           (etaf-ncm-set-shuffle
                            session
                            (not (plist-get (etaf-ncm--view-status session) :shuffle)))))
             (on-repeat (lambda ()
                          (etaf-ncm-set-repeat
                           session
                           (not (plist-get (etaf-ncm--view-status session) :repeat))))))
  :setup
  (progn
    (etaf-theme-provide palette)
    (etaf-on-mounted
     (lambda ()
       (etaf-ncm--start session)
       (etaf-ncm-refresh session)))
    (etaf-on-unmounted
     (lambda ()
       (etaf-ncm--dispose session))))
  :view
  (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
        ;; Rows that show symbol glyphs (the state dot, the transport icons, the
        ;; sidebar glyphs) render a little taller than the frame's line height
        ;; because their fallback font has larger metrics.  Keep the last line
        ;; clear so those extra pixels land in empty space instead of below the
        ;; window, which clipped the player bar's control row.
        :padding-bottom '(lh 1)
        :color (etaf-ncm-color :ink) :bgcolor (etaf-ncm-color :bg)
    (flex :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
          :align-items 'stretch
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'wide)
       :groups etaf-ncm-sections
       :section (etaf-ncm--read session :section)
       :account (etaf-ncm--read session :account)
       :on-locate on-locate)
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'medium)
       :compact t
       :groups etaf-ncm-sections
       :section (etaf-ncm--read session :section)
       :account (etaf-ncm--read session :account)
       :on-locate on-locate)
      (flex :if (etaf-ncm--list-shown-p session)
            :flex-direction 'column :width 'stretch :flex-grow 1
            :flex-basis '(px 0) :min-width '(ch 0) :min-height '(lh 0)
            :padding (if (etaf-ncm--compact-layout-p session)
                         '((lh 0) (ch 1)) '((lh 1) (ch 2)))
            :gap '((lh 1) (px 0))
        (etaf-ncm--view-header
         :title (etaf-ncm--read session :title)
         :subtitle (etaf-ncm--read session :subtitle)
         :query (etaf-ncm--read session :query)
         :loading (etaf-ncm--read session :loading)
         :compact (etaf-ncm--compact-layout-p session)
         :on-search on-search
         :on-play-all (and (etaf-ncm--playable-origin session) on-play-library)
         :on-refresh on-refresh)
        (etaf-ncm--view-chips
         :if (eq (etaf-ncm--read session :layout) 'narrow)
         :groups etaf-ncm-sections
         :section (etaf-ncm--read session :section)
         :on-locate on-locate)
        (flex :if (etaf-ncm--read session :error) :width 'stretch :height '(lh 1)
              :align-items 'center :padding '((lh 0) (ch 1))
              :background-color (etaf-ncm-color :danger-bg)
              :color (etaf-ncm-color :danger)
          (box :height '(lh 1) :overflow 'hidden
            (text (expr (or (etaf-ncm--read session :message) "")))))
        (etaf-ncm--view-list
         :entries (etaf-ncm--view-entries session)
         :start (1+ (nth 1 (etaf-ncm--page-rows session)))
         :total (etaf-ncm--read session :list-total)
         :loaded (length (etaf-ncm--read session :rows))
         :compact (etaf-ncm--compact-layout-p session)
         :empty-note (if (etaf-ncm--read session :loading)
                         "正在加载…"
                       "这里还没有内容：g 刷新，s 搜索")
         :on-press on-press-row))
      (etaf-ncm--view-aside
       :if (etaf-ncm--aside-shown-p session)
       :aside (etaf-ncm--read session :aside)
       :title (plist-get (etaf-ncm--view-status session) :title)
       :artist (plist-get (etaf-ncm--view-status session) :artist)
       :album (or (plist-get (etaf-ncm--selected-row session) :meta) "")
       :loading (plist-get (etaf-ncm--lyric-panel session) :loading)
       :lines (plist-get (etaf-ncm--lyric-panel session) :lines)
       :trans (plist-get (etaf-ncm--lyric-panel session) :trans)
       :current (plist-get (etaf-ncm--lyric-panel session) :current)
       :position (plist-get (etaf-ncm--lyric-panel session) :position)
       :total (plist-get (etaf-ncm--lyric-panel session) :total)
       :entries (plist-get (etaf-ncm--queue-panel session) :entries)
       :pos (plist-get (etaf-ncm--queue-panel session) :pos)
       :count (plist-get (etaf-ncm--queue-panel session) :count)
       :layout (etaf-ncm--read session :layout)
       :on-switch on-switch-aside
       :on-jump on-jump-queue))
    (etaf-ncm--view-pane-tabs
     :if (etaf-ncm--compact-layout-p session)
     :pane (etaf-ncm--read session :pane)
     :aside (etaf-ncm--read session :aside)
     :on-pane on-show-pane
     :on-aside on-show-aside)
    (etaf-ncm--view-player
     :compact (etaf-ncm--compact-layout-p session)
     :title (plist-get (etaf-ncm--view-status session) :title)
     :artist (plist-get (etaf-ncm--view-status session) :artist)
     :state (plist-get (etaf-ncm--view-status session) :state)
     :elapsed (plist-get (etaf-ncm--view-status session) :elapsed)
     :duration (plist-get (etaf-ncm--view-status session) :duration)
     :volume (plist-get (etaf-ncm--view-status session) :volume)
     :shuffle (plist-get (etaf-ncm--view-status session) :shuffle)
     :repeat (plist-get (etaf-ncm--view-status session) :repeat)
     :message (etaf-ncm--read session :message)
     :queue-pos (plist-get (etaf-ncm--view-status session) :queue-pos)
     :queue-count (plist-get (etaf-ncm--view-status session) :queue-count)
     :on-toggle on-toggle
     :on-next on-next
     :on-previous on-previous
     :on-stop on-stop
     :on-like on-like
     :on-volume on-volume
     :on-seek on-seek
     :on-seek-drag on-seek-drag
     :on-shuffle on-shuffle
     :on-repeat on-repeat)))

(defun etaf-ncm-view (&optional model)
  "Return the player View for MODEL.
MODEL defaults to a new session, exactly as `etaf-ncm-open' creates one; pass a
session from `etaf-ncm-create' to embed the player in your own mount."
  (etaf-view (etaf-ncm-app :model (or model (etaf-ncm-create)))))

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
      (setq-local mode-line-format nil)
      (setq-local emulation-mode-map-alists
                  (cons 'etaf-ncm--wheel-maps
                        (remq 'etaf-ncm--wheel-maps emulation-mode-map-alists)))
      ;; The player owns every column it paints.  A sub-cell rounding
      ;; remainder must not surface as Emacs's truncation glyph, so keep the
      ;; truncation slot blank instead of advertising a cut line.
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table))
      (use-local-map etaf-ncm-mode-map))
    (pop-to-buffer buffer)
    ;; The layout, page size and viewport come from the window that shows
    ;; the player, so the first paint already fits it.  The player adapts to
    ;; later resizes as well (see `etaf-ncm--sync-layout').
    (etaf-ncm--sync-layout model (selected-window))
    ;; Remember the canvas this mount paints at: a window that settles at a
    ;; different size must repaint instead of keeping the mount-time canvas.
    (plist-put model :mounted-width
               (plist-get (etaf-ncm--viewport-options (selected-window))
                          :viewport-width))
    (etaf-mount buffer (etaf-ncm-view model)
                 (etaf-ncm--viewport-options (selected-window)))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
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
