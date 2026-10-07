# frozen_string_literal: true

module Telegram
  # The bot answering a /p question: the Puck's reply and one row of buttons per action waiting for
  # a decision (CYRA-1018). Not a notification: there is no row to mark as sent.
  class AnswerPuck < ApplicationService
    def initialize(run:, text:)
      @run = run
      @text = text
    end

    def call
      Telegram::Send.call(chat_id: @run.channel_ref["chat_id"], text: @text, reply_markup: buttons)
    end

    private

    def buttons
      rows = @run.action_proposals.select(&:status_pending?).first(5).map do |proposal|
        label = "#{I18n.t("member.assistant.proposals.kinds.#{proposal.kind}")}: #{proposal.payload['title'] || proposal.payload['ticket_code']}".truncate(40)
        [ { text: "✅ #{label}", callback_data: "cwp:c:#{proposal.id}" }, { text: "✖", callback_data: "cwp:d:#{proposal.id}" } ]
      end
      rows.any? ? { inline_keyboard: rows } : nil
    end
  end
end
