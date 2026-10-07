# frozen_string_literal: true

module Telegram
  # A tap on Confirm or Discard under a Puck's answer (CYRA-1018). Same checks as the web: only the
  # person the proposal belongs to, inside the run's scope.
  class ConfirmPuckAction < ApplicationService
    include Telegram::Respondable
    DATA = /\Acwp:([cd]):([0-9a-f-]{36})\z/

    def initialize(callback:)
      @callback = callback
      @chat_id = callback.dig(:message, :chat, :id)
    end

    def call
      match = @callback[:data].to_s.match(DATA)
      @account = Accounts::Account.find_by(telegram_chat_id: @chat_id.to_s)
      return answer(nil) && Result.ok(:ignored) if match.nil? || @account.nil?

      proposal = Assistant::Proposal.where(account_id: @account.id).where.not(coworkers_run_id: nil).find_by(id: match[2])
      return answer(t("puck.action_gone")) && Result.ok(:gone) if proposal.nil? || !proposal.confirmable?

      match[1] == "c" ? confirm(proposal) : discard(proposal)
    end

    private

    def confirm(proposal)
      outcome = Assistant::Proposals::Confirm.call(proposal: proposal, account: @account, organization: proposal.organization,
                                                   allowed_project_ids: Coworkers::Scope.snapshot(proposal.coworkers_run).project_ids)
      answer(outcome.ok? ? t("puck.confirmed") : outcome.error.message)
      outcome.ok? ? Result.ok(:confirmed) : outcome
    end

    def discard(proposal)
      proposal.update!(status: :discarded)
      answer(t("puck.discarded"))
      Result.ok(:discarded)
    end

    def answer(text)
      Telegram::Send.api_post("answerCallbackQuery", callback_query_id: @callback[:id], text: text)
      true
    rescue StandardError => e
      Rails.logger.warn("Telegram callback answer failed: #{e.class}")
      true
    end
  end
end
