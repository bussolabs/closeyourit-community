module Coworkers
  # A direct message or a mention of the Puckies' Slack app (CYRA-1019). Unlinked people get the way to
  # link; linked ones ask the Puck they last used, or the one named first ("Writer: ...").
  class SlackEventJob < ApplicationJob
    queue_as :default
    HANDLED = %w[app_mention message].freeze

    def perform(payload)
      event = payload["event"] || {}
      return unless HANDLED.include?(event["type"]) && event["bot_id"].nil? && event["subtype"].nil?
      return unless Rails.cache.write("coworkers:slack:#{payload['event_id']}", true, unless_exist: true, expires_in: 1.hour)

      text = event["text"].to_s.gsub(/<@[A-Z0-9]+>/, "").strip
      return link(payload["team_id"], event, text) if text.match?(/\Alink\s+\S+\z/i) && event["channel_type"] == "im"

      link = SlackLink.find_by(slack_team_id: payload["team_id"], slack_user_id: event["user"])
      return reply(event, I18n.t("member.coworkers.slack.link_first")) if link.nil?

      ask(link, event, text)
    end

    private

    # Only in a private message, and each code works once: nobody else can reuse it (Codex review).
    def link(team_id, event, text)
      code = text.split(/\s+/, 2).last
      account_id, organization_id = Slack.read_link_code(code)
      fresh = account_id && Rails.cache.write("coworkers:slack-link:#{Digest::SHA256.hexdigest(code)}", true, unless_exist: true, expires_in: 1.hour)
      return reply(event, I18n.t("member.coworkers.slack.link_invalid")) unless fresh

      SlackLink.find_or_initialize_by(slack_team_id: team_id, slack_user_id: event["user"])
               .update!(account_id: account_id, organization_id: organization_id)
      reply(event, I18n.t("member.coworkers.slack.linked"))
    end

    # The link outlives the membership: someone who left keeps it, so membership is checked on every message.
    def ask(link, event, text)
      member = Connections::Membership.exists?(account_id: link.account_id, organization_id: link.organization_id)
      return reply(event, I18n.t("member.coworkers.slack.unavailable")) unless member && Coworkers.available_to?(account: link.account, organization: link.organization)

      puckies = Authorization::VisibleScope.new(account: link.account, organization: link.organization).coworker_puckies.order(:name).to_a
      named = puckies.find { |puck| text.downcase.start_with?("#{puck.name.downcase}:") }
      puck = named || puckies.find { |candidate| candidate.id == link.puck_id } || puckies.first
      return reply(event, I18n.t("member.coworkers.slack.no_puck")) if puck.nil?

      link.update!(puck: puck)
      start(link, puck, event, named ? text.split(":", 2).last.strip : text)
    end

    def start(link, puck, event, text)
      thread_ts = event["thread_ts"] || event["ts"]
      context = event["thread_ts"] ? Slack.thread_text(channel: event["channel"], thread_ts: thread_ts) : ""
      input = context.present? ? "#{text}\n\nSlack thread:\n#{context}" : text
      Start.call(puck: puck, kind: "chat", input: input.first(8000), account: link.account,
                 channel: "slack", channel_ref: { "channel" => event["channel"], "thread_ts" => thread_ts })
    rescue Start::Busy, Start::OverBudget
      reply(event, I18n.t("member.coworkers.slack.busy"))
    end

    def reply(event, text) = Slack.post(channel: event["channel"], thread_ts: event["thread_ts"] || event["ts"], text: text)
  end
end
