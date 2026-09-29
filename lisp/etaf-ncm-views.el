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

(defconst etaf-ncm--lyric-window-size 14
  "Lyric lines rendered around the current line.")

(defun etaf-ncm--view-border (_side color)
  "Return the border value of SIDE drawn with COLOR."
  (list '(px 1) 'solid color))

(defun etaf-ncm--view-duration (milliseconds)
  "Return MILLISECONDS as \"M:SS\", or an empty string."
  (etaf-ncm--format-duration milliseconds))

(defun etaf-ncm--view-ratio (value total)
  "Return VALUE/TOTAL clamped to a nonzero flex fraction."
  (let ((total (if (and (numberp total) (> total 0)) total 1)))
    (max 0.001 (min 1.0 (/ (float (or value 0)) total)))))

(defun etaf-ncm--lyric-window (lines index size)
  "Return (START . VISIBLE) for a window of SIZE LINES around INDEX."
  (let* ((total (length lines))
         (size (max 1 (min size total)))
         (start (max 0 (min (- index (/ size 3)) (- total size)))))
    (cons start (seq-subseq lines start (+ start size)))))

(defun etaf-ncm--translation-for (trans seconds)
  "Return the translation of SECONDS from TRANS, or nil."
  (cdr (assq seconds trans)))

;;; ---------------------------------------------------------------------------
;;; Primitive Views
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-nav-item (&key glyph label active badge on-press)
  "Render one library entry with GLYPH, LABEL, BADGE and press callback."
  :view
  (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
        :align-items 'center :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0
        :background-color (and active (etaf-ncm-color :accent-soft))
        :color (if active (etaf-ncm-color :ink) (etaf-ncm-color :muted))
        :font-weight (if active 'bold 'normal)
        :on-press on-press
    (box :width '(ch 2) :height '(lh 1)
         :color (if active (etaf-ncm-color :accent) (etaf-ncm-color :dim))
      (text (expr (or glyph ""))))
    (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
         :overflow 'hidden
      (text (expr (or label ""))))
    (box :if badge :width '(ch 5) :height '(lh 1) :text-align 'right
         :font-weight 'normal :color (etaf-ncm-color :dim)
      (text (expr badge)))))

(etaf-define-component etaf-ncm--view-row
    (&key index row selected playing compact on-press)
  "Render library ROW number INDEX, marked SELECTED and PLAYING as appropriate.
COMPACT drops the album column, which a narrow frame cannot show."
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
        :on-press on-press
    (box :height '(lh 1) :justify-self 'end
         :color (cond (playing (etaf-ncm-color :accent))
                      (selected (etaf-ncm-color :muted))
                      (t (etaf-ncm-color :dim)))
      (text (expr (if playing "▶" (format "%2s" index)))))
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

(etaf-define-component etaf-ncm--view-cover (&key size glyph)
  "Render a square cover placeholder of SIZE characters."
  :view
  (column :width size :height '(lh 7) :bgcolor (etaf-ncm-color :panel3)
          :item-gap '(lh 0) :cross-align 'center
    (box :height '(lh 2))
    (box :height '(lh 2) :text-align 'center :font-size 30
         :color (etaf-ncm-color :accent)
      (text (expr (or glyph "♪"))))
    (box :height '(lh 3))))

(etaf-define-component etaf-ncm--view-meter (&key ratio color)
  "Render a thin meter filled to RATIO with COLOR."
  :view
  (flex :width 'stretch :height '(lh 1) :align-items 'center
        :gap '((lh 0) (px 0))
    (box :height '(% 35) :flex-grow (etaf-ncm--view-ratio ratio 1)
         :flex-basis '(px 0) :min-width '(px 1)
         :bgcolor (or color (etaf-ncm-color :accent)))
    (box :height '(% 35) :flex-grow (- 1 (etaf-ncm--view-ratio ratio 1))
         :flex-basis '(px 0) :min-width '(px 0)
         :bgcolor (etaf-ncm-color :panel3))))

;;; ---------------------------------------------------------------------------
;;; Library
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm--view-sidebar
    (&key groups section account compact on-locate)
  "Render the library sidebar from GROUPS with SECTION highlighted.
COMPACT renders the glyph-only rail a medium layout has room for."
  :view
  (column :width (if compact etaf-ncm--rail-width etaf-ncm--sidebar-width)
          :height 'stretch
          :padding '((lh 1) (ch 1)) :item-gap '(lh 0)
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
      (box :if (not compact) :height '(lh 2) :padding '((lh 0) (ch 1))
           :font-weight 'bold :color (etaf-ncm-color :dim)
        (text (expr (format "%s" (car group)))))
      (etaf-ncm--view-nav-item :for (entry (cdr group)) :key (car entry)
        :glyph (nth 2 entry)
        :label (if compact "" (nth 1 entry))
        :active (eq (car entry) section)
        :on-press (lambda () (funcall on-locate (car entry)))))
    (box :height 'stretch)
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
      :background-color (and (eq (car entry) section) (etaf-ncm-color :accent-soft))
      :color (if (eq (car entry) section) (etaf-ncm-color :accent) (etaf-ncm-color :dim))
      :on-press (lambda () (funcall on-locate (car entry)))
      (box :height '(lh 1)
        (text (expr (or (nth 2 entry) "")))))))

(etaf-define-component etaf-ncm--view-header
    (&key title subtitle query loading compact on-search on-play-all on-refresh)
  "Render the content header for TITLE with its actions.
COMPACT stacks the search field under the title, the shape a narrow frame needs."
  :view
  (column :width 'stretch :height (if compact '(lh 3) '(lh 2)) :item-gap '(lh 0)
    (flex :if compact :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-size 17 :font-weight 'bold
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
      (etaf-button :label "▶ 播放全部" :variant 'primary :on-press on-play-all))
    (flex :if (not compact) :width 'stretch :height '(lh 2)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (column :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :item-gap '(lh 0)
        (text :font-size 17 :font-weight 'bold (expr (or title "")))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
             :font-size 12
          (text (expr (or subtitle "")))))
      (box :width '(ch 30) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder "搜索歌曲、歌手、歌单或专辑"
                         :hide-label t :on-change on-search))
      (etaf-button :label "▶ 播放全部" :variant 'primary :on-press on-play-all)
      (etaf-button :label (if loading "… 加载中" "↻ 换一批") :variant 'ghost
                   :on-press on-refresh))))

(etaf-define-component etaf-ncm--view-pane-tabs (&key pane aside on-pane on-aside)
  "Render the list/lyrics/queue switch a compact layout uses."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :align-items 'center :padding '((lh 0) (ch 2))
        :background-color (etaf-ncm-color :panel)
        :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (flex :for (tab (list (list 'list "列表")
                          (list 'lyrics "歌词")
                          (list 'queue "队列"))) :key (car tab)
      :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
      :padding '((lh 0) (ch 1)) :role 'button :tab-index 0
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
         :font-size 12
      (text (expr (if (eq pane 'aside)
                      (if (eq aside 'lyrics) "l 歌词/队列" "l 切换面板")
                    "j/k 选择 · RET 播放"))))))

(etaf-define-component etaf-ncm--view-list
    (&key entries start total compact empty-note on-play)
  "Render the visible library ENTRIES and a page footer."
  :view
  (column :width 'stretch :flex-grow 1 :min-height '(lh 0) :item-gap '(lh 0)
          :overflow 'hidden
    (etaf-ncm--view-note :if (null entries) :text empty-note)
    (etaf-ncm--view-row :for (entry entries) :key (plist-get entry :index)
      :index (plist-get entry :index)
      :row (plist-get entry :row)
      :selected (plist-get entry :selected)
      :playing (plist-get entry :playing)
      :compact compact
      :on-press (lambda () (funcall on-play entry)))
    (box :if entries :height 'stretch)
    (flex :if entries :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
          :color (etaf-ncm-color :dim) :font-size 12
      (box :height '(lh 1)
        (text (expr (format "第 %s-%s 首，共 %s 首"
                            start
                            (if entries (+ start (1- (length entries))) start)
                            total))))
      (box :if (not compact) :height '(lh 1)
        (text "j/k 选择 · RET 播放 · a 加入队列 · / 搜索 · l 歌词 · ? 帮助")))))

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
         :font-weight (if (eq aside 'lyrics) 'bold 'normal)
         :color (if (eq aside 'lyrics) (etaf-ncm-color :ink)
                  (etaf-ncm-color :muted))
         :border-bottom (and (eq aside 'lyrics)
                             (etaf-ncm--view-border 'bottom
                                                    (etaf-ncm-color :accent)))
         :on-press (lambda () (funcall on-switch 'lyrics))
      (text "歌词"))
    (box :height '(lh 2) :role 'button :tab-index 0
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
        (box :height '(lh 1) :overflow 'hidden :font-size 14 :font-weight 'bold
          (text (expr (or title "还没有播放"))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
          (text (expr (or artist ""))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :dim)
             :font-size 12
          (text (expr (or album ""))))))
    (box :height '(lh 1))
    (box :if loading :height '(lh 1) :color (etaf-ncm-color :dim)
      (text "正在取歌词…"))
    (box :if (and (not loading) (null lines)) :height '(lh 1)
         :color (etaf-ncm-color :dim)
      (text "这首歌没有歌词"))
    (flex :if lines :flex-direction 'column :width 'stretch :flex-grow 1
          :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
      (column :for (line lines) :key (format "%s" (car line))
              :width 'stretch :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden
             :color (if (equal (car line) current)
                        (etaf-ncm-color :accent)
                      (etaf-ncm-color :muted))
             :font-weight (if (equal (car line) current) 'bold 'normal)
          (text (expr (or (cdr line) " "))))
        (box :if (cdr (assq (car line) trans)) :height '(lh 1) :overflow 'hidden
             :color (etaf-ncm-color :dim) :font-size 12
          (text (expr (or (cdr (assq (car line) trans)) ""))))))
    (box :if lines :width 'stretch :height '(lh 1) :color (etaf-ncm-color :dim)
         :font-size 12 :text-align 'center
      (text (expr (format "%s / %s" (or position 0) (or total 0)))))))

(etaf-define-component etaf-ncm--view-queue (&key entries pos count on-jump)
  "Render queue ENTRIES around position POS.
Each entry is (:index :name :right :current) from the player model."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
        :min-height '(lh 0) :gap '((lh 0) (px 0)) :overflow 'hidden
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center
      (text :font-weight 'bold "播放队列")
      (text :color (etaf-ncm-color :dim)
            (expr (format "%s / %s" (or pos 0) (or count 0)))))
    (box :if (null entries) :height '(lh 1) :color (etaf-ncm-color :dim)
      (text "队列是空的"))
    (flex :for (entry entries) :key (plist-get entry :index)
      :width 'stretch :height '(lh 1) :role 'button :tab-index 0
      :gap '((lh 0) (ch 1)) :align-items 'center
      :background-color (and (plist-get entry :current)
                             (etaf-ncm-color :accent-soft))
      :color (if (plist-get entry :current)
                 (etaf-ncm-color :accent)
               (etaf-ncm-color :muted))
      :font-weight (if (plist-get entry :current) 'bold 'normal)
      :on-press (lambda () (funcall on-jump (plist-get entry :index)))
      (box :width '(ch 3) :height '(lh 1) :color (etaf-ncm-color :dim)
        (text (expr (if (plist-get entry :current)
                        "▶"
                      (format "%s." (plist-get entry :index))))))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden
        (text (expr (or (plist-get entry :name) ""))))
      (box :width '(ch 5) :height '(lh 1) :text-align 'right
           :color (etaf-ncm-color :dim)
        (text (expr (or (plist-get entry :right) "")))))))

(etaf-define-component etaf-ncm--view-aside
    (&key aside title artist album lines trans current position total loading
          entries pos count on-switch on-jump)
  "Render the ASIDE panel with either the lyrics or the queue."
  :view
  (flex :flex-direction 'column :width etaf-ncm--aside-width :height 'stretch
        :padding '((lh 1) (ch 2)) :gap '((lh 0) (px 0))
        :background-color (etaf-ncm-color :panel)
          :border-left (etaf-ncm--view-border 'left (etaf-ncm-color :line))
    (etaf-ncm--view-tabs :aside aside :on-switch on-switch)
    (etaf-ncm--view-lyrics :if (eq aside 'lyrics)
      :title title :artist artist :album album :lines lines :trans trans
      :current current :position position :total total :loading loading)
    (etaf-ncm--view-queue :if (eq aside 'queue)
      :entries entries :pos pos :count count :on-jump on-jump)))

(etaf-define-component etaf-ncm--view-player
    (&key title artist state elapsed duration volume shuffle repeat message
          queue-pos queue-count compact
          on-toggle on-next on-previous on-stop on-like on-volume on-seek
          on-shuffle on-repeat)
  "Render the player bar for the current track and its controls.
COMPACT stacks the track and the progress line, the shape a phone uses and a
narrow frame has room for."
  :view
  (flex :flex-direction (if compact 'column 'row)
        :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :align-items 'center :padding '((lh 0) (ch 2))
        :background-color (etaf-ncm-color :panel)
        :border-top (etaf-ncm--view-border 'top (etaf-ncm-color :line))
    (flex :if compact :width 'stretch :height '(lh 1)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (box :width '(ch 3) :height '(lh 1) :text-align 'center
           :color (etaf-ncm-color :accent)
        (text (expr (if (eq state 'playing) " ▶" " ⏸"))))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'bold
        (text (expr (or title "未在播放"))))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :color (etaf-ncm-color :muted) :text-align 'right
        (text (expr (if (and message (not (string-empty-p message)))
                         message
                       (or artist "")))))
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-like
        (text "♡"))
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-previous
        (text "⏮"))
      (box :height '(lh 1) :role 'button :tab-index 0 :font-weight 'bold
           :color (etaf-ncm-color :accent)
           :on-press on-toggle
        (text (expr (if (eq state 'playing) "⏸" "▶"))))
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-next
        (text "⏭")))
    (flex :if compact :width 'stretch :height '(lh 1)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (box :width '(ch 5) :height '(lh 1) :text-align 'right
           :color (etaf-ncm-color :dim)
        (text (expr (etaf-ncm--format-seconds elapsed))))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :role 'button :tab-index 0
           :on-press (lambda () (funcall on-seek 15))
        (etaf-ncm--view-meter :ratio (etaf-ncm--view-ratio elapsed duration)))
      (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim)
        (text (expr (etaf-ncm--format-seconds duration))))
      (box :width '(ch 16) :height '(lh 1) :text-align 'right
           :color (etaf-ncm-color :dim) :font-size 12 :overflow 'hidden
        (text (expr (format "%s/%s · 音量 %s" (or queue-pos 0) (or queue-count 0)
                            (or volume 0))))))
    (flex :if (not compact) :width '(ch 30) :gap '((lh 0) (ch 1)) :align-items 'center
      (box :width '(ch 3) :height '(lh 2) :text-align 'center
           :background-color (etaf-ncm-color :accent-soft)
           :color (etaf-ncm-color :accent)
        (text (expr (if (eq state 'playing) " ▶" " ⏸"))))
      (column :min-width '(ch 0) :flex-grow 1 :flex-basis '(px 0) :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text (expr (or title "未在播放"))))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-ncm-color :muted)
          (text (expr (if (and message (not (string-empty-p message)))
                           message
                         (or artist "")))))))
    (flex :if (not compact) :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (box :width '(ch 5) :height '(lh 1) :text-align 'right
           :color (etaf-ncm-color :dim)
        (text (expr (etaf-ncm--format-seconds elapsed))))
      (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
           :role 'button :tab-index 0
           :on-press (lambda () (funcall on-seek 15))
        (etaf-ncm--view-meter :ratio (etaf-ncm--view-ratio elapsed duration)))
      (box :width '(ch 5) :height '(lh 1) :color (etaf-ncm-color :dim)
        (text (expr (etaf-ncm--format-seconds duration))))
      (box :width '(ch 8) :height '(lh 1) :color (etaf-ncm-color :dim)
           :font-size 12
        (text (expr (format "%s/%s" (or queue-pos 0) (or queue-count 0))))))
    (flex :if (not compact) :gap '((lh 0) (ch 1)) :align-items 'center
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-like
        (text "♡"))
      (box :height '(lh 1) :role 'button :tab-index 0
           :color (if repeat (etaf-ncm-color :accent) (etaf-ncm-color :muted))
           :on-press on-repeat
        (text "↻"))
      (box :height '(lh 1) :role 'button :tab-index 0
           :color (if shuffle (etaf-ncm-color :accent) (etaf-ncm-color :muted))
           :on-press on-shuffle
        (text "⇄"))
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-previous
        (text "⏮"))
      (box :height '(lh 1) :role 'button :tab-index 0 :font-weight 'bold
           :color (etaf-ncm-color :accent)
           :on-press on-toggle
        (text (expr (if (eq state 'playing) "⏸" "▶"))))
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-next
        (text "⏭"))
      (box :height '(lh 1) :role 'button :tab-index 0 :color (etaf-ncm-color :muted)
           :on-press on-stop
        (text "■"))
      (flex :width '(ch 8) :gap '((lh 0) (ch 1)) :align-items 'center
        (box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0) :height '(lh 1)
             :role 'button :tab-index 0
             :on-press (lambda () (funcall on-volume 5))
          (etaf-ncm--view-meter :ratio (etaf-ncm--view-ratio volume 130)
                                :color (etaf-ncm-color :muted)))
        (box :width '(ch 3) :height '(lh 1) :text-align 'right
             :color (etaf-ncm-color :dim) :font-size 12
          (text (expr (format "%s" (or volume 0)))))))))

(provide 'etaf-ncm-views)
;;; etaf-ncm-views.el ends here
