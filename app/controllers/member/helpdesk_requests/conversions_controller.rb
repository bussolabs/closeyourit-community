# frozen_string_literal: true

module Member
  module HelpdeskRequests
    # Request → ticket with an editable draft (CYRA-941): `new` shows the form filled with what the
    # visitor wrote, `create` promotes through Helpdesk::PromoteToTicket. No AI involved: it works
    # on every installation.
    class ConversionsController < Member::BaseController
      include Member::HelpdeskAccess

      before_action :set_helpdesk_request
      before_action :require_new_request

      def new
        load_form_options
        @draft_title = @request_record.summary
        @draft_description = draft_description
      end

      def create
        result = ::Helpdesk::PromoteToTicket.call(
          request: @request_record, reporter: Current.account, true_actor: Current.true_account,
          params: conversion_params
        )
        if result.ok?
          redirect_to member_ticket_path(result.value), notice: t("member.helpdesk.converted")
        else
          load_form_options
          @draft_title = conversion_params[:title].presence || @request_record.summary
          @draft_description = conversion_params[:description]
          @errors = result.error.details || {}
          flash.now[:alert] = result.error.message
          render :new, status: :unprocessable_content
        end
      end

      private

      def require_new_request
        return if @request_record.open?

        redirect_to member_helpdesk_request_path(@request_record), alert: t("member.helpdesk.errors.already_handled")
      end

      def load_form_options
        @statuses = Current.organization.ticket_statuses.active.ordered
        @priorities = Current.organization.ticket_priorities.active.ordered
        # A visitor writes when something does not work: the draft starts as a bug.
        @kinds = %w[bug story task]
        @default_status_id = ::Ticketing::FormOptions.default_status_id(Current.organization)
        @default_priority_id = ::Ticketing::FormOptions.default_priority_id(Current.organization)
      end

      def conversion_params
        params.permit(:title, :description, :kind, :status_id, :priority_id)
      end

      # The visitor's words and where they wrote from. Never the address: a ticket is read by people
      # without the help desk key.
      def draft_description
        parts = [ @request_record.messages.first&.body ]
        parts << "#{t('member.helpdesk.page')}: #{@request_record.page_url}" if @request_record.page_url.present?
        parts.compact.join("\n\n")
      end
    end
  end
end
