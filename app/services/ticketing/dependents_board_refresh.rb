# frozen_string_literal: true

module Ticketing
  # Rinfresca le board dei progetti che ospitano i DEPENDENTS di uno o più ticket (CYRA-82): quando un
  # ticket cambia stato, il badge "bloccato" sulle card che dipendono da lui cade o si rialza, e quelle
  # card vivono sulla board del LORO progetto (cross-project intra-org ammesso).
  #
  # Accetta un LOTTO perché il percorso che conta è il blocco: Home::Approvals::BulkApprove accetta fino
  # a Queue::PAGE_LIMIT card in una richiesta, e una query per ticket dentro quel loop è un N+1 vero —
  # il guard Prosopite scatta già a due query identiche (spec/support/prosopite.rb). Con un lotto la
  # query resta UNA, qualunque sia il numero di card accettate.
  #
  # I progetti dei ticket passati sono ESCLUSI: le loro board le ha già rinfrescate
  # StatusBroadcasts#broadcast_status_change, una per ticket. Qui restano solo le board altrui.
  #
  #   Ticketing::DependentsBoardRefresh.call(tickets: ticket)   → Result<Integer>
  #   Ticketing::DependentsBoardRefresh.call(tickets: [t1, t2]) → Result<Integer>
  class DependentsBoardRefresh < ApplicationService
    def initialize(tickets:)
      @tickets = Array(tickets).compact
    end

    # Ritorna quante board sono state rinfrescate: zero è l'esito NORMALE, non un guasto — nella
    # stragrande maggioranza dei ticket nessuno dipende da loro e la query torna vuota.
    def call
      return Result.ok(0) if @tickets.empty?

      project_ids = dependent_project_ids - @tickets.map(&:project_id).uniq
      return Result.ok(0) if project_ids.empty?

      Projects::Project.where(id: project_ids).find_each do |project|
        Realtime::ThrottledRefresh.call(Realtime::Streams.project_board(project))
      end
      Result.ok(project_ids.size)
    end

    private

    # UNA query per l'intero lotto: le righe di dipendenza dove i nostri ticket sono il BLOCKER, unite
    # al ticket dipendente per leggerne il progetto. `distinct` sul progetto, così N dependents nello
    # stesso progetto valgono un refresh solo.
    def dependent_project_ids
      Connections::TicketDependency
        .where(blocker_id: @tickets.map(&:id))
        .joins(:ticket)
        .distinct
        .pluck("ticketing_tickets.project_id")
    end
  end
end
