# frozen_string_literal: true

module Member
  module Ideas
    # Conversione idea → ticket con preview editabile: `new` mostra il form (prefill AI via
    # Stimulus idea-convert + fallback titolo/corpo dell'idea), `create` promuove via
    # Ideas::PromoteToTicket. Converte l'autore (sempre) o chi ha ideas.convert sul progetto.
    class ConversionsController < Member::BaseController
      before_action :set_idea
      before_action :require_convert_permission
      before_action :require_open_idea

      def new
        load_form_options
        @draft_title = @idea.title
        @draft_description = draft_description
      end

      def create
        result = ::Ideas::PromoteToTicket.call(
          idea: @idea, reporter: Current.account, true_actor: Current.true_account,
          params: conversion_params
        )
        if result.ok?
          redirect_to member_ticket_path(result.value), notice: t("member.ideas.converted")
        else
          load_form_options
          @draft_title = conversion_params[:title].presence || @idea.title
          @draft_description = conversion_params[:description]
          @errors = result.error.details || {}
          flash.now[:alert] = result.error.message
          render :new, status: :unprocessable_content
        end
      end

      private

      def set_idea
        @idea = visible.ideas.find(params[:idea_id])
      end

      def require_convert_permission
        note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
        return if @idea.authored_by?(Current.account)

        require_permission!("ideas.convert", scope: @idea.project)
      end

      # Congelata (già convertita o archiviata) → la show mostra lo stato; niente form.
      def require_open_idea
        return if @idea.status_open?

        alert_key = @idea.status_converted? ? "already_converted" : "locked"
        redirect_to member_idea_path(@idea), alert: t("ideas.errors.#{alert_key}")
      end

      def load_form_options
        @statuses = Current.organization.ticket_statuses.active.ordered
        @priorities = Current.organization.ticket_priorities.active.ordered
        # Un'idea che diventa ticket nasce story per default: è una richiesta di valore, non un guasto.
        @kinds = %w[story task bug epic]
        @default_kind = @kinds.first
        @default_status_id = (@statuses.find { |s| s.code == "open" } || @statuses.first)&.id
        @default_priority_id = (@priorities.find { |p| p.code == "medium" } || @priorities.first)&.id
      end

      def conversion_params
        params.permit(:title, :description, :kind, :status_id, :priority_id)
      end

      # Fallback (senza JS/AI): descrizione ticket = problema + soluzione dell'idea.
      def draft_description
        parts = [ @idea.problem ]
        parts << "## Soluzione proposta\n#{@idea.solution}" if @idea.solution.present?
        parts.join("\n\n")
      end
    end
  end
end
