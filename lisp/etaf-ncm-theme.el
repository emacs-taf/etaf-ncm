;;; etaf-ncm-theme.el --- Palette and ETAF UI theme for etaf-ncm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The player renders its own dark surface instead of borrowing the user's
;; Emacs theme, so it looks the same in every session.  `etaf-ncm-color' is
;; the palette lookup used by the Views; `etaf-ncm-theme-defaults' projects the
;; same palette onto the ETAF UI token contract consumed by etaf-ui Components
;; (buttons, badges, text inputs).

;;; Code:

(require 'etaf)

(defgroup etaf-ncm nil
  "NetEase Cloud Music player built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-ncm--palettes
  '((dark :bg "#0E1013" :panel "#15181D" :panel2 "#1B1F26" :panel3 "#232832"
          :line "#262B34" :ink "#E9ECF1" :muted "#98A0AC" :dim "#6A727E"
          :accent "#EC4141" :accent-soft "#2A1619" :gold "#E8B45C" :ok "#4FB477"
          :warn "#E8B45C" :danger "#FF7A7A" :info "#6FB4E8")
    (light :bg "#FFFFFF" :panel "#F6F7F9" :panel2 "#EFF1F4" :panel3 "#E4E7EB"
           :line "#E1E4E9" :ink "#1B1F24" :muted "#5C6470" :dim "#8A919C"
           :accent "#D8232A" :accent-soft "#FBE9EA" :gold "#B07A16" :ok "#2E7D4F"
           :warn "#B07A16" :danger "#C0392B" :info "#2C6FA8"))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-ncm-theme-mode 'dark
  "Appearance used by a new player.
`dark' (default) renders the player's own dark surface; `light' uses the
light palette.  This is independent of the active Emacs theme."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-ncm)

(defun etaf-ncm-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to `etaf-ncm-theme-mode'.  An unknown KEY signals
`etaf-ncm-error' instead of returning a fallback, because a typo would
otherwise paint an invisible surface."
  (let* ((mode (if (eq (or mode etaf-ncm-theme-mode) 'light) 'light 'dark))
         (palette (cdr (assq mode etaf-ncm--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-ncm-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-ncm-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
MODE defaults to `etaf-ncm-theme-mode'.  The result is passed to
`etaf-theme-provide' by the application so shared etaf-ui Components use the
same colors as the player's own Views."
  (let* ((dark (not (eq (or mode etaf-ncm-theme-mode) 'light)))
         (bg (etaf-ncm-color :bg mode))
         (panel (etaf-ncm-color :panel mode))
         (panel3 (etaf-ncm-color :panel3 mode))
         (ink (etaf-ncm-color :ink mode))
         (line (etaf-ncm-color :line mode))
         (muted (etaf-ncm-color :muted mode))
         (accent (etaf-ncm-color :accent mode))
         (accent-soft (etaf-ncm-color :accent-soft mode))
         (ok (etaf-ncm-color :ok mode))
         (ok-bg (if dark "#17301F" "#E3F3E8"))
         (ok-border (if dark "#2E5C3F" "#A9D8BB"))
         (danger (etaf-ncm-color :danger mode))
         (danger-bg (if dark "#3A1D22" "#FBE4E2"))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-ncm-color :warn mode))
         (warn-bg (if dark "#33280F" "#FBF0DA"))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info (etaf-ncm-color :info mode))
         (info-bg (if dark "#14232F" "#E4F0FA"))
         (info-border (if dark "#2C4E66" "#A8CBE6")))
    (list
     :ink ink :paper bg :panel panel :line line :muted muted
     :accent accent :accent-soft accent-soft
     :ui-fg ink :ui-bg bg :ui-border line :ui-muted-fg muted
     :ui-disabled-fg muted :ui-disabled-bg panel :ui-disabled-border line
     :ui-accent accent :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg accent-soft
     :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg accent
     :ui-button-secondary-fg accent :ui-button-secondary-bg accent-soft
     :ui-button-ghost-fg muted
     :ui-success-fg ok :ui-success-bg ok-bg :ui-success-border ok-border
     :ui-danger-fg danger :ui-danger-bg danger-bg :ui-danger-border danger-border
     :ui-warning-fg warn :ui-warning-bg warn-bg :ui-warning-border warn-border
     :ui-info-fg info :ui-info-bg info-bg :ui-info-border info-border
     :ui-panel-fg ink :ui-panel-bg panel :ui-panel-border line
     :ui-divider-bg line :ui-progress-track panel3
     :ui-table-border line :ui-table-selected-fg accent
     :ui-table-selected-bg accent-soft
     :ui-shell-bg panel :ui-shell-fg ink :ui-shell-muted-fg muted
     :ui-shell-item-fg muted :ui-shell-item-minimized-fg muted
     :ui-window-bg bg :ui-window-fg ink :ui-window-border line
     :ui-window-title-bg panel :ui-window-title-fg muted
     :ui-window-title-active-fg ink
     :ui-picker-item-bg panel :ui-picker-item-fg ink
     :ui-picker-item-muted-fg muted
     :ui-pagination-muted-fg muted
     :ui-data-grid-error-fg danger
     :ui-checkbox-enabled-fg ink :ui-checkbox-disabled-fg muted)))

(provide 'etaf-ncm-theme)
;;; etaf-ncm-theme.el ends here
