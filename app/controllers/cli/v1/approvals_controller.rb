# frozen_string_literal: true

module Cli
  module V1
    # The approvals queue from the terminal (`cyi approvals`, CYRA-1184): list, read one card, decide,
    # defer to tomorrow. No logic of its own: the same Queue, Detail, Decide and Defer services as the
    # web page. A card that is not mine, or already decided, is 404 (Detail resolves it from the
    # visible scopes, anti-BOLA); each decision is authorized by its own domain service.
    class ApprovalsController < Cli::V1::BaseController
      before_action :set_card, only: %i[show defer]

      def index
        batch = ::Home::Approvals::Queue.call(**scope_args, state: params[:state], project: params[:project],
                                                            agent: params[:agent_id],
                                                            limit: Member::Home::ApprovalsController::BOARD_LIMIT)
        deferrals = live_deferrals
        render_ok(ApprovalRowSerializer.new(batch.items, params: { deferrals: deferrals }).serializable_hash,
                  meta: { total: batch.total, totals: batch.totals, deferred_count: deferrals.size })
      end

      def show
        render_ok(ApprovalCardSerializer.new(@card).serializable_hash)
      end

      def decide
        result = ::Home::Approvals::Decide.call(**scope_args, key: card_key, decision: params[:decision],
                                                              text: decision_text, true_actor: Current.account)
        return render_result_error(result) if result.err?

        render_ok({ key: card_key, decision: params[:decision].to_s })
      end

      def defer
        result = ::Home::Deferrals::Defer.call(account: Current.account, organization: Current.organization,
                                               card_key: @card.key)
        return render_result_error(result) if result.err?

        render_ok({ key: @card.key, until_at: result.value.until_at })
      end

      private

      def set_card
        @card = ::Home::Approvals::Detail.call(**scope_args, key: card_key)
        raise ActiveRecord::RecordNotFound if @card.nil?
      end

      def card_key = "#{params[:kind]}:#{params[:id]}"

      # Same composition as the web panel: picked proposed answers first, one line per question, then
      # the free text.
      def decision_text
        answers = params[:answers].respond_to?(:to_unsafe_h) ? params[:answers].to_unsafe_h : {}
        lines = answers.slice("1", "2", "3").sort.filter_map do |position, answer|
          "#{position}. #{answer.to_s.strip}" if answer.to_s.strip.present?
        end
        [ *lines, params[:text].to_s.strip.presence ].compact.join("\n")
      end

      def live_deferrals
        ::Home::Deferral.live.where(account_id: Current.account.id, organization_id: Current.organization.id)
                        .pluck(:card_key, :until_at).to_h
      end

      def render_result_error(result)
        render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
      end

      def scope_args
        { account: Current.account, organization: Current.organization,
          visible_projects: visible_projects, visible_tickets: visible_tickets }
      end
    end
  end
end
