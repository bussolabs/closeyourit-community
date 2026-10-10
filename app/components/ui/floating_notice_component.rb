# frozen_string_literal: true

module Ui
  # A message that matters but belongs to no panel: it floats over the bottom of the content frame in
  # its own panel, with a title saying what it is, and the person can close it for good (saved on the
  # account through Member::DismissedNoticesController). Never loose text in the content (DESIGN.md T1).
  # Render it inside `content_for :floating_notice`: the layout stacks it (shared/_floating_notices).
  # `lifted:` raises the stack over a page's sticky bottom bar. Member pages only: elsewhere it does not render.
  class FloatingNoticeComponent < BaseComponent
    # Every notice key matches one of these: the endpoint refuses any other. A project's next steps
    # carry the project and the steps shown, so a step the person has not seen brings the notice back;
    # the same incident carries how many other projects share the title, so one more brings it back.
    # `release:` is the release the person last opened from the footer (Ui::ChangelogComponent).
    KEY_FORMATS = [
      /\Aalerting_hierarchy\z/,
      /\Amembers_roles\z/,
      /\Aplatforms_intro\z/,
      /\Avault_(delegation|variables_help)\z/,
      /\Aservers_todo:[a-z0-9_,]{1,200}\z/,
      /\Acoverage_(uptime|crons):(covered|uncovered-\d{1,6})\z/,
      /\Arelease:v?[\w.-]{1,40}\z/,
      /\Aticket_review:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/,
      /\Asame_incident:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}:\d{1,4}\z/,
      /\Aproject_next_steps:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}:[a-z0-9,-]{1,200}\z/
    ].freeze

    def self.valid_key?(key) = KEY_FORMATS.any? { |format| format.match?(key.to_s) }

    # `tone:` says what kind of message it is: `:info` explains, `:warning` asks to fix something,
    # `:success` confirms all is well.
    # Literal classes: the Tailwind scanner does not see interpolated ones.
    TONES = {
      info: { box: "border-indigo-200 dark:border-indigo-500/40 bg-indigo-50 dark:bg-indigo-500/15 dark:bg-indigo-950", icon: "info", accent: "text-indigo-600 dark:text-indigo-400" },
      warning: { box: "border-amber-300 dark:border-amber-500/50 bg-amber-50 dark:bg-amber-500/15 dark:bg-amber-950", icon: "triangle-alert", accent: "text-amber-700 dark:text-amber-300" },
      success: { box: "border-emerald-200 dark:border-emerald-500/40 bg-emerald-50 dark:bg-emerald-500/15 dark:bg-emerald-950", icon: "circle-check", accent: "text-emerald-700 dark:text-emerald-300" }
    }.freeze

    def initialize(key:, title:, tone: :info, lifted: false, test_id: nil, **options)
      @tone = TONES.fetch(tone)
      @key = key.to_s
      @title = title
      @lifted = lifted
      @test_id = test_id
      @options = options

      raise ArgumentError, "unknown notice: #{@key}" unless self.class.valid_key?(@key)
    end

    def render?
      helpers.respond_to?(:notice_dismissed?) && !helpers.notice_dismissed?(@key)
    end

    private

    def html_options
      base = "pointer-events-auto flex items-start gap-3 rounded-lg border #{@tone[:box]} px-4 py-3"
      merge_options(base_class: base, test_id: @test_id, options: @options).tap do |opts|
        opts[:role] = "status"
        opts[:data] = (opts[:data] || {}).merge(controller: "ui--floating-notice", lifted: (true if @lifted),
                                                ui__floating_notice_url_value: helpers.member_dismissed_notices_path,
                                                ui__floating_notice_key_value: @key)
      end
    end

    def tone = @tone

    def dismiss_test_id
      @test_id ? "#{@test_id}-dismiss" : "floating-notice-dismiss"
    end
  end
end
