# frozen_string_literal: true

module Alerting
  # What an alert looks like in Slack: the alert, what people did from it and, while it is open, the
  # three buttons. Built from the stored message, so every refresh shows the latest state. CYRA-1156
  class SlackCard
    def initialize(message)
      @message = message
    end

    def text = @message.title.to_s

    def blocks
      I18n.with_locale(I18n.default_locale) do
        [ summary, status, (actions if @message.status_open?) ].compact
      end
    end

    private

    def summary
      lines = [ "*#{escape(@message.title)}*", escape(@message.body).presence,
                ("<#{absolute(@message.url)}|#{t('open_alert')}>" if @message.url.present?) ]
      { type: "section", text: { type: "mrkdwn", text: lines.compact.join("\n").first(2900) } }
    end

    def status
      lines = [ recovered_line, claimed_line, muted_line, ticket_line ].compact
      return nil if lines.empty?

      { type: "context", elements: lines.map { |line| { type: "mrkdwn", text: line } } }
    end

    def recovered_line
      t("recovered", time: time(@message.recovered_at)) if @message.status_recovered?
    end

    def claimed_line
      t("claimed", name: escape(@message.claimed_by.name)) if @message.claimed_by
    end

    # The whole rule is silenced, not this alert alone: the line says which rule and until when.
    def muted_line
      return nil unless @message.muted_until && @message.muted_by

      t("muted", name: escape(@message.muted_by.name), rule: escape(@message.rule&.name || @message.title),
                 time: time(@message.muted_until))
    end

    def ticket_line
      ticket = @message.ticket
      return nil if ticket.nil?

      link = "<#{absolute(routes.member_ticket_path(ticket))}|#{escape(ticket.code)}>"
      t("ticket", code: link, name: escape(@message.ticket_opened_by&.name.to_s))
    end

    def actions
      { type: "actions", block_id: "alert_actions",
        elements: [ button("alert_claim", t("claim"), style: "primary"), button("alert_mute", t("mute")), third_button ] }
    end

    # «Open ticket» where the alert can become one; the ticket once it exists; otherwise the alert's page.
    def third_button
      ticket = @message.ticket
      return link_button("alert_open_ticket", t("view_ticket", code: ticket.code), routes.member_ticket_path(ticket)) if ticket
      return button("alert_ticket", t("ticket_button")) if SlackTickets.supported?(@message.subject_type)

      link_button("alert_open", t("open_page"), @message.url.presence || "/")
    end

    def button(action_id, label, style: nil)
      { type: "button", action_id: action_id, text: { type: "plain_text", text: label }, style: style }.compact
    end

    def link_button(action_id, label, path)
      { type: "button", action_id: action_id, text: { type: "plain_text", text: label }, url: absolute(path) }
    end

    # Slack shows the time in the reader's own time zone; the fallback is ours.
    def time(at)
      "<!date^#{at.to_i}^{date_short_pretty} {time}|#{I18n.l(at, format: :short)}>"
    end

    def absolute(path) = path.to_s.start_with?("http") ? path.to_s : "#{App::Host.base_url}#{path}"

    def escape(value) = value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

    def t(key, **options) = I18n.t("alerting.slack.card.#{key}", **options)

    def routes = Rails.application.routes.url_helpers
  end
end
