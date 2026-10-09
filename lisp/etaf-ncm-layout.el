;;; etaf-ncm-layout.el --- Responsive layout plan and type scale -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The player is a text grid without container queries, so adaptivity is a
;; decision table.  This module owns that table, and it owns it in one place:
;;
;; - The layout tier follows from what the panes are made of, not from a
;;   screen size someone typed in.  The header and a row declare the columns
;;   their labels and actions need; the list pane's minimum is the larger of
;;   those; the breakpoint is that minimum plus the columns the sidebar and
;;   the side panel occupy.  Change a label or an action and every breakpoint
;;   follows.
;; - The vertical budget decides how many library rows fit.  Every tier spends
;;   a fixed number of rows on the header, the chip strip, the pane switch and
;;   the player bar; the model and the views read the same budget, so reserved
;;   and painted rows cannot disagree.
;; - The row plan decides which columns survive a narrow list: the song name
;;   never leaves, the artist folds into the name first, then the badge, then
;;   the album.  A variant is chosen by testing whether its fixed columns plus
;;   the name minimum fit, so a template change moves the choice with it.
;; - The chip plan keeps every library in the strip: the strip first drops its
;;   gaps and then narrows each chip to the icon's inset before a library
;;   could fall off the edge.
;; - The type scale has two sizes: the frame default for everything a reader
;;   acts on, and `etaf-ncm-font-meta' for secondary facts (subtitles,
;;   counters, hints, credits).  Emphasis uses weight, never a larger size, so
;;   wording can never change a fixed row height.  A short frame sheds whole
;;   lines (the subtitle, the hint) instead of shrinking type.

;;; Code:

(require 'cl-lib)
(require 'etaf-ncm-theme)

;;; Type scale

(defconst etaf-ncm-font-meta 15
  "Face size, in Ebox reference pixels, of secondary text.
Subtitles, counters, hints and credits use this size; everything a reader
acts on uses the frame's default size.  Emphasis uses weight, not size, so a
row's height never follows its wording.  Fifteen reference pixels is about
11.25 pt on a 14 pt frame: clearly smaller, still readable.")

;;; Fixed cells

(defconst etaf-ncm-layout-sidebar-columns 24
  "Width of the full library sidebar in columns.")

(defconst etaf-ncm-layout-rail-columns 6
  "Width of the glyph-only library rail in columns.")

(defconst etaf-ncm-layout-aside-columns 40
  "Width of the lyric and queue panel in columns.")

(defconst etaf-ncm-layout-bar-rows 5
  "Rows the player bar occupies.
Its top border, one padding row and the three content rows.  The bar keeps no
bottom padding: the window's echo area already gives the bar a clear closing
line, and the text sits one row from the bottom edge.")

(defconst etaf-ncm-layout-tab-rows 1
  "Rows the compact list/lyrics/queue switch occupies above the player bar.")

(defconst etaf-ncm-layout-chips-rows 2
  "Rows the narrow-tier library chip strip occupies.")

(defconst etaf-ncm-layout-footer-rows 2
  "Rows the list footer may occupy: the visible range and the loaded total.")

(defconst etaf-ncm-layout-min-page-rows 4
  "Smallest library page kept even in a very short window.")

;;; What the header, a row and a chip are made of

(defconst etaf-ncm-layout-title-min-columns 8
  "Smallest title column the header keeps.
A library name is a few characters; below this the title itself would be
unreadable, so the tier changes instead.")

(defconst etaf-ncm-layout-title-comfort-columns 26
  "Title column width at which the full subtitle fits beside the actions.")

(defconst etaf-ncm-layout-search-columns 30
  "Natural width of the search field in columns.
It is the placeholder's width; a narrower pane shrinks the field toward
`etaf-ncm-layout-search-min-columns' before anything else gives way.")

(defconst etaf-ncm-layout-search-min-columns 10
  "Smallest search field kept in any header row.")

(defconst etaf-ncm-layout-play-columns 15
  "Width of the play-all action including its padding and slack.
\"播放全部\" is eight columns of label, four of button padding and the slack
an `expr' text run needs before a multi-character label stops clipping.")

(defconst etaf-ncm-layout-refresh-columns 11
  "Width of the refresh action including its padding and slack.
\"换一批\" is six columns of label, two of ghost-button padding and the slack
an `expr' text run needs before a multi-character label stops clipping.")

(defconst etaf-ncm-layout-gap-columns 3
  "Total gap columns between the header's title, search and actions.")

(defconst etaf-ncm-layout-panel-pad-columns 4
  "Horizontal padding of the wide list panel in columns, two per side.")

(defconst etaf-ncm-layout-row-name-min-columns 10
  "Smallest name column a library row keeps.
A narrower row drops its secondary columns instead of squeezing the name.")

(defconst etaf-ncm-layout-row-name-comfort-columns 22
  "Name column at which a compact row reads comfortably.
The rail is worth its six columns only while the list still gives a name
this much room; below it the chip strip returns those columns to the list.")

(defconst etaf-ncm-layout-row-templates
  '((full    (ch 3) (fr 1) (ch 20) (ch 16) (ch 5) (ch 6) (ch 3) (ch 3))
    (regular (ch 3) (fr 1) (ch 14) (ch 5) (ch 6) (ch 3))
    (compact (ch 3) (fr 1) (ch 5) (ch 6) (ch 3))
    (tiny    (ch 2) (fr 1) (ch 5) (ch 3)))
  "Grid columns of a library row by variant.
`full' is index, name, artist, album, badge, time, download and queue;
`regular' keeps index, name, artist, badge, time and download; `compact'
folds the artist into the name cell; `tiny' drops the badge as well.  The
name column is the only flexible one and never leaves.")

(defconst etaf-ncm-layout-chip-columns 5
  "Comfortable width of one library chip: the icon and a one-column inset.")

(defconst etaf-ncm-layout-chip-min-columns 4
  "Narrowest library chip that still fits its icon.")

;;; Derived breakpoints
;;
;; These keep their user-facing names, but their defaults are computed from
;; the parts above: a tier begins where its panes' minimums fit together.

(defun etaf-ncm-layout-row-fixed-columns (variant)
  "Return the fixed-width columns of row VARIANT.
It sums every non-flexible column, the one-column gaps between them and the
row's two padding columns; add `etaf-ncm-layout-row-name-min-columns' for the
smallest width the variant needs."
  (let* ((template (etaf-ncm-layout-row-columns variant))
         (fixed (cl-loop for column in template
                         unless (eq (car-safe column) 'fr)
                         sum (cadr column))))
    (+ fixed (* (1- (length template)) 1) 2)))

(defun etaf-ncm-layout-row-columns (variant)
  "Return the grid template columns of row VARIANT."
  (or (cdr (assq variant etaf-ncm-layout-row-templates))
      (cdr (assq 'regular etaf-ncm-layout-row-templates))))

(defun etaf-ncm-layout-row-min-columns (variant)
  "Return the smallest window width row VARIANT can fill."
  (+ etaf-ncm-layout-row-name-min-columns
     (etaf-ncm-layout-row-fixed-columns variant)))

(defun etaf-ncm-layout-header-min-columns (layout)
  "Return the columns a header in LAYOUT needs to stay readable.
The wide header keeps its parts on one row; a compact header puts the search
and the action on a second row, so its minimum is the wider of the two."
  (let ((pad etaf-ncm-layout-panel-pad-columns)
        (gap 1))
    (if (eq layout 'wide)
        (+ etaf-ncm-layout-title-min-columns
           etaf-ncm-layout-search-min-columns
           etaf-ncm-layout-play-columns
           etaf-ncm-layout-refresh-columns
           etaf-ncm-layout-gap-columns
           pad)
      (max (+ etaf-ncm-layout-title-min-columns etaf-ncm-layout-refresh-columns gap pad)
           (+ etaf-ncm-layout-search-min-columns etaf-ncm-layout-play-columns gap pad)))))

(defconst etaf-ncm-layout-list-min-columns
  (max (etaf-ncm-layout-header-min-columns 'wide)
       (etaf-ncm-layout-row-min-columns 'full))
  "Columns the wide list pane needs before a header or a row can be read.
The breakpoints add the sidebar or the rail to this sum.")

(defconst etaf-ncm-layout-wide-comfort-columns
  (+ etaf-ncm-layout-title-comfort-columns
     etaf-ncm-layout-search-columns
     etaf-ncm-layout-play-columns
     etaf-ncm-layout-refresh-columns
     etaf-ncm-layout-gap-columns)
  "List content width at which the wide header shows every part at its
natural size: a complete subtitle, the full search placeholder and both
actions.  Below it the subtitle is dropped rather than clipped, and the
search field shrinks toward its minimum.")

(defcustom etaf-ncm-wide-columns
  (+ etaf-ncm-layout-sidebar-columns etaf-ncm-layout-aside-columns
     etaf-ncm-layout-list-min-columns)
  "Window width, in columns, that fits the three-column player.
At or above this width the library sidebar, the song list and the side panel
share the frame.  The default is derived: the sidebar and the side panel plus
the list pane's own minimum, which is what the header and a full row need.  A
narrower frame switches to the glyph rail."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-medium-columns
  (+ etaf-ncm-layout-rail-columns
     (etaf-ncm-layout-row-fixed-columns 'regular)
     etaf-ncm-layout-row-name-comfort-columns)
  "Window width, in columns, that still fits the glyph-only library rail.
Between this width and `etaf-ncm-wide-columns' the sidebar becomes an icon
rail and the panes share the frame.  The default is derived from the rail
plus a comfortable regular row: below it the chip strip returns the rail's
columns to the list instead of squeezing the names."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-compact-rows 24
  "Window rows below which the compact layouts shed secondary lines.
Short frames keep the title, the library, the transport and the progress;
they drop the header subtitle, the hint line and the loaded total instead of
squeezing the library page."
  :type 'integer
  :group 'etaf-ncm)

;;; Vertical plan

(defun etaf-ncm-layout-for (columns)
  "Return the layout COLUMNS columns of text can hold.
The result is `wide', `medium' or `narrow'; see `etaf-ncm-wide-columns' and
`etaf-ncm-medium-columns'."
  (cond ((>= (or columns 0) etaf-ncm-wide-columns) 'wide)
        ((>= (or columns 0) etaf-ncm-medium-columns) 'medium)
        (t 'narrow)))

(defun etaf-ncm-layout-compact-p (layout)
  "Return non-nil when LAYOUT shows one content pane at a time."
  (not (eq layout 'wide)))

(defun etaf-ncm-layout-header-rows (layout)
  "Return the rows the content header occupies in LAYOUT.
The wide header stacks a title over its subtitle; a compact one keeps the
title row and puts the search field and the library action on their own row."
  (if (eq layout 'wide) 2 3))

(defun etaf-ncm-layout-chips-rows-for (layout)
  "Return the rows the library chip strip occupies in LAYOUT."
  (if (eq layout 'narrow) etaf-ncm-layout-chips-rows 0))

(defun etaf-ncm-layout-tabs-rows (layout)
  "Return the rows the compact pane switch occupies in LAYOUT."
  (if (etaf-ncm-layout-compact-p layout) etaf-ncm-layout-tab-rows 0))

(defun etaf-ncm-layout-short-p (window-rows)
  "Return non-nil when WINDOW-ROWS leaves no room for secondary lines."
  (and window-rows (> window-rows 0) (< window-rows etaf-ncm-compact-rows)))

(defun etaf-ncm-layout-footer-rows-for (window-rows)
  "Return the footer rows kept in WINDOW-ROWS.
A short frame keeps the visible range and drops the loaded total."
  (if (etaf-ncm-layout-short-p window-rows)
      1
    etaf-ncm-layout-footer-rows))

(defun etaf-ncm-layout-list-top (layout)
  "Return the first row of the library page, counted from the window top.
It is the list panel's one-row top inset, the header and the chip strip."
  (+ 1
     (etaf-ncm-layout-header-rows layout)
     (etaf-ncm-layout-chips-rows-for layout)))

(defun etaf-ncm-layout-page-rows (layout window-rows)
  "Return the library rows one page holds in LAYOUT inside WINDOW-ROWS."
  (max etaf-ncm-layout-min-page-rows
       (- (or window-rows 0)
          (etaf-ncm-layout-list-top layout)
          (etaf-ncm-layout-footer-rows-for window-rows)
          (etaf-ncm-layout-tabs-rows layout)
          etaf-ncm-layout-bar-rows)))

(defun etaf-ncm-layout-aside-rows (layout window-rows)
  "Return the height of the side panel in LAYOUT inside WINDOW-ROWS.
The panel spans from the window top to the pane switch above the player bar."
  (max 1 (- (or window-rows 0)
            etaf-ncm-layout-bar-rows
            (etaf-ncm-layout-tabs-rows layout))))

(defun etaf-ncm-layout-queue-rows (layout window-rows)
  "Return the queue entries the side panel shows in WINDOW-ROWS.
The aside padding, the tabs with their border and the queue heading take
seven rows before the first entry."
  (max 0 (- (etaf-ncm-layout-aside-rows layout window-rows) 7)))

(defun etaf-ncm-layout-lyric-rows (layout window-rows)
  "Return the lyric lines the side panel shows in WINDOW-ROWS.
The cover, the spacer and the lyric footer take seven more rows than the
queue heading; translations share the same budget."
  (max 0 (- (etaf-ncm-layout-queue-rows layout window-rows) 7)))

;;; Horizontal plan

(defun etaf-ncm-layout-list-columns (layout columns)
  "Return the list pane's content width in COLUMNS for LAYOUT.
It matches what `etaf-ncm--view-list-panel' draws, minus its padding, so a
view can test whether a part fits without duplicating the panel geometry."
  (let* ((columns (or columns 0))
         (wide-p (eq layout 'wide)))
    (max 1 (- columns
              (if wide-p
                  (+ etaf-ncm-layout-sidebar-columns etaf-ncm-layout-aside-columns)
                (if (eq layout 'medium) etaf-ncm-layout-rail-columns 0))
              (if wide-p etaf-ncm-layout-panel-pad-columns 2)))))

(defun etaf-ncm-layout-subtitle-p (layout columns)
  "Return non-nil when LAYOUT at COLUMNS can show the header subtitle.
Wide shows it once the title column can hold the full line; a compact header
shares its first row with the actions, so it shows the subtitle from the
medium tier up."
  (if (eq layout 'wide)
      (>= (etaf-ncm-layout-list-columns layout columns)
          etaf-ncm-layout-wide-comfort-columns)
    (not (eq layout 'narrow))))

(defun etaf-ncm-layout-row-variant (layout columns)
  "Return the row variant LAYOUT renders at COLUMNS columns.
Wide keeps every column; compact layouts pick the widest variant whose fixed
columns plus the name minimum fit, so the name keeps its room."
  (if (eq layout 'wide)
      'full
    (let ((content (etaf-ncm-layout-list-columns layout columns)))
      (cond ((<= (etaf-ncm-layout-row-min-columns 'regular) content) 'regular)
            ((<= (etaf-ncm-layout-row-min-columns 'compact) content) 'compact)
            (t 'tiny)))))

(defun etaf-ncm-layout-chips (columns count)
  "Return the (WIDTH . GAP) for COUNT library chips inside COLUMNS.
The strip starts at its comfortable size, drops the gap and then narrows the
chips to the icon inset before a library could fall off the edge."
  (let ((options (list (cons etaf-ncm-layout-chip-columns 1)
                       (cons etaf-ncm-layout-chip-columns 0)
                       (cons etaf-ncm-layout-chip-min-columns 0))))
    (or (cl-find-if (lambda (option)
                      (<= (+ (* count (car option))
                             (* (1- count) (cdr option)))
                          (or columns 0)))
                    options)
        (cons etaf-ncm-layout-chip-min-columns 0))))

(provide 'etaf-ncm-layout)
;;; etaf-ncm-layout.el ends here
