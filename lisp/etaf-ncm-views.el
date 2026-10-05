;;; etaf-ncm-views.el --- Views of the NetEase Cloud Music player -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer of etaf-ncm.  The Components here are internal: they take
;; plain values and callbacks, and never read the player model themselves.  The
;; public `etaf-ncm-app' Component owns that boundary, so a repaint happens in
;; exactly one place and these Views stay independently renderable.
;;
;; Only ETAF hosts and etaf-ui Components are used, and every color comes from
;; `etaf-ncm-color' so both palettes share one layout.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'ebox)
(require 'etaf-ncm-theme)
(require 'etaf-ncm-model)

(declare-function etaf-ncm--view-entries "etaf-ncm-app" (model))

;;; ---------------------------------------------------------------------------
;;; Shared geometry
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm--sidebar-width '(ch 24)
  "Width of the library sidebar.")

(defconst etaf-ncm--rail-width '(ch 6)
  "Width of the glyph-only library rail of a compact layout.")

(defconst etaf-ncm--aside-width '(ch 40)
  "Width of the lyrics and queue panel.")

(defconst etaf-ncm--row-columns '((ch 3) (fr 1) (ch 22) (ch 18) (ch 5) (ch 6) (ch 3) (ch 3))
  "Grid columns of one library row: index, title, artist, album, badge, time,
download, add to queue.")

(defconst etaf-ncm--row-columns-compact '((ch 3) (fr 1) (ch 18) (ch 5) (ch 6) (ch 3))
  "Grid columns of a compact library row: index, title, artist, badge, time,
download.")

(defun etaf-ncm--view-border (_side color)
  "Return the border value of SIDE drawn with COLOR."
  (list '(px 1) 'solid color))

(defun etaf-ncm--hover-surface ()
  "Return the hover declarations of a clickable row.
Ebox hover styles accept colours only, so this is the surface a pointer moves
over, one step above the panel it sits on."
  (list :background-color (etaf-ncm-color :panel2)))

(defun etaf-ncm--view-duration (milliseconds)
  "Return MILLISECONDS as \"M:SS\", or an empty string."
  (etaf-ncm--format-duration milliseconds))

(defun etaf-ncm--lyric-window (lines index size)
  "Return (START . VISIBLE) for a window of SIZE LINES around INDEX."
  (let* ((total (length lines))
         (size (max 0 (min size total)))
         (start (max 0 (min (- index (/ size 3)) (- total size)))))
    (cons start (seq-subseq lines start (+ start size)))))

(defun etaf-ncm--translation-for (trans seconds)
  "Return the translation of SECONDS from TRANS, or nil."
  (cdr (cl-assoc seconds trans :test #'=)))

;;; ---------------------------------------------------------------------------
;;; Primitive Views
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-nav-item (&key icon label section entry-key badge on-press chip help tight)
  "Render one library entry, retaining its active paint across navigation.
TIGHT drops the spacer line so a height-constrained sidebar shows every entry."
  :bindings ((active (etaf-computed (lambda () (eq (etaf-value section) entry-key)))))
  :view
  (flex :width (if chip '(ch 5) 'stretch) :height (if (or chip tight) '(lh 1) '(lh 2)) :flex-direction 'column
        :role 'button :tab-index 0
       
        :help-echo (or help label "音乐库")
        :on-press on-press
    ;; A callbackless button here would block the cell's inherited keymap.
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center :padding (if chip '((lh 0) (ch 1)) '((lh 0) (ch 2)))
          :hover-style (etaf-ncm--hover-surface)
          :background-color (if (etaf-value active) (etaf-ncm-color :accent-soft)
                              (etaf-ncm-color :panel))
          :color (if (etaf-value active) (etaf-ncm-color :ink) (etaf-ncm-color :muted))
          :font-weight 'normal
      (etaf-ui-toggle-icon :value active :off (or icon 'music) :on (or icon 'music)
                           :set 'svg :size 1.0 :min-width 3
                           :color (etaf-ncm-color :muted)
                           :on-color (etaf-ncm-color :accent))
      (box :if (not chip) :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'normal
        (text (expr (or label ""))))
      (box :if badge :width '(ch 5) :height '(lh 1) :text-align 'right
           :font-weight 'normal :color (etaf-ncm-color :dim)
        (text (expr badge))))
    (box :if (not (or chip tight)) :height '(lh 1))))

(etaf-define-component etaf-ncm--view-row
    (&key offset row playing selection compact press on-action)
  "Render library ROW number INDEX, highlighted when SELECTION names it.
ROW and PLAYING may be retained reactive sources; the row reads them inside
its Host text and paint bindings, so a list reply updates prepared values
instead of rebuilding the row.  COMPACT drops the album and add-to-queue
columns, which a narrow frame cannot show.  PRESS is called with INDEX when
the row is clicked, and ON-ACTION with INDEX plus the action key (`download' or
`queue') of the inline action the reader pressed."
  :bindings ((play-glyph (car (etaf-ui-icon-lines 'play :set 'svg :size 1.0
                                                  :color (etaf-ncm-color :accent))))
             (downloaded (etaf-computed
                          (lambda () (plist-get (etaf-ncm--reactive-text row) :downloaded))))
             (index (etaf-computed
                     (lambda () (or (plist-get (etaf-ncm--reactive-text row) :display-index) 0)))))
  :view
  (grid :position 'absolute :z-index 0 :left '(ch 0) :top (list 'lh offset)
        :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :visibility (if (etaf-ncm--reactive-text row) 'visible 'hidden)
        :grid-template-columns (if compact etaf-ncm--row-columns-compact
                                 etaf-ncm--row-columns)
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        ;; The unselected row paints the list background explicitly: a retained
        ;; paint binding needs a declared value, and an absent background
        ;; cannot acquire a prepared slot.
        :background-color (let ((playing (etaf-ncm--active-value playing))
                                (selected (eq (1- (etaf-ncm--active-value index)) (etaf-value selection))))
                            (cond (playing (etaf-ncm-color :accent-soft))
                                  (selected (etaf-ncm-color :panel2))
                                  (t (etaf-ncm-color :bg))))
        :color (if (etaf-ncm--active-value playing)
                   (etaf-ncm-color :accent)
                 (etaf-ncm-color :ink))
        :font-weight (let ((playing (etaf-ncm--active-value playing))
                           (selected (eq (1- (etaf-ncm--active-value index)) (etaf-value selection))))
                       (if (or playing selected) 'bold 'normal))
        :hover-style (etaf-ncm--hover-surface)
        :help-echo "播放这一行"
        :on-press (lambda () (when (etaf-ncm--reactive-text row)
                               (funcall press (etaf-ncm--active-value index))))
    (box :width '(ch 3) :height '(lh 1) :justify-self 'end
         :color (if (eq (1- (etaf-ncm--active-value index)) (etaf-value selection))
                    (etaf-ncm-color :muted)
                  (etaf-ncm-color :dim))
      ;; Both states belong to the same retained text Host. A hidden absolute
      ;; overlay has no initial composition target and poisons the fast cohort.
      (text (expr (let ((active (etaf-ncm--active-value playing))
                        (number (etaf-ncm--active-value index)))
                    (if active play-glyph (format "%2s" number))))))
    (box :height '(lh 1) :overflow 'hidden
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :name) ""))))
    (box :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-ncm-color :muted)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :subtitle) ""))))
    (box :if (not compact) :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :meta) ""))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-ncm-color :gold)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :badge) ""))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :right) ""))))
    (box :height '(lh 1) :justify-self 'center :min-width '(ch 2)
      ;; The download button doubles as the local-library marker: a registered
      ;; song shows a check and stays clickable to refresh the file.  The SVG
      ;; icon keeps the row at one line height.
      (etaf-ui-toggle-icon :value downloaded :off 'download :on 'check
                           :set 'svg :size 1.0 :min-width 3
                           :color (etaf-ncm-color :dim)
                           :on-color (etaf-ncm-color :accent)
                           :help-echo "下载到本地（勾号表示已下载，点击可重新下载）"
                           :on-press (lambda () (when (etaf-ncm--reactive-text row)
                                                  (funcall on-action (etaf-ncm--active-value index) 'download)))))
    (box :if (not compact) :height '(lh 1) :justify-self 'center :min-width '(ch 2)
      (etaf-ui-icon :name 'plus :set 'svg :size 1.0 :min-width 3
                    :color (etaf-ncm-color :dim)
                    :help-echo "加入队列"
                    :on-press (lambda () (when (etaf-ncm--reactive-text row)
                                           (funcall on-action (etaf-ncm--active-value index) 'queue)))))))

(etaf-define-component etaf-ncm--view-note (&key text)
  "Render TEXT as a quiet placeholder filling the content area.
TEXT may be a retained reactive source, so the note updates as prepared text."
  :view
  (box :width 'stretch :height '(lh 6) :text-align 'center
       :color (etaf-ncm-color :dim)
    (text (expr (or (etaf-ncm--reactive-text text) "")))))

(defun etaf-ncm--cover-size (file)
  "Return FILE's (WIDTH . HEIGHT) pixels, or nil when it cannot be read."
  (let ((head (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally file nil 0 16)
                (buffer-string))))
    (ignore-errors
      (let ((image (create-image file (image-type-from-data head) nil)))
        (and image (image-size image t))))))

(defun etaf-ncm--cover-grid (file chars lines)
  "Return the (COLS . ROWS) cell grid for FILE inside a CHARS x LINES cover.
The grid keeps FILE's aspect ratio; Ebox scales the raster to it, so both
dimensions stay cell-aligned and every row is fully covered."
  (let* ((size (etaf-ncm--cover-size file))
         (cell-w (max 1 (frame-char-width)))
         (cell-h (max 1 (frame-char-height)))
         (image-w (max 1 (or (car-safe size) 1)))
         (image-h (max 1 (or (cdr-safe size) 1)))
         (cols (max 1 (round (/ (* (float lines) cell-h image-w)
                                (* (float image-h) cell-w)))))
         (rows lines))
    (when (> cols chars)
      (setq cols chars
            rows (max 1 (min lines (round (/ (* (float chars) cell-w image-h)
                                              (* (float image-w) cell-h)))))))
    (cons cols rows)))

(defun etaf-ncm--cover-rows (file chars lines)
  "Return LINES rows of CHARS cells showing FILE, or nil for the placeholder.
Ebox prepares the raster for the chosen cell grid: the image is scaled onto
cells, every cell carries its immutable slice, and the grid is centered with
blank cells.  Hand-slicing at row boundaries leaves half-covered rows, which
paint as seams; the prepared raster is the seam-free path."
  (when (and (stringp file) (file-readable-p file)
             (integerp chars) (> chars 0) (integerp lines) (> lines 0))
    (condition-case nil
        (let* ((grid (etaf-ncm--cover-grid file chars lines))
               (cols (car grid))
               (rows (cdr grid))
               (content (ebox-image-content (ebox-image-prepare file cols rows)))
               (parts (and (stringp content) (split-string content "\n")))
               (lead (max 0 (/ (- chars cols) 2)))
               (top (max 0 (/ (- lines rows) 2)))
               (blank (make-string chars ?\s))
               (prefix (make-string lead ?\s))
               result)
          (dotimes (_ top) (push blank result))
          (dolist (part parts) (push (concat prefix part) result))
          (while (< (length result) lines) (push blank result))
          (seq-take (nreverse result) lines))
      (error nil))))

(etaf-define-component etaf-ncm--view-cover-row (&key cell)
  "Render one cover-art row cell inside the cover block."
  :view
  (box :width 'stretch :height '(lh 1) :text-align 'center
    (text (expr cell))))

(etaf-define-component etaf-ncm--view-cover
    (&key size glyph (height '(lh 7)) file (chars 10) (lines 7))
  "Render FILE's album art, or a square placeholder of SIZE characters.
FILE is a reactive source or a literal path; CHARS and LINES must match the
cell the caller reserves so the image never exceeds its canvas."
  :render
  (let* ((value (and file (if (or (etaf-ref-p file) (etaf-computed-p file))
                              (etaf-value file)
                            file)))
         (rows (and value (etaf-ncm--cover-rows value chars lines)))
         (indices (and rows (number-sequence 0 (1- (length rows))))))
    (etaf-view
     (flex :flex-direction 'column :width size :height height
           :bgcolor (etaf-ncm-color :panel3)
           :align-items 'center :justify-content 'center
       (column :if indices :width 'stretch :item-gap '(lh 0)
         (etaf-ncm--view-cover-row :for (index indices) :key index
                                   :cell (nth index rows)))
       (etaf-ui-icon :if (and (not indices) (not glyph)) :name 'music :set 'svg
                     :size 1.0 :min-width 2 :color (etaf-ncm-color :accent))
       (text :if (and (not indices) glyph) :height '(lh 1) :text-align 'center
             (expr glyph))))))

(etaf-define-component etaf-ncm--view-sidebar
    (&key model groups compact height on-locate)
  "Render the library sidebar with MODEL's current SECTION highlighted.
COMPACT renders the glyph-only rail a medium layout has room for.  A HEIGHT
that cannot hold the two-line entries switches the sidebar to a tight
one-line-per-entry form, so every library stays visible in short frames.
The component reads the session sources itself, so a library switch repaints
the sidebar instead of the whole application."
  :render
  (let* ((section (etaf-ncm--ref model :section))
         (account (etaf-ncm--read model :account))
         (rows (and (eq (car-safe height) 'lh) (numberp (cadr height)) (cadr height)))
         (entries (apply #'append (mapcar #'cdr groups)))
         (tight (and rows
                     (< rows (+ 2 (* 2 (length entries))
                                (* 3 (1- (length groups))))))))
    (etaf-view
  (flex :position 'absolute :left '(px 0) :top '(lh 0)
        :flex-direction 'column
        :width (if compact etaf-ncm--rail-width etaf-ncm--sidebar-width)
        :height height
        :padding (if tight '((lh 0) (ch 1)) '((lh 1) (ch 1))) :gap '((lh 0) (ch 0))
        :background-color (etaf-ncm-color :panel)
        :border-right (etaf-ncm--view-border 'right (etaf-ncm-color :line))
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center :padding '((lh 0) (ch 1))
      (etaf-ui-icon :name 'music :set 'svg :size 1.0 :min-width 2
                    :color (etaf-ncm-color :accent))
      (box :if (not compact) :height '(lh 1)
        (text :font-weight 'bold "网易云音乐"))
      (box :if (not compact) :height '(lh 1) :color (etaf-ncm-color :dim)
        (text "NCM")))
    (column :for (group groups) :key (car group) :width 'stretch :item-gap '(lh 0)
      ;; A group reads as a section: a blank line, a small bold label, one more
      ;; blank line and then its entries, so the label cannot be mistaken for
      ;; the first entry.
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1))
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1)
           :padding '((lh 0) (ch 2)) :font-size 12 :font-weight 'bold
           :color (etaf-ncm-color :muted)
        (text (expr (format "%s" (car group)))))
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1))
      (etaf-ncm--view-nav-item :for (entry (cdr group)) :key (car entry)
        :icon (nth 2 entry)
        :label (if compact "" (nth 1 entry)) :help (nth 1 entry)
        :tight tight
        :section section :entry-key (car entry)
        :on-press (lambda () (funcall on-locate (car entry)))))
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
          :padding '((lh 1) (ch 1))
          :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
      (box :width '(ch 1) :height '(lh 1) :flex-shrink 0
           :background-color (etaf-ncm-color (if account :ok :danger)))
      (box :if (not compact) :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
           :height '(lh 1)
           :overflow 'hidden :color (etaf-ncm-color :muted)
        (text (expr (if account
                         (format "%s%s" (or (plist-get account :nick) "已登录")
                                 (if (etaf-ncm--truthy-string-p
                                      (plist-get account :vip))
                                     " ·VIP" ""))
                       "未登录")))))))))

(etaf-define-component etaf-ncm--view-chips
    (&key model groups on-locate)
  "Render the libraries as a strip of glyph chips, as a narrow layout does.
The strip replaces the sidebar: every library stays one press away while the
header keeps showing the current library's name.  The component reads the
session source itself, so a library switch repaints the chips only."
  :render
  (let ((section (etaf-ncm--ref model :section)))
    (etaf-view
     (flex :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 4)
           :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
           :align-items 'center :overflow 'hidden
       (etaf-ncm--view-nav-item :for (entry (apply #'append (mapcar #'cdr groups))) :key (car entry)
         :chip t :icon (nth 2 entry) :label (nth 1 entry)
         :section section :entry-key (car entry)
         :on-press (lambda () (funcall on-locate (car entry))))))))

(etaf-define-component etaf-ncm--view-header
    (&key model compact on-search on-play-library on-refresh)
  "Render the content header for MODEL's current library.
COMPACT stacks the search field under the title, the shape a narrow frame
needs.  The component reads the session sources itself, so a title or loading
change repaints the header instead of the whole application."
  :bindings ((playable (etaf-ncm--ref model :playable)))
  :render
  (let* ((title (etaf-ncm--ref model :title))
         (subtitle (etaf-ncm--ref model :subtitle))
         (query (etaf-ncm--read model :query)))
    (etaf-view
  (column :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
          :width 'stretch :height (if compact '(lh 3) '(lh 2)) :item-gap '(lh 0)
    (flex :if compact :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'bold
        (text (expr (or (etaf-value title) ""))))
      (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
           :font-size 12
        (text (expr (or (etaf-value subtitle) ""))))
      (etaf-button :label "换一批" :variant 'ghost
                   :help-echo "换一批"
                   :on-press on-refresh))
    (flex :if compact :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
      (flex :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (box :visibility (if (etaf-value playable) 'visible 'hidden)
        (etaf-button :label "▶ 播放全部" :variant 'primary :pointer 'hand
                     :help-echo "播放整个列表" :on-press on-play-library)))
    (flex :if (not compact) :width 'stretch :height '(lh 2)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 10) :item-gap '(lh 0)
        (text :font-weight 'bold (expr (or (etaf-value title) "")))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
             :font-size 12
          (text (expr (or (etaf-value subtitle) "")))))
      (box :width '(ch 30) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (box :visibility (if (etaf-value playable) 'visible 'hidden)
        (etaf-button :label "播放全部" :variant 'primary :pointer 'hand
                     :help-echo "播放整个列表" :on-press on-play-library))
      (etaf-button :label "换一批" :variant 'ghost
                   :help-echo "换一批"
                   :on-press on-refresh))))))

(defun etaf-ncm--pane-tab-source (key pane-list lyrics queue)
  "Return KEY's reactive active source among the pane switch flags."
  (pcase key
    ('list pane-list)
    ('lyrics lyrics)
    (_ queue)))

(etaf-define-component etaf-ncm--view-pane-tabs
    (&key pane-list lyrics queue on-pane on-aside)
  "Render the list/lyrics/queue switch a compact layout uses.
PANE-LIST, LYRICS and QUEUE are reactive sources; each tab reads them inside
its Host bindings, so switching a pane publishes retained paint instead of
rebuilding the view."
  :view
  (flex :position 'relative :z-index 2
        :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
        :flex-shrink 0 :align-items 'center :padding '((lh 0) (ch 2))
        :background-color (etaf-ncm-color :panel)
        :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (flex :for (tab (list (list 'list "列表")
                          (list 'lyrics "歌词")
                          (list 'queue "队列"))) :key (car tab)
      :width '(ch 8) :height '(lh 1) :flex-grow 0 :flex-shrink 0
      :justify-content 'center :align-items 'center
      :padding '((lh 0) (ch 1)) :role 'button :tab-index 0
      :hover-style (etaf-ncm--hover-surface)
      :help-echo (nth 1 tab)
      :background-color (if (etaf-value (etaf-ncm--pane-tab-source
                                         (car tab) pane-list lyrics queue))
                            (etaf-ncm-color :accent-soft)
                          (etaf-ncm-color :panel))
      :color (if (etaf-value (etaf-ncm--pane-tab-source
                              (car tab) pane-list lyrics queue))
                 (etaf-ncm-color :accent)
               (etaf-ncm-color :muted))
      :font-weight (if (etaf-value (etaf-ncm--pane-tab-source
                                    (car tab) pane-list lyrics queue))
                       'bold 'normal)
      :on-press (if (eq (car tab) 'list)
                    (lambda () (funcall on-pane 'list))
                  (lambda () (funcall on-aside (car tab))))
      (box :height '(lh 1)
        (text (expr (nth 1 tab)))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
         :height '(lh 1) :text-align 'right :color (etaf-ncm-color :dim)
         :font-size 12 :overflow 'hidden
      (text (expr (let ((list-p (etaf-value pane-list))
                        (lyrics-p (etaf-value lyrics))
                        (queue-p (etaf-value queue)))
                    (cond (list-p "j/k 或滚轮选择 · 双击播放")
                          (queue-p "l 切换面板")
                          (lyrics-p "l 歌词/队列")
                          (t "l 切换面板"))))))))

(etaf-define-component etaf-ncm--view-list
    (&key model compact selection on-press on-action)
  "Render MODEL's visible rows through retained row slots and a page footer.
Each visible row keeps its slot identity across library switches, so a reply
updates prepared row text and paint instead of rebuilding the list.  SELECTION
is the player's reactive selection source; ON-PRESS is called with a row's
page index when that row is clicked, and ON-ACTION with that index plus an
inline action key."
  :render
  (let* ((slots (plist-get model :row-slots))
         (playing (plist-get model :row-playing))
         (visible (etaf-ncm--ref model :visible-count))
         (count (min (etaf-ncm--read model :page-size) (length slots)))
         (offsets (and (> count 0) (number-sequence 0 (1- count))))
         (page-label (etaf-ncm--ref model :page-label))
         (loaded-label (etaf-ncm--ref model :loaded-label))
         (empty-note (etaf-ncm--ref model :empty-note))
         (footer-visible (etaf-ncm--ref model :footer-visible))
         (more-visible (etaf-ncm--ref model :more-visible))
         (layout (etaf-ncm--read model :layout))
         (window-rows (etaf-ncm--read model :window-rows))
         (top (pcase layout ('wide 3) ('narrow 7) (_ 4)))
         (height (if window-rows
                     (max 1 (- window-rows (pcase layout ('wide 12) ('narrow 14) (_ 11))))
                   (+ count 2))))
    (etaf-view
     (flex :position 'absolute :z-index 0 :left '(ch 0) :top (list 'lh top)
           :flex-direction 'column :width 'stretch :height (list 'lh height)
           :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
       (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
            :width 'stretch :height '(lh 6)
            :visibility (if (zerop (etaf-value visible)) 'visible 'hidden)
         (etaf-ncm--view-note :text empty-note))
       (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
            :width 'stretch :height (list 'lh count)
         (etaf-ncm--view-row :for (offset offsets) :key offset
           :offset offset
           :row (aref slots offset)
           :playing (aref playing offset)
           :selection selection
           :compact compact
           :press on-press
           :on-action on-action))
       (flex :position 'absolute :z-index 0 :left '(ch 0) :top (list 'lh (max 0 (- height 2)))
             :flex-direction 'column
             :visibility (if (etaf-value footer-visible) 'visible 'hidden)
             :width 'stretch :height '(lh 2)
             :flex-shrink 0 :gap '((lh 0) (px 0))
             :color (etaf-ncm-color :dim) :font-size 12
         (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
           (box :height '(lh 1) :flex-shrink 0
             (text (expr (etaf-ncm--reactive-text page-label))))
           (box :if (not compact) :height '(lh 1) :overflow 'hidden
                :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
             (text "j/k 或滚轮选择 · 双击播放 · a 入队 · d 下载 · / 搜索 · l 歌词 · ? 帮助")))
         (box :height '(lh 1)
              :visibility (if (and (etaf-value footer-visible) (etaf-value more-visible)) 'visible 'hidden)
           (text (expr (etaf-ncm--reactive-text loaded-label)))))))))

(etaf-define-component etaf-ncm--view-list-panel
    (&key layout columns window-rows visible)
  "Wrap the library column in an absolute stage panel.
VISIBLE is the reactive source that shows the list; LAYOUT, COLUMNS and
WINDOW-ROWS place and size the panel in the same cells the content budgets
assume, keeping its footer above the pane switch and the player bar.  The
panel is a direct child of the root plane, so the rows inside it keep a
retained canvas and a selection change publishes retained row paint instead
of rebuilding the view."
  :render
  (let* ((sidebar-ch (cadr etaf-ncm--sidebar-width))
         (rail-ch (cadr etaf-ncm--rail-width))
         (aside-ch (cadr etaf-ncm--aside-width))
         (columns (or columns 0))
         (wide-p (eq layout 'wide))
         (rows (or window-rows 0))
         (height (and (> rows 0)
                      (max 1 (- rows 1 (if wide-p 6 5) (if wide-p 0 1)))))
         (left (cond (wide-p sidebar-ch)
                     ((eq layout 'medium) rail-ch)
                     (t 0)))
         (width (cond (wide-p (max 1 (- columns sidebar-ch aside-ch)))
                      ((eq layout 'medium) (max 1 (- columns rail-ch)))
                      (t (max 1 columns)))))
    (etaf-view
     (box :position 'absolute :left (list 'ch left) :top '(lh 0)
          :width (list 'ch width) :height (if height (list 'lh height) '(% 100)) :z-index 0
          :visibility (if (etaf-value visible) 'visible 'hidden)
       (flex :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
             :flex-direction 'column :width 'stretch :height 'stretch
             :min-width '(ch 0) :min-height '(lh 0)
             :padding (if wide-p '((lh 1) (ch 2)) '((lh 0) (ch 1)))
             :gap '((lh 1) (px 0))
         (expr (etaf-current-slot 'default)))))))

;;; ---------------------------------------------------------------------------
;;; Lyrics, queue and player
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-tabs (&key kind on-switch)
  "Render the lyrics/queue switch with KIND active.
Each aside variant draws its own static tab row, so the active underline and
paint never re-render when the other variant becomes visible."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :align-items 'center
        :border-bottom (etaf-ncm--view-border 'bottom (etaf-ncm-color :line))
    (box :height '(lh 2) :padding '((lh 0) (ch 0)) :role 'button :tab-index 0
        
         :hover-style (etaf-ncm--hover-surface)
         :help-echo "看歌词"
         :font-weight (if (eq kind 'lyrics) 'bold 'normal)
         :color (if (eq kind 'lyrics) (etaf-ncm-color :ink)
                  (etaf-ncm-color :muted))
         :border-bottom (and (eq kind 'lyrics)
                             (etaf-ncm--view-border 'bottom
                                                    (etaf-ncm-color :accent)))
         :on-press (lambda () (funcall on-switch 'lyrics))
      (text "歌词"))
    (box :height '(lh 2) :role 'button :tab-index 0
        
         :hover-style (etaf-ncm--hover-surface)
         :help-echo "看播放队列"
         :font-weight (if (eq kind 'queue) 'bold 'normal)
         :color (if (eq kind 'queue) (etaf-ncm-color :ink)
                  (etaf-ncm-color :muted))
         :border-bottom (and (eq kind 'queue)
                             (etaf-ncm--view-border 'bottom
                                                    (etaf-ncm-color :accent)))
         :on-press (lambda () (funcall on-switch 'queue))
      (text "播放队列"))))

(etaf-define-component etaf-ncm--view-lyric-cell (&key projection index)
  "Keep one physical lyric row while its text and current-line paint change."
  :bindings ((cell (etaf-computed
                   (lambda () (nth index (plist-get (etaf-value projection) :cells))) :test #'equal)))
  :view
  (box :height '(lh 1) :overflow 'hidden
       :color (let ((row (etaf-value cell)))
                (etaf-ncm-color (cond ((plist-get row :current) :accent)
                                      ((plist-get row :translation) :dim) (t :muted))))
       :font-weight (if (plist-get (etaf-value cell) :current) 'bold 'normal)
    (text (expr (let* ((row (etaf-value cell)) (text (or (plist-get row :text) "")))
                  (if (plist-get row :translation) (propertize text 'face '(:height 0.85)) text))))))

(etaf-define-component etaf-ncm--view-lyrics
    (&key title artist album cover projection rows)
  "Render retained metadata and a viewport-sized lyric row pool."
  :render
  (let ((offsets (and (> rows 0) (number-sequence 0 (1- rows)))))
   (etaf-view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
      (etaf-ncm--view-cover :size '(ch 10) :chars 10 :lines 7 :file cover)
      (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text (expr (or (etaf-ncm--reactive-text title) "还没有播放"))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
          (text (expr (or (etaf-ncm--reactive-text artist) ""))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :dim)
             :font-size 12
          (text (expr (or (etaf-ncm--reactive-text album) ""))))))
    (box :height '(lh 1))
    (flex :flex-direction 'column :width 'stretch :flex-grow 1
          :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
      (etaf-ncm--view-lyric-cell :for (index offsets) :key index :projection projection :index index))
    (box :width 'stretch :height '(lh 1) :color (etaf-ncm-color :dim)
         :font-size 12 :text-align 'center
      (text (expr (let ((data (etaf-value projection)))
                    (if (plist-get data :lines)
                        (format "%s / %s" (or (plist-get data :position) 0) (or (plist-get data :total) 0)) "")))))))))

(etaf-define-component etaf-ncm--view-queue-cell (&key projection index on-jump)
  "Render one retained queue slot, resolving its current identity on activation."
  :bindings ((entry (etaf-computed (lambda () (nth index (plist-get (etaf-value projection) :entries))) :test #'equal))
             (glyph (car (etaf-ui-icon-lines 'play :set 'svg :color (etaf-ncm-color :accent)))))
  :view
  (flex :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :visibility (if (etaf-value entry) 'visible 'hidden)
        :help-echo (lambda (&rest _)
                     (let ((row (etaf-value entry)))
                       (when row (format "播放队列第 %s 首：%s" (plist-get row :index) (plist-get row :name)))))
        :hover-style (etaf-ncm--hover-surface)
        :gap '((lh 0) (ch 1)) :align-items 'center
        :background-color (if (plist-get (etaf-value entry) :current)
                              (etaf-ncm-color :accent-soft) (etaf-ncm-color :panel))
        :color (if (plist-get (etaf-value entry) :current) (etaf-ncm-color :accent) (etaf-ncm-color :muted))
        :font-weight (if (plist-get (etaf-value entry) :current) 'bold 'normal)
        :on-press (lambda () (when-let* ((row (etaf-value entry))) (funcall on-jump (plist-get row :index))))
    (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim)
      (text (expr (let ((row (etaf-value entry)))
                    (cond ((null row) "") ((plist-get row :current) glyph)
                          (t (format "%s." (plist-get row :index))))))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1) :overflow 'hidden
      (text (expr (or (plist-get (etaf-value entry) :name) ""))))
    (box :width '(ch 5) :height '(lh 1) :text-align 'right :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-value entry) :right) ""))))))

(etaf-define-component etaf-ncm--view-queue (&key projection rows on-jump)
  "Render a viewport-sized queue pool without replacing rows on every scroll."
  :render
  (let ((offsets (and (> rows 0) (number-sequence 0 (1- rows)))))
   (etaf-view
  (flex :position 'relative :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (column :width 'stretch :height '(lh 2) :item-gap '(lh 0)
      (text :font-weight 'bold "播放队列")
      (text :color (etaf-ncm-color :dim)
            (expr (let* ((data (etaf-value projection)) (entries (plist-get data :entries)))
                    (format "第 %s-%s 首 / 共 %s 首" (or (plist-get (car entries) :index) 0)
                            (or (plist-get (car (last entries)) :index) 0) (or (plist-get data :count) 0))))))
    (box :position 'absolute :z-index 0 :top '(lh 2) :left '(ch 0) :height '(lh 1)
         :visibility (if (plist-get (etaf-value projection) :entries) 'hidden 'visible)
         :color (etaf-ncm-color :dim)
      (text "队列是空的"))
    (etaf-ncm--view-queue-cell :for (index offsets) :key index :projection projection :index index :on-jump on-jump)))))

(etaf-define-component etaf-ncm--view-aside
    (&key kind visible layout columns window-rows title artist album cover projection rows on-switch on-jump)
  "Render one absolute aside variant: KIND is `lyrics' or `queue'.
Both variants are panels of the root stage; VISIBLE is the reactive source
that reveals this one, so switching panels publishes retained visibility
updates instead of rebuilding the view.  LAYOUT and COLUMNS size and place
the panel in the same cells the wheel hit test uses.  The panel ends at the
window bottom; the player bar paints over its last rows, and the row budgets
already stop the content above it."
  :render
  (let* ((aside-ch (cadr etaf-ncm--aside-width))
         (rail-ch (cadr etaf-ncm--rail-width))
         (columns (or columns 0))
         ;; The panel spans the window; ROWS is the row budget each panel view
         ;; keeps for its own pool, so this local must not shadow that prop.
         (window-height (or window-rows 0))
         (height (and (> window-height 0)
                      (max 1 (- window-height 1 (if (eq layout 'wide) 6 5)
                                (if (eq layout 'wide) 0 1)))))
         (left (cond ((eq layout 'wide) (max 0 (- columns aside-ch)))
                     ((eq layout 'medium) rail-ch)
                     (t 0)))
         (width (cond ((eq layout 'wide) aside-ch)
                      ((eq layout 'medium) (max 1 (- columns rail-ch)))
                      (t (max 1 columns)))))
    (etaf-view
     (box :position 'absolute :left (list 'ch left) :top '(lh 0)
          :width (list 'ch width) :height (if height (list 'lh height) '(% 100)) :z-index 0
          :visibility (if (etaf-value visible) 'visible 'hidden)
          :padding '((lh 1) (ch 2))
          :background-color (etaf-ncm-color :panel)
          :border-left (etaf-ncm--view-border 'left (etaf-ncm-color :line))
       (flex :flex-direction 'column :width 'stretch :height 'stretch
             :min-width '(ch 0) :gap '((lh 0) (px 0))
         (etaf-ncm--view-tabs :kind kind :on-switch on-switch)
         (etaf-ncm--view-lyrics :if (eq kind 'lyrics)
           :title title :artist artist :album album :cover cover
           :projection projection :rows rows)
         (etaf-ncm--view-queue :if (eq kind 'queue)
           :projection projection :rows rows :on-jump on-jump))))))

(defun etaf-ncm--reactive-text (text)
  "Return TEXT's current string, reading a reactive source in place.
Reading inside the Host expression keeps the dependency on the source instead
of subscribing the rendering Component to it."
  (if (or (etaf-ref-p text) (etaf-computed-p text)) (etaf-value text) text))

(defun etaf-ncm--active-value (active)
  "Return ACTIVE's current boolean for a HOST binding.
A reactive source, ref or computed, is read at the call site, which keeps the
read inside the host property binding instead of subscribing the whole
component.  A computed object is truthy on its own, so failing to read it
would mark every row as playing."
  (if (or (etaf-ref-p active) (etaf-computed-p active)) (etaf-value active) active))

(etaf-define-component etaf-ncm--view-control (&key icon icons glyph label help on-press active value ref)
  "Render one compact player action.
ICON names an `etaf-ui-icon' in the SVG style, so the control keeps one
optical size and never changes the row height.  ICONS, when given, is an
\(OFF . ON) icon-name pair rendered by `etaf-ui-toggle-icon'; VALUE is then the
reactive source that selects the variant, so a state change publishes a
retained Host text update instead of re-rendering the view.  GLYPH is the
plain-text alternative for controls that are words (词 ON) instead of
pictures.  LABEL appends a small count or state next to the icon."
  :view
  (flex :width 'max-content :height '(lh 1) :align-items 'center :flex-shrink 0
        :gap '((lh 0) (ch 1))
    (etaf-ui-toggle-icon :if icons :value (or value active)
                         :off (car icons) :on (cdr icons)
                         :set 'svg :size 1.0
                         :color (etaf-ncm-color :muted)
                         :on-color (etaf-ncm-color :accent)
                         :min-width 3 :help-echo help :on-press on-press :ref ref)
    (etaf-ui-icon :if (and icon (not icons)) :name (or icon 'music) :set 'svg :size 1.0
                  :color (etaf-ncm-color (if active :accent :muted))
                  :min-width 3 :help-echo help :on-press on-press :ref ref)
    (box :if (and (not icon) (not icons) glyph) :height '(lh 1) :role 'button :tab-index 0
         :color (etaf-ncm-color (if active :accent :muted))
         :hover-style (etaf-ncm--hover-surface)
         :help-echo help :on-press on-press
      (text (expr (or glyph ""))))
    (box :if label :height '(lh 1) :color (etaf-ncm-color :muted)
      (text (expr (format "%s" (or (etaf-ncm--reactive-text label) "")))))))

(defun etaf-ncm--track-label (title artist vip)
  "Format retained TITLE, ARTIST and VIP without changing dependency branches."
  (let ((name (or (etaf-ncm--reactive-text title) ""))
        (performer (or (etaf-ncm--reactive-text artist) ""))
        (premium (etaf-ncm--active-value vip)))
    (concat (if premium (propertize "VIP " 'face (list :foreground (etaf-ncm-color :accent) :weight 'normal)) "")
            (if (string-empty-p name) "未在播放" name)
            (if (string-empty-p performer) "" (concat " - " performer)))))

(etaf-define-component etaf-ncm--view-track
    (&key title artist vip queue-count compact shuffle message liked cover
          on-lyrics on-add on-like on-shuffle on-stop on-queue)
  "Render the cover, one-line track identity and the small action row."
  :view
  (grid :width 'stretch :height (if compact '(lh 1) '(lh 3))
        :grid-template-columns (if compact '((fr 1) (ch 24)) '((ch 6) (fr 1)))
        :gap '((lh 0) (ch 1)) :align-items 'center
    (box :if (not compact) :id "ncm-cover" :ref 'ncm-cover :width '(ch 6) :height '(lh 3)
         :role 'button :tab-index 0
         :help-echo "显示歌词"
         :on-press on-lyrics
      (etaf-ncm--view-cover :size '(ch 6) :height '(lh 3) :chars 6 :lines 3
                            :file (and (not compact) cover)))
    (box :if compact :height '(lh 1) :width 'stretch
         :min-width '(ch 0) :overflow 'hidden :font-weight 'bold
      (text :ref 'ncm-track-title (expr (etaf-ncm--track-label title artist vip))))
    (flex :flex-direction 'column :width 'stretch :min-width '(ch 0)
          :gap '((lh 0) (ch 1)) :justify-content 'center
      (flex :if (not compact) :height '(lh 1) :width 'stretch
            :min-width '(ch 0)
            :gap '((lh 0) (ch 1)) :align-items 'center
        (box :height '(lh 1) :flex-grow 1 :flex-basis '(px 0)
             :min-width '(ch 0) :overflow 'hidden :font-weight 'bold
          (text :ref 'ncm-track-title (expr (etaf-ncm--track-label title artist vip)))))
      (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
        (etaf-ncm--view-control :ref 'ncm-plus :icon 'plus :help "加入队列 (a)" :on-press on-add)
        (etaf-ncm--view-control :ref 'ncm-like :icons '(heart . heart-filled)
                                :value liked
                                :help "喜欢 / 取消喜欢 (f / F)" :on-press on-like)
        (etaf-ncm--view-control :ref 'ncm-shuffle :icons '(shuffle . shuffle)
                                :value shuffle
                                :help "随机播放 (z)" :on-press on-shuffle)
        (etaf-ncm--view-control :ref 'ncm-stop :icon 'close :help "停止" :on-press on-stop)
        (etaf-ncm--view-control :ref 'ncm-queue :icon 'queue :help "显示播放列表" :on-press on-queue
                                :label queue-count))
      (box :if (not compact) :height '(lh 1) :width 'stretch
           :overflow 'hidden :color (etaf-ncm-color :dim)
        (text (expr (or (etaf-ncm--reactive-text message) "")))))))

(etaf-define-component etaf-ncm--view-transport
    (&key playing repeat compact on-like on-previous on-toggle on-next on-repeat)
  "Render the centred transport with an accent play control.
PLAYING is the reactive boolean that selects the play/pause glyph, and REPEAT
the reactive flag that paints the repeat control; both publish through
retained Host text, so a toggle never rebuilds the bar.  The play control is a
one-line accent pill: a bigger glyph would paint outside its row and clip,
which a terminal-cell layout cannot round away."
  :view
  (flex :height (if compact '(lh 1) '(lh 2))
        :gap (if compact '((lh 0) (ch 1)) '((lh 0) (ch 3)))
        :align-items 'center :justify-content 'center
    (etaf-ncm--view-control :ref 'ncm-previous :icon 'previous :help "上一首 (p)" :on-press on-previous)
    (box :id "ncm-play" :ref 'ncm-play :width (if compact '(ch 3) '(ch 4))
         :height '(lh 1) :flex-shrink 0
         :role 'button :tab-index 0
         :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle
         :background-color (etaf-ncm-color :accent)
      (etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg :size 0.9
                           :color (etaf-ncm-color :ink) :on-color (etaf-ncm-color :ink)
                           ;; Span the whole pill so the glyph centres with one inset on
                           ;; both sides; a narrower icon leaves the right side heavier.
                           :min-width (if compact 3 4)
                           :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle))
    (etaf-ncm--view-control :ref 'ncm-next :icon 'next :help "下一首 (n)" :on-press on-next)
    (etaf-ncm--view-control :ref 'ncm-repeat :icons '(repeat . repeat) :value repeat
                            :help "列表循环 (r)" :on-press on-repeat)))

(etaf-define-component etaf-ncm--view-progress
    (&key elapsed duration on-seek)
  "Render elapsed, a draggable progress range and the duration.
Both ELAPSED and DURATION are read by retained Host bindings: the range
clamps a reactive :max itself, so a song change updates the meter in place
instead of re-rendering this Component and republishing the view."
  :render
  (etaf-view
  (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
    (box :width '(ch 5) :height '(lh 1) :text-align 'right
         :color (etaf-ncm-color :dim) :flex-shrink 0
      (text :ref 'ncm-elapsed :id "ncm-elapsed"
            (expr (etaf-ncm--format-seconds (etaf-ncm--active-value elapsed)))))
    (flex :flex-direction 'row :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
          :height '(lh 1)
      (etaf-range :value elapsed :min 0 :max duration
                  :ref 'ncm-seek :fill-ref 'ncm-meter
                  :aria-label "播放进度，点击或拖动跳转"
                  :color (etaf-ncm-color :accent)
                  :track-color (etaf-ncm-color :panel3)
                  :on-commit on-seek))
    (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim) :flex-shrink 0
      (text (expr (etaf-ncm--format-seconds (etaf-ncm--active-value duration))))))))

(etaf-define-component etaf-ncm--view-player-tools
    (&key quality lyrics volume compact on-lyrics on-queue on-volume)
  "Render the reported quality, pane controls and a draggable volume range.
Controls sit in separated groups so the right edge reads as three ideas
(quality badge, pane switches, volume) instead of one crowded line."
  :bindings ((muted (etaf-computed
                    (lambda () (zerop (or (etaf-ncm--active-value volume) 0))))))
  :view
  (flex :height '(lh 1) :align-items 'center :flex-shrink 0
        :justify-content 'end :gap (if compact '((lh 0) (ch 0.5)) '((lh 0) (ch 1)))
    (box :if (not compact) :id "ncm-quality" :ref 'ncm-quality :height '(lh 1)
         :visibility (if (etaf-ncm--active-value quality) 'visible 'hidden)
         :flex-shrink 0 :width '(ch 10) :overflow 'hidden
         :help-echo (lambda (&rest _) (etaf-ncm--active-value quality))
         :color (etaf-ncm-color :muted)
      (text (expr (let ((label (etaf-ncm--active-value quality))) (if label (format "[%s]" label) "")))))
    (box :if (not compact) :width '(ch 1) :height '(lh 1) (text " "))
    (etaf-ncm--view-control :ref 'ncm-lyrics :icons '(lyrics . lyrics) :value lyrics
                            :help "显示歌词 (l)" :on-press on-lyrics)
    (etaf-ncm--view-control :ref 'ncm-queue-aside :icon 'queue :help "显示播放列表" :on-press on-queue)
    (box :width '(ch 1) :height '(lh 1) (text " "))
    (etaf-ui-toggle-icon :value muted :off 'volume :on 'volume-mute
                         :set 'svg :size 0.9 :color (etaf-ncm-color :muted) :min-width 2)
    (flex :flex-direction 'row :width (if compact '(ch 8) '(ch 12)) :height '(lh 1)
          :flex-shrink 0
      (etaf-range :value (or volume 0) :min 0 :max 100 :ref 'ncm-volume
                  :fill-ref 'ncm-volume-fill
                  :aria-label "音量，点击或拖动调节"
                  :color (etaf-ncm-color :accent)
                  :track-color (etaf-ncm-color :panel3)
                  :on-commit on-volume))
    (box :width '(ch 4) :height '(lh 1) :text-align 'right
         :color (etaf-ncm-color :dim)
      (text (expr (format "%d%%" (or (etaf-ncm--active-value volume) 0)))))))

(etaf-define-component etaf-ncm--view-player
    (&key title artist vip quality playing elapsed duration volume shuffle repeat lyrics message
          queue-count compact liked cover on-toggle on-next on-previous on-stop on-like on-add
          on-volume on-seek on-shuffle on-repeat
          on-lyrics on-queue)
  "Render a native-style three-column bar, or three compact rows.
The bar is an absolutely positioned panel: the app reserves its six lines with
a positioned host, while the panel itself stays a retained publication address
so its controls update without rebuilding the view.  The bar box is
border-box: one border row, three content rows and one padding row above and
below. Compact bars omit the top padding and reserve five lines, meeting
the one-line pane tabs directly."
  :view
  (box :position 'absolute :left '(px 0) :top '(lh 0)
       :width '(% 100) :height '(% 100) :z-index 1
       :padding (if compact '((lh 0) (ch 2) (lh 1) (ch 2))
                  '((lh 1) (ch 2)))
       :background-color (etaf-ncm-color :panel)
       :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (grid :if (not compact) :width 'stretch :height '(lh 3)
          :grid-template-columns '((fr 1) (fr 1) (fr 1)) :gap '((lh 0) (ch 2))
      (etaf-ncm--view-track :title title :artist artist :vip vip :queue-count queue-count
                            :message message :shuffle shuffle :liked liked :cover cover
                            :on-lyrics on-lyrics :on-add on-add
                            :on-like on-like :on-shuffle on-shuffle :on-stop on-stop :on-queue on-queue)
      (flex :flex-direction 'column :width 'stretch :height '(lh 3)
        (etaf-ncm--view-transport :playing playing :repeat repeat :on-like on-like
                                :on-previous on-previous :on-toggle on-toggle :on-next on-next :on-repeat on-repeat)
        (etaf-ncm--view-progress :elapsed elapsed :duration duration
                               :on-seek on-seek))
      (flex :width 'stretch :height '(lh 3) :align-items 'center
        (etaf-ncm--view-player-tools :quality quality :lyrics lyrics :volume volume
                                   :on-lyrics on-lyrics :on-queue on-queue
                                   :on-volume on-volume)))
    (flex :if compact :width 'stretch :height '(lh 3) :flex-direction 'column
      (etaf-ncm--view-track :title title :artist artist :vip vip :queue-count queue-count
                            :compact t :shuffle shuffle :liked liked :cover cover
                            :on-add on-add :on-like on-like
                            :on-shuffle on-shuffle :on-stop on-stop :on-queue on-queue)
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
        (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
          (etaf-ncm--view-transport :playing playing :repeat repeat :compact t :on-like on-like
                                  :on-previous on-previous :on-toggle on-toggle :on-next on-next :on-repeat on-repeat))
        (flex :width '(ch 24) :height '(lh 1) :flex-shrink 0 :flex-direction 'row
          (etaf-ncm--view-player-tools :lyrics lyrics :volume volume :compact t
                                     :on-lyrics on-lyrics :on-queue on-queue
                                     :on-volume on-volume)))
      (etaf-ncm--view-progress :elapsed elapsed :duration duration
                             :on-seek on-seek))))

(provide 'etaf-ncm-views)
;;; etaf-ncm-views.el ends here
