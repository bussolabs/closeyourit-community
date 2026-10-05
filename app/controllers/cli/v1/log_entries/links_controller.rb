# frozen_string_literal: true

module Cli
  module V1
    module LogEntries
      # Collegamenti manuali log↔errore/ticket (oltre alla correlazione automatica per trace_id), via CLI.
      # Gated dalla chiave scoped `logs.link` sul progetto del log; anti-BOLA: il log si risolve nello scope
      # visibile (non visibile → R404). Logica nei service Logs::Links::{Attach,Detach} condivisi col canale
      # Member (`rules/backend-channels.md`). param `linkable` = "Errors::Group:<uuid>" | "Ticketing::Ticket:<uuid>".
      class LinksController < Cli::V1::BaseController
        before_action :set_entry
        before_action -> { require_permission!("logs.link", scope: @entry.project) }

        def create
          linkable = resolve_linkable
          return render_error("R422-LOG-003", "Target non collegabile", status: :unprocessable_content) if linkable.nil?

          result = Logs::Links::Attach.call(log_entry: @entry, linkable: linkable, actor: Current.account)
          if result.ok?
            render_created(link_payload(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          link = @entry.links.find(params[:id])
          Logs::Links::Detach.call(log_entry: @entry, linkable: link.linkable)
          render_no_content
        end

        private

        # Anti-BOLA: log risolto tra i progetti visibili → un log non visibile/di altra org → R404.
        def set_entry
          @entry = Logs::Entry.where(project_id: visible_projects.select(:id)).find(params[:log_entry_id])
        end

        # rpartition sull'ULTIMO ":" (il type contiene "::"). Solo i tipi ammessi e SOLO nel progetto del
        # log (anti-BOLA); l'Attach ri-valida il confine di tenant sul model.
        def resolve_linkable
          type, _, id = params[:linkable].to_s.rpartition(":")
          return nil unless Logs::Link::LINKABLE_TYPES.include?(type)

          type.constantize.where(project_id: @entry.project_id).find_by(id: id)
        end

        def link_payload(link)
          { id: link.id, log_entry_id: @entry.id,
            linkable_type: link.linkable_type, linkable_id: link.linkable_id }
        end
      end
    end
  end
end
