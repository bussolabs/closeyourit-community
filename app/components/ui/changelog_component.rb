# frozen_string_literal: true

module Ui
  # Footer della sidebar: trigger con la versione del sistema (dato grezzo, mono) che apre un
  # <dialog> nativo col changelog delle release più recenti + link allo storico completo.
  # Riusa il pattern Stimulus `ui--dialog` (focus-trap/Esc/backdrop nativi).
  class ChangelogComponent < BaseComponent
    # From md up the version sits in the page footer and opens the dialog. The footer is desktop-only,
    # so on phones the sidebar drawer keeps a plain link to the changelog page: one dialog per page.
    PLACEMENTS = %i[footer sidebar].freeze

    # The key a seen release is saved under, next to the dismissed notices (Member::DismissedNoticesController).
    def self.seen_key(release) = "release:#{release.label}"

    # `unseen:` — the person has not opened the current release yet: the trigger carries a signal, and
    # its first click saves the release as seen.
    def initialize(current: Changelog.current,
                   releases: Changelog.recent(Changelog::Constants::MODAL_RELEASES), placement: :footer, unseen: false)
      @current = current
      @releases = releases
      @placement = PLACEMENTS.include?(placement) ? placement : :footer
      @unseen = unseen && current.present?
    end

    private

    def sidebar? = @placement == :sidebar

    def unseen? = @unseen

    def wrapper_data
      return { controller: "ui--dialog" } unless unseen?

      { controller: "ui--dialog ui--seen-signal",
        "ui--seen-signal-url-value": helpers.member_dismissed_notices_path,
        "ui--seen-signal-key-value": self.class.seen_key(@current) }
    end

    def trigger_action = unseen? ? "ui--dialog#open ui--seen-signal#mark" : "ui--dialog#open"

    def version_label
      @current ? @current.label : t("shared.changelog.unknown")
    end
  end
end
