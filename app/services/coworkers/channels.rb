module Coworkers
  # Sends a finished run back to the chat it came from, with the actions waiting for a decision
  # (CYRA-1018, CYRA-1019). The web conversation shows the same run.
  module Channels
    MAX_TEXT = 3500

    def self.answer(run)
      text = I18n.with_locale(run.requester.effective_locale) { answer_text(run) }
      case run.channel
      when "telegram" then Telegram::AnswerPuck.call(run: run, text: text)
      when "slack" then Coworkers::Slack.post(channel: run.channel_ref["channel"], thread_ts: run.channel_ref["thread_ts"], text: text)
      end
    end

    def self.answer_text(run)
      body = run.output.presence || I18n.t("member.coworkers.status.#{run.status}")
      pending = run.action_proposals.select(&:status_pending?)
      lines = [ "#{run.puck.name}: #{body.truncate(MAX_TEXT)}" ]
      lines << I18n.t("member.coworkers.channels.pending", count: pending.size) if pending.any?
      lines.join("\n\n")
    end
    private_class_method :answer_text
  end
end
