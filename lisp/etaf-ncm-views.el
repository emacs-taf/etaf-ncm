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

(defconst etaf-ncm--sidebar-width (list 'ch etaf-ncm-layout-sidebar-columns)
  "Width of the library sidebar.")

(defconst etaf-ncm--rail-width (list 'ch etaf-ncm-layout-rail-columns)
  "Width of the glyph-only library rail of a compact layout.")

(defconst etaf-ncm--aside-width (list 'ch etaf-ncm-layout-aside-columns)
  "Width of the lyrics and queue panel.")

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

(etaf-define-component etaf-ncm--view-nav-item
    (&key icon label section entry-key badge on-press chip compact width tight help)
  "Render one library entry, retaining its active paint across navigation.
CHIP renders the glyph-only strip entry of the narrow layout, COMPACT the icon
rail of the medium one.  WIDTH is the chip width in columns.  TIGHT drops the
spacer line so a height-constrained sidebar shows every entry."
  :bindings ((active (etaf-computed (lambda () (eq (etaf-value section) entry-key)))))
  :view
  (flex :width (if chip (list 'ch (or width 5)) 'stretch)
        :height (if (or chip tight) '(lh 1) '(lh 2)) :flex-direction 'column
        :role 'button :tab-index 0
        :aria-current (etaf-value active)
        :aria-label (or help label "音乐库")
        :help-echo (or help label "音乐库")
        :on-press on-press
    ;; A callbackless button here would block the cell's inherited keymap.
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
          :justify-content (if (or chip compact) 'center 'start)
          :padding (cond ((and chip width (= width 5)) '((lh 0) (ch 1)))
                         (chip '((lh 0) (ch 0)))
                         (compact '((lh 0) (ch 0)))
                         (t '((lh 0) (ch 2))))
          :hover-style (unless (etaf-value active) (etaf-ncm--hover-surface))
          :background-color (if (etaf-value active) (etaf-ncm-color :accent-soft)
                              (etaf-ncm-color :panel))
          :color (if (etaf-value active) (etaf-ncm-color :ink) (etaf-ncm-color :muted))
          :font-weight 'normal
      (etaf-ui-toggle-icon :value active :off (or icon 'music) :on (or icon 'music)
                           :set 'svg :size 1.0 :min-width 3
                           :color (etaf-ncm-color :muted)
                           :on-color (etaf-ncm-color :accent))
      (box :if (and (not chip) (not compact)) :flex-grow 1 :flex-basis '(px 0)
           :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'normal
        (text (expr (or label ""))))
      (box :if (and (not chip) (not compact) badge) :width '(ch 5) :height '(lh 1)
           :text-align 'right
           :font-weight 'normal :color (etaf-ncm-color :dim)
        (text (expr badge))))
    (box :if (not (or chip compact tight)) :height '(lh 1))))

(etaf-define-component etaf-ncm--view-row
    (&key offset row playing selection variant press on-action)
  "Render library ROW number INDEX with content-driven text only.
The selection and playing highlight live on the list's overlay bars, so this
row has no paint bindings to repaint a whole plane.  ROW and PLAYING may be
retained reactive sources; the row reads them inside its Host text bindings,
so a list reply updates prepared values instead of rebuilding the row.
VARIANT selects the columns the layout can afford (see
`etaf-ncm-layout-row-variant'): the name never leaves, `compact' folds the
artist into the name cell, `tiny' drops the badge as well.  PRESS is called
with INDEX when the row is clicked, and ON-ACTION with INDEX plus the action
key (`download' or `queue') of the inline action the reader pressed."
  :bindings ((play-glyph (car (etaf-ui-icon-lines 'play :set 'svg :size 1.0
                                                  :color (etaf-ncm-color :accent))))
             (downloaded (etaf-computed
                          (lambda () (plist-get (etaf-ncm--reactive-text row) :downloaded))))
             (index (etaf-computed
                     (lambda () (or (plist-get (etaf-ncm--reactive-text row) :display-index) 0)))))
  :view
  ;; The list container is the keyboard stop; a row stays a click target.
  (grid :z-index 0
        :width 'stretch :height '(lh 1) :role 'option
        :visibility (if (etaf-ncm--reactive-text row) 'visible 'hidden)
        :grid-template-columns (etaf-ncm-layout-row-columns variant)
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        ;; The selection and playing highlight are painted by the list's two
        ;; overlay bars.  The row keeps only content-driven changes, so a
        ;; marker move does not repaint the whole list plane.
        :color (etaf-ncm-color :ink)
        ;; The playing bar behind the row is its own surface, so hover must not
        ;; repaint it; the read stays inside this host binding.
        :hover-style (unless (etaf-ncm--active-value playing)
                       (etaf-ncm--hover-surface))
        :help-echo "播放这一行"
        :on-press (lambda () (when (etaf-ncm--reactive-text row)
                               (funcall press (etaf-ncm--active-value index))))
    (box :width (if (eq variant 'tiny) '(ch 2) '(ch 3)) :height '(lh 1)
         :justify-self 'end
         :color (etaf-ncm-color :dim)
      ;; Both states belong to the same retained text Host. A hidden absolute
      ;; overlay has no initial composition target and poisons the fast cohort.
      (text (expr (let ((active (etaf-ncm--active-value playing))
                        (number (etaf-ncm--active-value index)))
                    (if active play-glyph (format "%2s" number))))))
    (box :height '(lh 1) :overflow 'hidden
      ;; A compact row folds the artist into the name cell instead of
      ;; squeezing the name away: the library row must stay identifiable.
      (text (expr (let* ((data (etaf-ncm--reactive-text row))
                         (title (or (and data (plist-get data :name)) ""))
                         (artist (or (and data (plist-get data :subtitle)) "")))
                    (if (and (memq variant '(compact tiny))
                             (not (string-empty-p artist)))
                        (concat title
                                (propertize (format " · %s" artist)
                                            'face (list :foreground (etaf-ncm-color :dim))))
                      title)))))
    (box :if (memq variant '(full regular)) :height '(lh 1) :overflow 'hidden
         :font-weight 'normal
         :color (etaf-ncm-color :muted)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :subtitle) ""))))
    (box :if (eq variant 'full) :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get (etaf-ncm--reactive-text row) :meta) ""))))
    (box :if (not (eq variant 'tiny)) :height '(lh 1) :justify-self 'end :font-weight 'normal
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
                           :tab-index -1
                           :on-press (lambda () (when (etaf-ncm--reactive-text row)
                                                  (funcall on-action (etaf-ncm--active-value index) 'download)))))
    (box :if (eq variant 'full) :height '(lh 1) :justify-self 'center :min-width '(ch 2)
      (etaf-ui-icon :name 'plus :set 'svg :size 1.0 :min-width 3
                    :color (etaf-ncm-color :dim)
                    :help-echo "加入队列" :tab-index -1
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

(etaf-define-component etaf-ncm--view-cover
    (&key size glyph height file (chars 10) (lines 7))
  "Render FILE's album art, or a square placeholder of SIZE characters.
FILE is a reactive source or a literal path; CHARS and LINES bound the area
the art may use.  A usable raster sizes the cover box exactly, so the art
fills it without an empty band above or below.  Without art the box keeps the
standard square cover shape (HEIGHT overrides it), so a cover that is still
downloading does not change the panel height when it arrives."
  :render
  (let* ((value (and file (if (or (etaf-ref-p file) (etaf-computed-p file))
                              (etaf-value file)
                            file)))
         (grid (and (stringp value) (file-readable-p value)
                    (etaf-ncm--cover-grid value chars lines)))
         (square-rows (max 1 (round (/ (* chars (frame-char-width))
                                       (max 1 (frame-char-height))))))
         (box-width (if grid (list 'ch (car grid)) size))
         (box-height (cond (grid (list 'lh (cdr grid)))
                           (height height)
                           (t (list 'lh square-rows)))))
    (etaf-view
     (flex :flex-direction 'column :width box-width :height box-height
           :bgcolor (etaf-ncm-color :panel3)
           :align-items 'center :justify-content 'center
       (image :if grid :key value :src value :columns (car grid) :rows (cdr grid))
       (etaf-ui-icon :if (and (not grid) (not glyph)) :name 'music :set 'svg
                     :size 1.0 :min-width 2 :color (etaf-ncm-color :accent))
       (text :if (and (not grid) glyph) :height '(lh 1) :text-align 'center
             (expr glyph))))))

(etaf-define-component etaf-ncm--view-sidebar
    (&key model groups compact height on-locate on-login)
  "Render the library sidebar with MODEL's current SECTION highlighted.
COMPACT renders the glyph-only rail a medium layout has room for.  A HEIGHT
that cannot hold the two-line entries switches the sidebar to a tight
one-line-per-entry form, so every library stays visible in short frames.
The account row is a status line, not a coloured square: the account icon
and the nickname carry the login state, and pressing the row starts the
sign-in when there is no account.  The component reads the session sources
itself, so a library switch repaints the sidebar instead of the whole
application."
  :render
  (let* ((section (etaf-ncm--ref model :section))
         (account (etaf-ncm--read model :account))
         (nick (and account (or (plist-get account :nick) "已登录")))
         (vip (and account (etaf-ncm--truthy-string-p (plist-get account :vip))))
         (rows (and (eq (car-safe height) 'lh) (numberp (cadr height)) (cadr height)))
         (entries (apply #'append (mapcar #'cdr groups)))
         (tight (and rows
                     (< rows (+ 2 (* 2 (length entries))
                                (* 3 (1- (length groups))))))))
    (etaf-view
  (flex :position 'absolute :left '(px 0) :top '(lh 0)
        :flex-direction 'column :focus-group 'vertical
        :width (if compact etaf-ncm--rail-width etaf-ncm--sidebar-width)
        :height height
        :padding '((lh 1) (ch 1)) :gap '((lh 0) (ch 0))
        :background-color (etaf-ncm-color :panel)
        :border-right (etaf-ncm--view-border 'right (etaf-ncm-color :line))
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
          :justify-content (if compact 'center 'start)
          :padding (if compact '((lh 0) (ch 0)) '((lh 0) (ch 1)))
      (etaf-ui-icon :name 'music :set 'svg :size 1.0 :min-width 3
                    :color (etaf-ncm-color :accent))
      (box :if (not compact) :height '(lh 1)
        (text :font-weight 'bold "网易云音乐")))
    (column :for (group groups) :key (car group) :width 'stretch :item-gap '(lh 0)
      ;; A group reads as a section: a blank line, a small bold label, one more
      ;; blank line and then its entries, so the label cannot be mistaken for
      ;; the first entry.
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1))
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1)
           :padding '((lh 0) (ch 2)) :font-size etaf-ncm-font-meta :font-weight 'bold
           :color (etaf-ncm-color :muted)
        (text (expr (format "%s" (car group)))))
      (box :if (and (not compact) (not tight) (not (eq group (car groups)))) :height '(lh 1))
      (etaf-ncm--view-nav-item :for (entry (cdr group)) :key (car entry)
        :icon (nth 2 entry)
        :label (if compact "" (nth 1 entry)) :help (nth 1 entry)
        :compact compact :tight tight
        :section section :entry-key (car entry)
        :on-press (lambda () (funcall on-locate (car entry)))))
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (flex :width 'stretch :height '(lh 3) :gap '((lh 0) (ch 1)) :align-items 'center
          :padding '((lh 1) (ch 1))
          :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
          :role (and (not account) 'button) :tab-index (and (not account) 0)
          :aria-label "短信登录"
          :help-echo (if account
                          (format "%s%s" nick (if vip " · VIP" ""))
                        "未登录：按 L 登录")
          :on-press (unless account on-login)
      (etaf-ui-icon :name 'account :set 'svg :size 1.0 :min-width 3
                    :color (if account (etaf-ncm-color :ok) (etaf-ncm-color :dim)))
      (box :if (not compact) :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
           :height '(lh 1) :overflow 'hidden
        (text (expr (if account (or nick "已登录") "未登录"))))
      (box :if (and (not compact) account vip) :height '(lh 1) :flex-shrink 0
           :font-weight 'bold :color (etaf-ncm-color :gold)
        (text "VIP"))
      (box :if (and (not compact) (not account)) :height '(lh 1) :flex-shrink 0
           :font-size etaf-ncm-font-meta :color (etaf-ncm-color :dim)
        (text "L 登录")))))))

(etaf-define-component etaf-ncm--view-chips
    (&key model groups columns on-locate)
  "Render the libraries as a strip of glyph chips, as a narrow layout does.
The strip replaces the sidebar: every library stays one press away while the
header keeps showing the current library's name.  COLUMNS is the window
width; the chip size shrinks with it so the strip keeps every library.  The
component reads the session source itself, so a library switch repaints the
chips only."
  :render
  (let* ((section (etaf-ncm--ref model :section))
         (entries (apply #'append (mapcar #'cdr groups)))
         (plan (etaf-ncm-layout-chips columns (length entries)))
         (width (car plan))
         (gap (cdr plan)))
    (etaf-view
     (flex :position 'absolute :z-index 0 :left '(ch 1) :top '(lh 3)
           :width (list 'ch (etaf-ncm-layout-list-columns 'narrow columns))
           :height '(lh 2) :gap (list (list 'lh 0) (list 'ch gap))
           :align-items 'center :overflow 'hidden :focus-group 'horizontal
       (etaf-ncm--view-nav-item :for (entry entries) :key (car entry)
         :chip t :width width :icon (nth 2 entry) :label (nth 1 entry)
         :section section :entry-key (car entry)
         :on-press (lambda () (funcall on-locate (car entry))))))))

(etaf-define-component etaf-ncm--view-header-action
    (&key label primary hidden on-press help)
  "Render one header action with the shared button component.
The button sizes itself from its label, and the wrapper refuses to shrink,
so a cramped row moves the search field instead of clipping the word."
  :view
  (box :flex-shrink 0 :visibility (if hidden 'hidden 'visible)
    (etaf-button :label label
                 :variant (if primary 'primary 'ghost)
                 :pointer (if primary 'hand nil)
                 :help-echo help :on-press on-press)))

(etaf-define-component etaf-ncm--view-header
    (&key model layout columns short on-search on-play-library on-refresh)
  "Render the content header for MODEL's current library.
LAYOUT is the window's tier; a compact one stacks the search field under the
title.  The subtitle only appears when COLUMNS can hold it, and SHORT frames
drop it.  Every width comes from `etaf-ncm-layout': the search field shrinks
toward its minimum while the actions keep their intrinsic width, so a pressed
button can never be clipped into a shorter word.  The component reads the
session sources itself, so a title or loading change repaints the header
instead of the whole application."
  :bindings ((playable (etaf-ncm--ref model :playable)))
  :render
  (let* ((compact (not (eq layout 'wide)))
         (title (etaf-ncm--ref model :title))
         (subtitle (etaf-ncm--ref model :subtitle))
         (query (etaf-ncm--read model :query))
         (title-min (list 'ch etaf-ncm-layout-title-min-columns))
         (search-min (list 'ch etaf-ncm-layout-search-min-columns))
         (search-width (list 'ch etaf-ncm-layout-search-columns))
         (show-subtitle (and (not short)
                             (etaf-ncm-layout-subtitle-p layout columns))))
    (etaf-view
  (column :position 'absolute :z-index 0
          :left (list 'ch (if compact 1 2)) :top '(lh 0)
          :width (list 'ch (etaf-ncm-layout-list-columns layout columns))
          :height (if compact '(lh 3) '(lh 2)) :item-gap '(lh 0)
    (flex :if compact :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
      (box :flex-grow 1 :flex-shrink 1 :flex-basis '(px 0) :min-width title-min
           :height '(lh 1) :overflow 'hidden :font-weight 'bold
        (text (expr (or (etaf-value title) ""))))
      (box :if show-subtitle :height '(lh 1) :overflow 'hidden :flex-shrink 0
           :color (etaf-ncm-color :muted) :font-size etaf-ncm-font-meta
        (text (expr (or (etaf-value subtitle) ""))))
      (etaf-ncm--view-header-action
       :label "换一批" :help-echo "换一批" :on-press on-refresh))
    (flex :if compact :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
      (flex :flex-grow 1 :flex-shrink 1 :flex-basis '(px 0) :min-width search-min
            :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (etaf-ncm--view-header-action
       :primary t :label "播放全部" :help-echo "播放整个列表"
       :hidden (not (etaf-value playable)) :on-press on-play-library))
    (column :if (not compact) :width 'stretch :height '(lh 2) :item-gap '(lh 0)
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
            :align-items 'center
        (box :height '(lh 1) :flex-shrink 1 :min-width title-min :overflow 'hidden
             :font-weight 'bold
          (text (expr (or (etaf-value title) ""))))
        ;; The subtitle follows the title on the same row, one gap column
        ;; apart; the row below stays clear so the header keeps its air.
        (box :if show-subtitle :height '(lh 1) :flex-shrink 0 :overflow 'hidden
             :color (etaf-ncm-color :muted) :font-size etaf-ncm-font-meta
          (text (expr (or (etaf-value subtitle) ""))))
        (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 1))
        (box :width search-width :height '(lh 1) :flex-shrink 1 :min-width search-min
          (etaf-text-input :value query :label "搜索"
                           :placeholder "搜索歌曲、歌手、歌单或专辑"
                           :hide-label t :on-change on-search))
        (etaf-ncm--view-header-action
         :primary t :label "播放全部" :help-echo "播放整个列表"
         :hidden (not (etaf-value playable)) :on-press on-play-library)
        (etaf-ncm--view-header-action
         :label "换一批" :help-echo "换一批" :on-press on-refresh))
      (box :flex-grow 1 :flex-basis '(lh 0)))))))

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
    (flex :focus-group 'horizontal :height '(lh 1) :gap '((lh 0) (ch 1))
          :flex-shrink 0 :align-items 'center
    (flex :for (tab (list (list 'list "列表")
                          (list 'lyrics "歌词")
                          (list 'queue "队列"))) :key (car tab)
      :width '(ch 8) :height '(lh 1) :flex-grow 0 :flex-shrink 0
      :justify-content 'center :align-items 'center
      :padding '((lh 0) (ch 1)) :role 'tab :tab-index 0
      :aria-selected (etaf-value (etaf-ncm--pane-tab-source
                                  (car tab) pane-list lyrics queue))
      :hover-style (unless (etaf-value (etaf-ncm--pane-tab-source
                                        (car tab) pane-list lyrics queue))
                     (etaf-ncm--hover-surface))
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
        (text (expr (nth 1 tab))))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
         :height '(lh 1) :text-align 'right :color (etaf-ncm-color :dim)
         :font-size etaf-ncm-font-meta :overflow 'hidden
      (text (expr (let ((list-p (etaf-value pane-list))
                        (lyrics-p (etaf-value lyrics))
                        (queue-p (etaf-value queue)))
                    (cond (list-p "↑↓ 选择 · Tab 切换")
                          (queue-p "l 切换面板")
                          (lyrics-p "i 歌词/队列")
                          (t "l 切换面板"))))))))

(etaf-define-component etaf-ncm--view-list
    (&key model compact selection keys direction on-focus on-press on-action)
  "Render MODEL's visible rows through retained row slots and a page footer.
Each visible row keeps its slot identity across library switches, so a reply
updates prepared row text instead of rebuilding the list.  The selection and
playing highlight are two absolute overlay bars whose `:top' is the only
thing that moves; rows stay transparent and content-driven, so moving the
highlight never repaints the whole plane.  The page fills every row the
window budget leaves after the header, the tabs and the player bar, and the
wheel scrolls the window through the loaded rows, so a long library is fully
reachable.  SELECTION is the player's reactive selection source; ON-PRESS is
called with a row's page index when that row is clicked, and ON-ACTION with
that index plus an inline action key.  The list is one keyboard stop: KEYS
are its `:keys', and ON-FOCUS runs when focus enters it."
  :render
  (let* ((slots (plist-get model :row-slots))
         (playing (plist-get model :row-playing))
         (visible (etaf-ncm--ref model :visible-count))
         (count (min (etaf-ncm--read model :page-size) (length slots)))
         (offsets (and (> count 0) (number-sequence 0 (1- count))))
         (page-label (etaf-ncm--ref model :page-label))
         (loaded-label (etaf-ncm--ref model :loaded-label))
         (footer-visible (etaf-ncm--ref model :footer-visible))
         (more-visible (etaf-ncm--ref model :more-visible))
         (empty-note (etaf-ncm--ref model :empty-note))
         (layout (etaf-ncm--read model :layout))
         (columns (or (etaf-ncm--read model :columns) 0))
         (window-rows (etaf-ncm--read model :window-rows))
         (variant (etaf-ncm-layout-row-variant layout columns))
         (short (etaf-ncm-layout-short-p window-rows))
         ;; The view lives in the list panel, whose content box starts one
         ;; row below the window top; the layout budget counts from the
         ;; window, hence the conversion.
         (top (1- (etaf-ncm-layout-list-top layout)))
         (footer-rows (etaf-ncm-layout-footer-rows-for window-rows))
         (hint (cond ((and (not compact) (not short)) "↑↓ 选择 · RET 播放 · a 入队 · d 下载 · / 搜索 · i 歌词 · Tab 切换区域 · ? 帮助")
                     ((and (<= 44 columns) (not short)) "↑↓ 选择 · Tab 切换 · ? 命令")
                     (t nil)))
         (height (if (and window-rows (> window-rows 0))
                     ;; The panel inset converts the window-level budget into
                     ;; this view's coordinate: page rows plus the footer
                     ;; reach exactly the bar, so the footer cannot slide
                     ;; under it.
                     (max 1 (- window-rows (1+ top)
                               (etaf-ncm-layout-tabs-rows layout)
                               etaf-ncm-layout-bar-rows))
                   (+ count footer-rows))))
    (etaf-view
     (flex :position 'absolute :z-index 0
           :left (list 'ch (if (eq layout 'wide) 2 1))
           :top (list 'lh top)
           :flex-direction 'column
           :width (list 'ch (etaf-ncm-layout-list-columns layout columns))
           :height (list 'lh height)
           :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
           :ref 'ncm-list :role 'listbox :aria-label "歌曲列表" :tab-index 0
           :keys keys :on-direction direction :on-focus-enter on-focus
       (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
            :width 'stretch :height '(lh 6)
            :visibility (if (zerop (etaf-value visible)) 'visible 'hidden)
         (etaf-ncm--view-note :text empty-note))
       (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
            :width 'stretch :height (list 'lh count) :overflow 'hidden
         ;; Two static bars behind the rows: selection first, playing on top.
         ;; The app moves them through retained host geometry (`:top' is
         ;; their only change), so a highlight move never repaints the plane.
         (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh -1)
              :width 'stretch :height '(lh 1)
              :ref 'ncm-list-selection :id "ncm-list-selection"
              :background-color (etaf-ncm-color :panel2))
         (box :position 'absolute :z-index 0 :left '(ch 0) :top '(lh -1)
              :width 'stretch :height '(lh 1)
              :ref 'ncm-list-playing :id "ncm-list-playing"
              :background-color (etaf-ncm-color :accent-soft))
         (column :position 'relative :z-index 1 :left '(ch 0) :top '(lh 0)
                 :width 'stretch :item-gap '(lh 0)
           (etaf-ncm--view-row :for (offset offsets) :key offset
             :offset offset
             :row (aref slots offset)
             :playing (aref playing offset)
             :selection selection
             :variant variant
             :press on-press
             :on-action on-action)))
       (flex :position 'absolute :z-index 0 :left '(ch 0)
             :top (list 'lh (max 0 (- height footer-rows)))
             :flex-direction 'column
             :width 'stretch :height (list 'lh footer-rows)
             :flex-shrink 0 :gap '((lh 0) (px 0))
             :color (etaf-ncm-color :dim) :font-size etaf-ncm-font-meta
         (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
           (box :height '(lh 1) :flex-shrink 0
             ;; The row stays painted and each label reads its own sources
             ;; inside its Host binding: gating the whole row on a
             ;; component-level read left it invisible until some unrelated
             ;; write happened to re-render the list.
             (text (expr (if (etaf-value footer-visible)
                             (or (etaf-ncm--reactive-text page-label) "")
                           ""))))
           (box :if hint :height '(lh 1) :overflow 'hidden
                :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
             (text (expr (or hint "")))))
         (box :if (not short) :height '(lh 1)
           (text (expr (if (and (etaf-value footer-visible)
                                (etaf-value more-visible))
                           (or (etaf-ncm--reactive-text loaded-label) "")
                         "")))))))))

(defun etaf-ncm--notice-lines (text layout columns)
  "Return how many wrapped lines TEXT needs in the library panel.
LAYOUT and COLUMNS come from the session; the result is between one and four
lines, so a long failure stays fully readable without covering the library."
  (let ((width (max 8 (etaf-ncm-layout-list-columns layout columns))))
    (max 1 (min 4 (/ (+ (string-width (or text "")) width -1) width)))))

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
  (let* ((columns (or columns 0))
         (wide-p (eq layout 'wide))
         (rows (or window-rows 0))
         (height (and (> rows 0)
                      (max 1 (- rows etaf-ncm-layout-bar-rows
                               (etaf-ncm-layout-tabs-rows layout)))))
         (left (cond (wide-p etaf-ncm-layout-sidebar-columns)
                     ((eq layout 'medium) etaf-ncm-layout-rail-columns)
                     (t 0)))
         (width (+ (etaf-ncm-layout-list-columns layout columns)
                   (if wide-p 4 2))))
    (etaf-view
     (box :position 'absolute :left (list 'ch left) :top '(lh 0)
          :width (list 'ch width) :height (if height (list 'lh height) '(% 100)) :z-index 0
          :visibility (if (etaf-value visible) 'visible 'hidden)
       (flex :position 'absolute :z-index 0 :left '(ch 0) :top '(lh 0)
             :flex-direction 'column
             :width (list 'ch (+ (etaf-ncm-layout-list-columns layout columns)
                                 (if wide-p 4 2)))
             :height 'stretch
             :min-width '(ch 0) :min-height '(lh 0)
             :padding '((lh 1) (ch 0) (lh 0) (ch 0))
             :gap '((lh 1) (px 0))
         (expr (etaf-current-slot 'default)))))))

;;; ---------------------------------------------------------------------------
;;; Lyrics, queue and player
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-tabs (&key kind on-switch)
  "Render the lyrics/queue switch with KIND active.
The active tab is a tinted pill, not an underline: the two tabs keep their
width, so switching cannot shift the row, and the state reads from the
typography and the surface together.  Each aside variant draws its own
static tab row."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
        :align-items 'center :focus-group 'horizontal
        :border-bottom (etaf-ncm--view-border 'bottom (etaf-ncm-color :line))
    (box :height '(lh 1) :padding '((lh 0) (ch 2)) :role 'tab :tab-index 0
         :aria-selected (eq kind 'lyrics)
         :hover-style (unless (eq kind 'lyrics) (etaf-ncm--hover-surface))
         :help-echo "看歌词"
         :font-weight (if (eq kind 'lyrics) 'bold 'normal)
         :background-color (if (eq kind 'lyrics) (etaf-ncm-color :accent-soft)
                             (etaf-ncm-color :panel))
         :color (if (eq kind 'lyrics) (etaf-ncm-color :accent)
                  (etaf-ncm-color :muted))
         :on-press (lambda () (funcall on-switch 'lyrics))
      (text "歌词"))
    (box :height '(lh 1) :padding '((lh 0) (ch 2)) :role 'tab :tab-index 0
         :aria-selected (eq kind 'queue)
         :hover-style (unless (eq kind 'queue) (etaf-ncm--hover-surface))
         :help-echo "看播放队列"
         :font-weight (if (eq kind 'queue) 'bold 'normal)
         :background-color (if (eq kind 'queue) (etaf-ncm-color :accent-soft)
                             (etaf-ncm-color :panel))
         :color (if (eq kind 'queue) (etaf-ncm-color :accent)
                  (etaf-ncm-color :muted))
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
             :font-size etaf-ncm-font-meta
          (text (expr (or (etaf-ncm--reactive-text album) ""))))))
    (box :height '(lh 1))
    (flex :flex-direction 'column :width 'stretch :flex-grow 1
          :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
      (etaf-ncm--view-lyric-cell :for (index offsets) :key index :projection projection :index index))
    (box :width 'stretch :height '(lh 1) :color (etaf-ncm-color :dim)
         :font-size etaf-ncm-font-meta :text-align 'center
      (text (expr (let ((data (etaf-value projection)))
                    (if (plist-get data :lines)
                        (format "%s / %s" (or (plist-get data :position) 0) (or (plist-get data :total) 0)) "")))))))))

(etaf-define-component etaf-ncm--view-queue-cell (&key projection index on-jump)
  "Render one retained queue slot, resolving its current identity on activation."
  :bindings ((entry (etaf-computed (lambda () (nth index (plist-get (etaf-value projection) :entries))) :test #'equal))
             (glyph (car (etaf-ui-icon-lines 'play :set 'svg :color (etaf-ncm-color :accent)))))
  :view
  (flex :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :ref (intern (format "ncm-queue-cell-%d" index))
        :aria-current (plist-get (etaf-value entry) :current)
        :aria-label (let ((row (etaf-value entry)))
                      (if row (format "队列 %s：%s" (plist-get row :index) (plist-get row :name)) "队列"))
        :visibility (if (etaf-value entry) 'visible 'hidden)
        :help-echo (lambda (&rest _)
                     (let ((row (etaf-value entry)))
                       (when row (format "播放队列第 %s 首：%s" (plist-get row :index) (plist-get row :name)))))
        :hover-style (unless (plist-get (etaf-value entry) :current)
                       (etaf-ncm--hover-surface))
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

(etaf-define-component etaf-ncm--view-queue (&key projection rows keys direction on-jump)
  "Render a viewport-sized queue pool without replacing rows on every scroll.
The cells form one vertical focus group entered at the playing entry; KEYS
are the group's `:keys' and DIRECTION moves its selection and scrolls past
the pool's first and last cell."
  :render
  (let ((offsets (and (> rows 0) (number-sequence 0 (1- rows)))))
   (etaf-view
  (flex :position 'relative :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
        :ref 'ncm-queue :focus-group 'vertical :keys keys :on-direction direction
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
    (&key kind visible layout columns window-rows title artist album cover
          projection rows queue-keys queue-direction on-switch on-jump)
  "Render one absolute aside variant: KIND is `lyrics' or `queue'.
Both variants are panels of the root stage; VISIBLE is the reactive source
that reveals this one, so switching panels publishes retained visibility
updates instead of rebuilding the view.  QUEUE-KEYS are the queue's
`:keys'.  LAYOUT and COLUMNS size and place
the panel in the same cells the wheel hit test uses.  The panel ends at the
window bottom; the player bar paints over its last rows, and the row budgets
already stop the content above it."
  :render
  (let* ((columns (or columns 0))
         ;; The panel spans the window; ROWS is the row budget each panel view
         ;; keeps for its own pool, so this local must not shadow that prop.
         (window-height (or window-rows 0))
         (height (and (> window-height 0)
                      (etaf-ncm-layout-aside-rows layout window-height)))
         (left (cond ((eq layout 'wide)
                      (max 0 (- columns etaf-ncm-layout-aside-columns)))
                     ((eq layout 'medium) etaf-ncm-layout-rail-columns)
                     (t 0)))
         (width (cond ((eq layout 'wide) (max 1 etaf-ncm-layout-aside-columns))
                      ((eq layout 'medium) (max 1 (- columns etaf-ncm-layout-rail-columns)))
                      (t (max 1 columns)))))
    (etaf-view
     (box :position 'absolute :left (list 'ch left) :top '(lh 0)
          :width (list 'ch width) :height (if height (list 'lh height) '(% 100)) :z-index 0
          :visibility (if (etaf-value visible) 'visible 'hidden)
          :ref (intern (format "ncm-aside-%s" kind))
          :padding '((lh 1) (ch 2))
          :background-color (etaf-ncm-color :panel)
          :border-left (etaf-ncm--view-border 'left (etaf-ncm-color :line))
       (flex :flex-direction 'column
             :width (list 'ch (max 1 (- width 4))) :height 'stretch
             :min-width '(ch 0) :gap '((lh 0) (px 0))
         (etaf-ncm--view-tabs :kind kind :on-switch on-switch)
         (etaf-ncm--view-lyrics :if (eq kind 'lyrics)
           :title title :artist artist :album album :cover cover
           :projection projection :rows rows)
         (etaf-ncm--view-queue :if (eq kind 'queue)
           :projection projection :rows rows :keys queue-keys :direction queue-direction :on-jump on-jump))))))

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
         :aria-label help
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
            :focus-group 'horizontal
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
        :align-items 'center :justify-content 'center :focus-group 'horizontal
    (etaf-ncm--view-control :ref 'ncm-previous :icon 'previous :help "上一首 (p)" :on-press on-previous)
    (box :id "ncm-play" :ref 'ncm-play :width (if compact '(ch 3) '(ch 4))
         :height '(lh 1) :flex-shrink 0
         :role 'button :tab-index 0 :aria-label "播放 / 暂停"
         :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle
         :background-color (etaf-ncm-color :accent)
      (etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg :size 0.9
                           :color (etaf-ncm-color :ink) :on-color (etaf-ncm-color :ink)
                           ;; Span the whole pill so the glyph centres with one inset on
                           ;; both sides; a narrower icon leaves the right side heavier.
                           :min-width (if compact 3 4)
                           :help-echo "播放 / 暂停 (SPC)" :tab-index -1
                           :on-press on-toggle))
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
                  :ref 'ncm-seek :fill-ref 'ncm-meter :key-step 5
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
    (flex :height '(lh 1) :align-items 'center :flex-shrink 0 :focus-group 'horizontal
          :gap (if compact '((lh 0) (ch 0.5)) '((lh 0) (ch 1)))
      (etaf-ncm--view-control :ref 'ncm-lyrics :icons '(lyrics . lyrics) :value lyrics
                              :help "显示歌词 (i)" :on-press on-lyrics)
      (etaf-ncm--view-control :ref 'ncm-queue-aside :icon 'queue :help "显示播放列表"
                              :on-press on-queue))
    (box :width '(ch 1) :height '(lh 1) (text " "))
    (etaf-ui-toggle-icon :value muted :off 'volume :on 'volume-mute
                         :set 'svg :size 0.9 :color (etaf-ncm-color :muted) :min-width 2)
    (flex :flex-direction 'row :width (if compact '(ch 8) '(ch 12)) :height '(lh 1)
          :flex-shrink 0
      (etaf-range :value (or volume 0) :min 0 :max 100 :ref 'ncm-volume :key-step 5
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
The bar is an absolutely positioned panel: the app reserves its five lines
with a positioned host, while the panel itself stays a retained publication
address so its controls update without rebuilding the view.  The bar box is
exactly those five rows: one padding row above the content, the three
content rows and the closing padding row that keeps the text one row from
the bottom edge, since the hosting window adds no inset of its own.  It
paints no border of its own: a pixel border would push the box off the row
grid and eat the closing line; the pane tab strip above it carries the
separator where one is drawn."
  :view
  (box :position 'absolute :left '(px 0) :top '(lh 0)
       :width '(% 100) :height '(% 100) :z-index 1
       :padding '((lh 1) (ch 2) (lh 1) (ch 2))
       :background-color (etaf-ncm-color :panel)
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
