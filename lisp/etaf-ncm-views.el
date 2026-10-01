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
(require 'etaf-ncm-theme)
(require 'etaf-ncm-model)

;;; ---------------------------------------------------------------------------
;;; Shared geometry
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm--sidebar-width '(ch 24)
  "Width of the library sidebar.")

(defconst etaf-ncm--rail-width '(ch 6)
  "Width of the glyph-only library rail of a compact layout.")

(defconst etaf-ncm--aside-width '(ch 40)
  "Width of the lyrics and queue panel.")

(defconst etaf-ncm--row-columns '((ch 3) (fr 1) (ch 22) (ch 18) (ch 5) (ch 6))
  "Grid columns of one library row: index, title, artist, album, badge, time.")

(defconst etaf-ncm--row-columns-compact '((ch 3) (fr 1) (ch 18) (ch 5) (ch 6))
  "Grid columns of a compact library row: index, title, artist, badge, time.")

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

(etaf-define-component etaf-ncm--view-nav-item (&key icon label active badge on-press)
  "Render one library entry with ICON, LABEL, BADGE and press callback.
The whole two-line cell is the click target, but only the text row is painted,
so a selected entry reads as one highlighted line."
  :view
  (flex :width 'stretch :height '(lh 2) :flex-direction 'column
        :role 'button :tab-index 0
       
        :help-echo (or label "音乐库")
        :on-press on-press
    ;; A callbackless button here would block the cell's inherited keymap.
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center :padding '((lh 0) (ch 2))
          :hover-style (etaf-ncm--hover-surface)
          :background-color (and active (etaf-ncm-color :accent-soft))
          :color (if active (etaf-ncm-color :ink) (etaf-ncm-color :muted))
          :font-weight (if active 'bold 'normal)
          :border-left (and active
                            (etaf-ncm--view-border 'left (etaf-ncm-color :accent)))
      (etaf-ui-icon :name (or icon 'music) :set 'svg :size 1.0 :min-width 3
                    :color (if active (etaf-ncm-color :accent) (etaf-ncm-color :muted)))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight (if active 'bold 'normal)
        (text (expr (or label ""))))
      (box :if badge :width '(ch 5) :height '(lh 1) :text-align 'right
           :font-weight 'normal :color (etaf-ncm-color :dim)
        (text (expr badge))))
    (box :height '(lh 1))))

(etaf-define-component etaf-ncm--view-row
    (&key index row selected playing compact press)
  "Render library ROW number INDEX, marked SELECTED and PLAYING as appropriate.
COMPACT drops the album column, which a narrow frame cannot show.  PRESS is
called with INDEX when the row is clicked; keeping it stable is what lets a row
whose data did not change keep its rendered output."
  :view
  (grid :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :grid-template-columns (if compact etaf-ncm--row-columns-compact
                                 etaf-ncm--row-columns)
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        :background-color (cond (playing (etaf-ncm-color :accent-soft))
                                (selected (etaf-ncm-color :panel2)))
        :color (cond (playing (etaf-ncm-color :accent))
                     (selected (etaf-ncm-color :ink))
                     (t (etaf-ncm-color :ink)))
        :font-weight (if (or playing selected) 'bold 'normal)
       
        :hover-style (etaf-ncm--hover-surface)
        :help-echo (format "播放 %s" (or (plist-get row :name) "这一行"))
        :on-press (lambda () (funcall press index))
    (box :height '(lh 1) :justify-self 'end
         :color (cond (playing (etaf-ncm-color :accent))
                      (selected (etaf-ncm-color :muted))
                      (t (etaf-ncm-color :dim)))
      (text (expr (if playing "▶︎" (format "%2s" index)))))
    (box :height '(lh 1) :overflow 'hidden
      (text (expr (or (plist-get row :name) ""))))
    (box :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-ncm-color :muted)
      (text (expr (or (plist-get row :subtitle) ""))))
    (box :if (not compact) :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get row :meta) ""))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-ncm-color :gold)
      (text (expr (or (plist-get row :badge) ""))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-ncm-color :dim)
      (text (expr (or (plist-get row :right) ""))))))

(etaf-define-component etaf-ncm--view-note (&key text)
  "Render TEXT as a quiet placeholder filling the content area."
  :view
  (box :width 'stretch :height '(lh 6) :text-align 'center
       :color (etaf-ncm-color :dim)
    (text (expr (or text "")))))

(etaf-define-component etaf-ncm--view-cover (&key size glyph (height '(lh 7)))
  "Render a square cover placeholder of SIZE characters."
  :view
  (flex :width size :height height :bgcolor (etaf-ncm-color :panel3)
        :align-items 'center :justify-content 'center
    (box :height '(lh 1) :text-align 'center :font-weight 'bold
         :color (etaf-ncm-color :accent)
      (text (expr (or glyph "♪"))))))

(etaf-define-component etaf-ncm--view-sidebar
    (&key groups section account compact on-locate)
  "Render the library sidebar from GROUPS with SECTION highlighted.
COMPACT renders the glyph-only rail a medium layout has room for."
  :view
  (flex :flex-direction 'column
        :width (if compact etaf-ncm--rail-width etaf-ncm--sidebar-width)
        :height 'stretch
        :padding '((lh 1) (ch 1)) :gap '((lh 0) (ch 0))
        :background-color (etaf-ncm-color :panel)
        :border-right (etaf-ncm--view-border 'right (etaf-ncm-color :line))
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center :padding '((lh 0) (ch 1))
      (text :font-weight 'bold :color (etaf-ncm-color :accent) "♫")
      (box :if (not compact) :height '(lh 1)
        (text :font-weight 'bold "网易云音乐"))
      (box :if (not compact) :height '(lh 1) :color (etaf-ncm-color :dim)
        (text "NCM")))
    (column :for (group groups) :key (car group) :width 'stretch :item-gap '(lh 0)
      ;; A group reads as a section: a blank line, a small bold label, one more
      ;; blank line and then its entries, so the label cannot be mistaken for
      ;; the first entry.
      (box :if (and (not compact) (not (eq group (car groups)))) :height '(lh 1))
      (box :if (and (not compact) (not (eq group (car groups)))) :height '(lh 1)
           :padding '((lh 0) (ch 2)) :font-size 12 :font-weight 'bold
           :color (etaf-ncm-color :muted)
        (text (expr (format "%s" (car group)))))
      (box :if (and (not compact) (not (eq group (car groups)))) :height '(lh 1))
      (etaf-ncm--view-nav-item :for (entry (cdr group)) :key (car entry)
        :icon (nth 2 entry)
        :label (if compact "" (nth 1 entry))
        :active (eq (car entry) section)
        :on-press (lambda () (funcall on-locate (car entry)))))
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
          :padding '((lh 1) (ch 1))
          :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
      (text :color (etaf-ncm-color (if account :ok :danger)) "●")
      (box :if (not compact) :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
           :height '(lh 1)
           :overflow 'hidden :color (etaf-ncm-color :muted)
        (text (expr (if account
                         (format "%s%s" (or (plist-get account :nick) "已登录")
                                 (if (etaf-ncm--truthy-string-p
                                      (plist-get account :vip))
                                     " ·VIP" ""))
                       "未登录")))))))

(etaf-define-component etaf-ncm--view-chips
    (&key groups section on-locate)
  "Render the libraries as a strip of glyph chips, as a narrow layout does.
The strip replaces the sidebar: every library stays one press away while the
header keeps showing the current library's name."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
        :align-items 'center :overflow 'hidden
    (flex :for (entry (apply #'append (mapcar #'cdr groups))) :key (car entry)
      :height '(lh 1) :align-items 'center :padding '((lh 0) (ch 1))
      :role 'button :tab-index 0
     
      :hover-style (etaf-ncm--hover-surface)
      :help-echo (or (nth 1 entry) "音乐库")
      :background-color (and (eq (car entry) section) (etaf-ncm-color :accent-soft))
      :color (if (eq (car entry) section) (etaf-ncm-color :accent) (etaf-ncm-color :dim))
      :on-press (lambda () (funcall on-locate (car entry)))
      (etaf-ui-icon :name (or (nth 2 entry) 'music) :set 'svg :size 1.0 :min-width 3
                    :color (if (eq (car entry) section)
                               (etaf-ncm-color :accent)
                             (etaf-ncm-color :dim))))))

(etaf-define-component etaf-ncm--view-header
    (&key title subtitle query loading compact on-search on-play-all on-refresh)
  "Render the content header for TITLE with its actions.
COMPACT stacks the search field under the title, the shape a narrow frame needs."
  :view
  (column :width 'stretch :height (if compact '(lh 3) '(lh 2)) :item-gap '(lh 0)
    (flex :if compact :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'bold
        (text (expr (or title ""))))
      (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
           :font-size 12
        (text (expr (or subtitle ""))))
      (etaf-button :label (if loading "…" "↻") :variant 'ghost
                   :on-press on-refresh))
    (flex :if compact :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
      (flex :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (etaf-button :if on-play-all :label "▶︎ 播放全部" :variant 'primary :pointer 'hand
                   :help-echo "播放整个列表" :on-press on-play-all))
    (flex :if (not compact) :width 'stretch :height '(lh 2)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 10) :item-gap '(lh 0)
        (text :font-weight 'bold (expr (or title "")))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
             :font-size 12
          (text (expr (or subtitle "")))))
      (box :width '(ch 30) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (etaf-button :if on-play-all :label "▶︎ 播放全部" :variant 'primary :pointer 'hand
                   :help-echo "播放整个列表" :on-press on-play-all)
      (etaf-button :label (if loading "… 加载中" "↻ 换一批") :variant 'ghost
                   :on-press on-refresh))))

(etaf-define-component etaf-ncm--view-pane-tabs (&key pane aside on-pane on-aside)
  "Render the list/lyrics/queue switch a compact layout uses."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :flex-shrink 0 :align-items 'center :padding '((lh 0) (ch 2))
        :background-color (etaf-ncm-color :panel)
        :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (flex :for (tab (list (list 'list "列表")
                          (list 'lyrics "歌词")
                          (list 'queue "队列"))) :key (car tab)
      :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
      :padding '((lh 0) (ch 1)) :role 'button :tab-index 0
     
      :hover-style (etaf-ncm--hover-surface)
      :help-echo (nth 1 tab)
      :background-color (and (or (eq (car tab) pane)
                                 (and (eq pane 'aside) (eq (car tab) aside)))
                             (etaf-ncm-color :accent-soft))
      :color (if (or (eq (car tab) pane)
                     (and (eq pane 'aside) (eq (car tab) aside)))
                 (etaf-ncm-color :accent)
               (etaf-ncm-color :muted))
      :font-weight (if (eq (car tab) pane) 'bold 'normal)
      :on-press (if (eq (car tab) 'list)
                    (lambda () (funcall on-pane 'list))
                  (lambda () (funcall on-aside (car tab))))
      (box :height '(lh 1)
        (text (expr (nth 1 tab)))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
         :height '(lh 1) :text-align 'right :color (etaf-ncm-color :dim)
         :font-size 12 :overflow 'hidden
      (text (expr (if (eq pane 'aside)
                      (if (eq aside 'lyrics) "l 歌词/队列" "l 切换面板")
                    "j/k 或滚轮选择 · 双击播放"))))))

(etaf-define-component etaf-ncm--view-list
    (&key entries start total loaded compact empty-note on-press)
  "Render the visible library ENTRIES and a page footer.
ON-PRESS is called with a row's page index when that row is clicked."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (etaf-ncm--view-note :if (null entries) :text empty-note)
    (etaf-ncm--view-row :for (entry entries) :key (plist-get entry :index)
      :index (plist-get entry :index)
      :row (plist-get entry :row)
      :selected (plist-get entry :selected)
      :playing (plist-get entry :playing)
      :compact compact
      :press on-press)
    (box :if entries :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (flex :if (or entries (> total 0)) :flex-direction 'column
          :width 'stretch :height (if (< loaded total) '(lh 2) '(lh 1))
          :flex-shrink 0 :gap '((lh 0) (px 0))
          :color (etaf-ncm-color :dim) :font-size 12
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
        (box :height '(lh 1) :flex-shrink 0
          (text (expr (format "第 %s-%s 首 / 共 %s 首"
                              (if entries start 0)
                              (if entries (+ start (1- (length entries))) 0)
                              total))))
        (box :if (not compact) :height '(lh 1) :overflow 'hidden
             :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
          (text "j/k 或滚轮选择 · 双击播放 · a 入队 · / 搜索 · l 歌词 · ? 帮助")))
      (box :if (< loaded total) :height '(lh 1)
        (text (expr (format "已加载 %s / 共 %s 首" loaded total)))))))

;;; ---------------------------------------------------------------------------
;;; Lyrics, queue and player
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-tabs (&key aside on-switch)
  "Render the lyrics/queue switch with ASIDE active."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :align-items 'center
        :border-bottom (etaf-ncm--view-border 'bottom (etaf-ncm-color :line))
    (box :height '(lh 2) :padding '((lh 0) (ch 0)) :role 'button :tab-index 0
        
         :hover-style (etaf-ncm--hover-surface)
         :help-echo "看歌词"
         :font-weight (if (eq aside 'lyrics) 'bold 'normal)
         :color (if (eq aside 'lyrics) (etaf-ncm-color :ink)
                  (etaf-ncm-color :muted))
         :border-bottom (and (eq aside 'lyrics)
                             (etaf-ncm--view-border 'bottom
                                                    (etaf-ncm-color :accent)))
         :on-press (lambda () (funcall on-switch 'lyrics))
      (text "歌词"))
    (box :height '(lh 2) :role 'button :tab-index 0
        
         :hover-style (etaf-ncm--hover-surface)
         :help-echo "看播放队列"
         :font-weight (if (eq aside 'queue) 'bold 'normal)
         :color (if (eq aside 'queue) (etaf-ncm-color :ink)
                  (etaf-ncm-color :muted))
         :border-bottom (and (eq aside 'queue)
                             (etaf-ncm--view-border 'bottom
                                                    (etaf-ncm-color :accent)))
         :on-press (lambda () (funcall on-switch 'queue))
      (text "播放队列"))))

(etaf-define-component etaf-ncm--view-lyrics
    (&key title artist album lines trans current position total loading)
  "Render the lyric window LINES around CURRENT seconds.
LINES is the visible slice of the parsed lyric and TRANS its translations."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
      (etaf-ncm--view-cover :size '(ch 10))
      (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text (expr (or title "还没有播放"))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
          (text (expr (or artist ""))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :dim)
             :font-size 12
          (text (expr (or album ""))))))
    (box :height '(lh 1))
    (box :if loading :height '(lh 1) :color (etaf-ncm-color :dim)
      (text "正在取歌词…"))
    (box :if (and (not loading) (zerop (or total 0))) :height '(lh 1)
         :color (etaf-ncm-color :dim)
      (text "这首歌没有歌词"))
    (flex :if lines :flex-direction 'column :width 'stretch :flex-grow 1
          :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
      ;; The key is the line's ordinal, not its timestamp: a real LRC may
      ;; repeat a timestamp and two lines must still keep distinct instances.
      (column :for (line lines) :key (nth 2 line)
              :width 'stretch :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden
             :color (if (equal (car line) current)
                        (etaf-ncm-color :accent)
                      (etaf-ncm-color :muted))
             :font-weight (if (equal (car line) current) 'bold 'normal)
          (text (expr (or (cadr line) " "))))
        (box :if (etaf-ncm--translation-for trans (car line))
             :height '(lh 1) :overflow 'hidden
             :color (etaf-ncm-color :dim) :font-size 12
          (text (expr (or (etaf-ncm--translation-for trans (car line)) ""))))))
    (box :if lines :width 'stretch :height '(lh 1) :color (etaf-ncm-color :dim)
         :font-size 12 :text-align 'center
      (text (expr (format "%s / %s" (or position 0) (or total 0)))))))

(etaf-define-component etaf-ncm--view-queue (&key entries pos count on-jump)
  "Render queue ENTRIES around position POS.
Each entry is (:index :name :right :current) from the player model."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (column :width 'stretch :height '(lh 2) :item-gap '(lh 0)
      (text :font-weight 'bold "播放队列")
      (text :color (etaf-ncm-color :dim)
            (expr (format "第 %s-%s 首 / 共 %s 首"
                          (or (plist-get (car entries) :index) 0)
                          (or (plist-get (car (last entries)) :index) 0)
                          (or count 0)))))
    (box :if (and (null entries) (zerop (or count 0)))
         :height '(lh 1) :color (etaf-ncm-color :dim)
      (text "队列是空的"))
    (flex :for (entry entries) :key (plist-get entry :index)
      :width 'stretch :height '(lh 1) :role 'button :tab-index 0
     
      :help-echo (format "播放队列第 %s 首：%s"
                         (plist-get entry :index) (plist-get entry :name))
      :hover-style (etaf-ncm--hover-surface)
      :gap '((lh 0) (ch 1)) :align-items 'center
      :background-color (and (plist-get entry :current)
                             (etaf-ncm-color :accent-soft))
      :color (if (plist-get entry :current)
                 (etaf-ncm-color :accent)
               (etaf-ncm-color :muted))
      :font-weight (if (plist-get entry :current) 'bold 'normal)
      :on-press (lambda () (funcall on-jump (plist-get entry :index)))
      (box :width (list 'ch (max 3 (1+ (length (number-to-string (or count 0))))))
           :height '(lh 1) :color (etaf-ncm-color :dim)
        (text (expr (if (plist-get entry :current)
                        "▶︎"
                      (format "%s." (plist-get entry :index))))))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden
        (text (expr (or (plist-get entry :name) ""))))
      (box :width '(ch 5) :height '(lh 1) :text-align 'right
           :color (etaf-ncm-color :dim)
        (text (expr (or (plist-get entry :right) "")))))))

(etaf-define-component etaf-ncm--view-aside
    (&key aside title artist album lines trans current position total loading
          entries pos count layout on-switch on-jump)
  "Render the ASIDE panel with either the lyrics or the queue.
LAYOUT decides the width: a wide layout keeps the panel at its sidebar width,
a compact one makes it the only visible pane so it fills the window."
  :view
  (flex :flex-direction 'column
        :width (if (eq layout 'wide) etaf-ncm--aside-width 'stretch)
        :flex-grow (if (eq layout 'wide) 0 1)
        :min-width '(ch 0) :height 'stretch
        :padding '((lh 1) (ch 2)) :gap '((lh 0) (px 0))
        :background-color (etaf-ncm-color :panel)
          :border-left (etaf-ncm--view-border 'left (etaf-ncm-color :line))
    (etaf-ncm--view-tabs :aside aside :on-switch on-switch)
    (etaf-ncm--view-lyrics :if (eq aside 'lyrics)
      :title title :artist artist :album album :lines lines :trans trans
      :current current :position position :total total :loading loading)
    (etaf-ncm--view-queue :if (eq aside 'queue)
      :entries entries :pos pos :count count :on-jump on-jump)))

(etaf-define-component etaf-ncm--view-control (&key icon glyph label help on-press active ref)
  "Render one compact player action.
ICON names an `etaf-ui-icon' in the SVG style, so the control keeps one
optical size and never changes the row height.  GLYPH is the plain-text
alternative for controls that are words (词 ON) instead of pictures.  LABEL
appends a small count or state next to the icon."
  :view
  (flex :width 'max-content :height '(lh 1) :align-items 'center :flex-shrink 0
        :gap '((lh 0) (ch 1))
    (etaf-ui-icon :if icon :name (or icon 'music) :set 'svg :size 1.0
                  :color (etaf-ncm-color (if active :accent :muted))
                  :min-width 3 :help-echo help :on-press on-press :ref ref)
    (box :if (and (not icon) glyph) :height '(lh 1) :role 'button :tab-index 0
         :color (etaf-ncm-color (if active :accent :muted))
         :hover-style (etaf-ncm--hover-surface)
         :help-echo help :on-press on-press
      (text (expr (or glyph ""))))
    (box :if label :height '(lh 1) :color (etaf-ncm-color :muted)
      (text (expr (or label ""))))))

(etaf-define-component etaf-ncm--view-track
    (&key title artist vip queue-count compact shuffle message liked
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
      (etaf-ncm--view-cover :size '(ch 6) :height '(lh 3)))
    (box :if compact :height '(lh 1) :width 'stretch
         :min-width '(ch 0) :overflow 'hidden :font-weight 'bold
      (text (expr (concat (if vip "VIP " "")
                          (if (string-empty-p (or title "")) "未在播放" title)
                          (if (string-empty-p (or artist "")) "" (concat " - " artist))))))
    (flex :flex-direction 'column :width 'stretch :min-width '(ch 0)
          :gap '((lh 0) (ch 1)) :justify-content 'center
      (flex :if (not compact) :height '(lh 1) :width 'stretch
            :min-width '(ch 0)
            :gap '((lh 0) (ch 1)) :align-items 'center
        (box :if vip :id "ncm-vip" :height '(lh 1) :color (etaf-ncm-color :accent)
          (text "VIP"))
        (box :height '(lh 1) :flex-grow 1 :flex-basis '(px 0)
             :min-width '(ch 0) :overflow 'hidden :font-weight 'bold
          (text (expr (concat (if (string-empty-p (or title "")) "未在播放" title)
                              (if (string-empty-p (or artist "")) ""
                                (concat " - " artist)))))))
      (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
        (etaf-ncm--view-control :ref 'ncm-plus :icon 'plus :help "加入队列 (a)" :on-press on-add)
        (etaf-ncm--view-control :ref 'ncm-like :icon (if liked 'heart-filled 'heart)
                                :active liked
                                :help "喜欢 / 取消喜欢 (f / F)" :on-press on-like)
        (etaf-ncm--view-control :ref 'ncm-shuffle :icon 'shuffle :help "随机播放 (z)"
                                :on-press on-shuffle :active shuffle)
        (etaf-ncm--view-control :ref 'ncm-stop :icon 'close :help "停止" :on-press on-stop)
        (etaf-ncm--view-control :ref 'ncm-queue :icon 'queue :help "显示播放列表" :on-press on-queue
                                :label (format "%s" (or queue-count 0))))
      (box :if (not compact) :height '(lh 1) :width 'stretch
           :overflow 'hidden :color (etaf-ncm-color :dim)
        (text (expr (or message "")))))))

(etaf-define-component etaf-ncm--view-transport
    (&key state repeat compact on-like on-previous on-toggle on-next on-repeat)
  "Render the centred transport with an accent play control.
The play control is a one-line accent pill: a bigger glyph would paint outside
its row and clip, which a terminal-cell layout cannot round away."
  :view
  (flex :height (if compact '(lh 1) '(lh 2))
        :gap (if compact '((lh 0) (ch 1)) '((lh 0) (ch 3)))
        :align-items 'center :justify-content 'center
    (etaf-ncm--view-control :ref 'ncm-previous :icon 'previous :help "上一首 (p)" :on-press on-previous)
    (box :id "ncm-play" :ref 'ncm-play :width (if compact '(ch 3) '(ch 4))
         :height '(lh 1) :flex-shrink 0
         :background-color (etaf-ncm-color :accent)
      (etaf-ui-icon :name (if (eq state 'playing) 'pause 'play) :set 'svg :size 0.9
                    :color (etaf-ncm-color :ink)
                    ;; Span the whole pill so the glyph centres with one inset on
                    ;; both sides; a narrower icon leaves the right side heavier.
                    :min-width (if compact 3 4)
                    :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle))
    (etaf-ncm--view-control :ref 'ncm-next :icon 'next :help "下一首 (n)" :on-press on-next)
    (etaf-ncm--view-control :ref 'ncm-repeat :icon 'repeat :help "列表循环 (r)" :on-press on-repeat :active repeat)))

(etaf-define-component etaf-ncm--view-progress
    (&key elapsed duration on-seek)
  "Render elapsed, a draggable progress range and the duration."
  :view
  (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
    (box :width '(ch 5) :height '(lh 1) :text-align 'right
         :color (etaf-ncm-color :dim) :flex-shrink 0
      (text :ref 'ncm-elapsed :id "ncm-elapsed"
            (expr (etaf-ncm--format-seconds elapsed))))
    (flex :flex-direction 'row :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
          :height '(lh 1)
      (etaf-range :value elapsed :min 0 :max (max 1 (or duration 0))
                  :ref 'ncm-seek :fill-ref 'ncm-meter
                  :aria-label "播放进度，点击或拖动跳转"
                  :color (etaf-ncm-color :accent)
                  :track-color (etaf-ncm-color :panel3)
                  :on-commit on-seek))
    (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim) :flex-shrink 0
      (text (expr (etaf-ncm--format-seconds duration))))))

(etaf-define-component etaf-ncm--view-player-tools
    (&key quality lyrics volume compact on-lyrics on-queue on-volume)
  "Render the reported quality, pane controls and a draggable volume range.
Controls sit in separated groups so the right edge reads as three ideas
(quality badge, pane switches, volume) instead of one crowded line."
  :view
  (flex :height '(lh 1) :align-items 'center :flex-shrink 0
        :justify-content 'end :gap (if compact '((lh 0) (ch 0.5)) '((lh 0) (ch 1)))
    (box :if (and quality (not compact)) :id "ncm-quality" :ref 'ncm-quality :height '(lh 1)
         :flex-shrink 0 :min-width '(ch 4) :max-width '(ch 10) :overflow 'hidden :help-echo quality
         :color (etaf-ncm-color :muted)
      (text (expr (format "[%s]" quality))))
    (box :if (and quality (not compact)) :width '(ch 1) :height '(lh 1) (text " "))
    (etaf-ncm--view-control :ref 'ncm-lyrics :icon 'lyrics :help "显示歌词 (l)" :on-press on-lyrics :active lyrics)
    (etaf-ncm--view-control :ref 'ncm-queue-aside :icon 'queue :help "显示播放列表" :on-press on-queue)
    (box :width '(ch 1) :height '(lh 1) (text " "))
    (etaf-ui-icon :name (if (and (numberp volume) (zerop volume)) 'volume-mute 'volume)
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
      (text (expr (format "%d%%" (or volume 0)))))))

(etaf-define-component etaf-ncm--view-player
    (&key title artist vip quality state elapsed duration volume shuffle repeat lyrics message
          queue-count compact liked on-toggle on-next on-previous on-stop on-like on-add
          on-volume on-seek on-shuffle on-repeat
          on-lyrics on-queue)
  "Render a native-style three-column bar, or three compact rows.
The bar box is border-box: one border row, three content rows and one padding
row above and below, so its total footprint stays the six lines the page
budget reserves."
  :view
  (box :width 'stretch :height '(lh 6) :flex-shrink 0
       :padding '((lh 1) (ch 2))
       :background-color (etaf-ncm-color :panel)
       :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (grid :if (not compact) :width 'stretch :height '(lh 3)
          :grid-template-columns '((fr 1) (fr 1) (fr 1)) :gap '((lh 0) (ch 2))
      (etaf-ncm--view-track :title title :artist artist :vip vip :queue-count queue-count
                            :message message :shuffle shuffle :liked liked
                            :on-lyrics on-lyrics :on-add on-add
                            :on-like on-like :on-shuffle on-shuffle :on-stop on-stop :on-queue on-queue)
      (flex :flex-direction 'column :width 'stretch :height '(lh 3)
        (etaf-ncm--view-transport :state state :repeat repeat :on-like on-like
                                :on-previous on-previous :on-toggle on-toggle :on-next on-next :on-repeat on-repeat)
        (etaf-ncm--view-progress :elapsed elapsed :duration duration
                               :on-seek on-seek))
      (flex :width 'stretch :height '(lh 3) :align-items 'center
        (etaf-ncm--view-player-tools :quality quality :lyrics lyrics :volume volume
                                   :on-lyrics on-lyrics :on-queue on-queue
                                   :on-volume on-volume)))
    (flex :if compact :width 'stretch :height '(lh 3) :flex-direction 'column
      (etaf-ncm--view-track :title title :artist artist :vip vip :queue-count queue-count
                            :compact t :shuffle shuffle :liked liked
                            :on-add on-add :on-like on-like
                            :on-shuffle on-shuffle :on-stop on-stop :on-queue on-queue)
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
        (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
          (etaf-ncm--view-transport :state state :repeat repeat :compact t :on-like on-like
                                  :on-previous on-previous :on-toggle on-toggle :on-next on-next :on-repeat on-repeat))
        (flex :width '(ch 24) :height '(lh 1) :flex-shrink 0 :flex-direction 'row
          (etaf-ncm--view-player-tools :lyrics lyrics :volume volume :compact t
                                     :on-lyrics on-lyrics :on-queue on-queue
                                     :on-volume on-volume)))
      (etaf-ncm--view-progress :elapsed elapsed :duration duration
                             :on-seek on-seek))))

(provide 'etaf-ncm-views)
;;; etaf-ncm-views.el ends here
