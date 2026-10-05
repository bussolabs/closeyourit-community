# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Collegamenti ticket↔ticket (kind duplicate/related). index elenca i link che coinvolgono il
      # ticket (baseline: chi vede il ticket); destroy rimuove un link (gate `tickets.edit`, come il
      # canale Member). La CREAZIONE dei link nasce SOLO dal flusso dedup web (Ticketing::ResolveDuplicate,
      # pagina di confronto) → non esposta in CLI. Anti-BOLA: ticket dentro @project visibile; il link si
      # risolve tra quelli che coinvolgono il ticket (id estraneo → R404).
      class LinksController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def index
          links = Connections::TicketLink.involving(@ticket).includes(ticket: :project, related: :project).to_a
          # CYRA-789 — anti-BOLA in lettura (parità col web): l'altro capo di un collegamento può stare
          # in un progetto che chi chiama non vede — il gate duplicati collega cross-project di
          # proposito. Il Set dei visibili con UNA pluck, mai un check per riga.
          visible_ids = visible_tickets.where(id: links.flat_map { |link| [ link.ticket_id, link.related_id ] }.uniq)
                                       .pluck(:id).to_set
          render_ok(links.map { |link| link_payload(link, visible_ids) })
        end

        def destroy
          return unless require_permission!("tickets.edit", scope: @project)

          link = Connections::TicketLink.involving(@ticket).find(params[:id])
          link.destroy
          render_no_content
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # `id` è l'handle del DELETE e resta sempre: chi vede questo ticket può staccare il collegamento
        # anche quando l'altro capo gli è oscurato. Fuori scope spariscono TUTTI i riferimenti al ticket
        # riservato — l'uuid quanto il codice — e `hidden` dice al client che la riga è monca invece di
        # farlo ragionare su dei null. Il capo di QUESTO ticket resta al suo posto: è già noto a chi chiama.
        def link_payload(link, visible_ids)
          other = link.other_ticket(@ticket)
          visible = other.present? && visible_ids.include?(other.id)
          { id: link.id, kind: link.kind, hidden: !visible,
            ticket_id: side_id(link.ticket_id, visible), related_id: side_id(link.related_id, visible),
            other_ticket_id: visible ? other.id : nil, other_ticket_code: visible ? other.code : nil }
        end

        def side_id(id, visible)
          (visible || id == @ticket.id) ? id : nil
        end
      end
    end
  end
end
