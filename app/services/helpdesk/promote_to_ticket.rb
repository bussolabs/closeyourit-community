# frozen_string_literal: true

module Helpdesk
  # Turns a new request into a ticket of its project (CYRA-941). The reporter is who triages: the
  # visitor has no account. Same shape as Ideas::PromoteToTicket.
  class PromoteToTicket < ApplicationService
    def initialize(request:, reporter:, params:, true_actor: nil)
      @request = request
      @reporter = reporter
      @params = params
      @true_actor = true_actor
    end

    def call
      return already_handled unless @request.open?

      result = Ticketing::CreateTicket.call(
        organization: organization, reporter: @reporter, true_actor: @true_actor, params: ticket_params
      )
      @request.update!(ticket: result.value, status: :converted) if result.ok?
      result
    end

    private

    def organization = @request.project.organization

    def already_handled
      Result.err(AppError.new(I18n.t("member.helpdesk.errors.already_handled"), code: "R422-HELPDESK-002"))
    end

    def ticket_params
      {
        project_id: @request.project_id,
        title: @params[:title].presence || @request.summary,
        description: @params[:description],
        kind: @params[:kind].presence || :bug,
        status_id: @params[:status_id].presence || Ticketing::FormOptions.default_status_id(organization),
        priority_id: @params[:priority_id].presence || Ticketing::FormOptions.default_priority_id(organization)
      }
    end
  end
end
