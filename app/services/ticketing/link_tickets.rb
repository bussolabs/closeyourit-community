# frozen_string_literal: true

module Ticketing
  # Scrive N collegamenti fra un ticket e altri ticket, con la cronologia su entrambi i capi
  # (CYRA-633). È l'unico posto che crea una Connections::TicketLink: ci arrivano il pannello del
  # form (dove si spuntano i simili), la pagina di confronto dei duplicati e il collegamento
  # automatico al ticket che ha suggerito questo. Prima erano tre copie della stessa transazione, e
  # solo una delle tre registrava gli eventi.
  #
  # Il perimetro NON è suo: i bersagli arrivano già risolti e già ristretti dal chiamante. Deve
  # essere così perché le regole divergono — il pannello propone solo lo stesso progetto, mentre il
  # collegamento a un ticket-sorgente attraversa i progetti di proposito. L'invariante di tenant
  # resta comunque presidiata dal model (`same_organization`), che qui fa da difesa in profondità.
  #
  # Fail-soft, per una ragione sola: si chiama subito DOPO che il ticket è stato creato. Un bersaglio
  # cancellato o rifiutato dalle validazioni nel frattempo farebbe perdere un ticket appena scritto
  # per colpa di un ticket di qualcun altro. Chi non entra viene saltato e loggato; il chiamante
  # legge dai collegamenti riusciti cosa dire a chi ha premuto il pulsante.
  class LinkTickets < ApplicationService
    def initialize(ticket:, targets:, kind:, actor:, true_actor: nil)
      @ticket = ticket
      @targets = Array(targets)
      @kind = kind
      @actor = actor
      @true_actor = true_actor
    end

    def call
      linked = []
      ApplicationRecord.transaction do
        @targets.each do |target|
          next if skip?(target)

          linked << target if link(target)
        end
      end
      Result.ok(linked)
    end

    private

    def skip?(target)
      target.nil? || target.id == @ticket.id || already_linked.include?(target.id)
    end

    # Gli id già collegati, chiesti UNA volta per tutto il lotto. La coppia è direzionale
    # nell'indice unico, ma un collegamento è un collegamento: se esiste in un verso o nell'altro,
    # rifarlo produrrebbe una riga gemella che la pagina mostrerebbe due volte.
    def already_linked
      @already_linked ||= begin
        ids = @targets.compact.map(&:id)
        rows = Connections::TicketLink
               .where(ticket_id: @ticket.id, related_id: ids)
               .or(Connections::TicketLink.where(ticket_id: ids, related_id: @ticket.id))
               .pluck(:ticket_id, :related_id)
        rows.flatten.to_set - [ @ticket.id ]
      end
    end

    # Savepoint per bersaglio (`requires_new`), non per eleganza: fra la lettura e la scrittura il
    # bersaglio può sparire davvero — qualcuno lo cancella mentre l'altro sta spuntando — e allora
    # non è una validazione a fallire ma il vincolo del database, che ABORTA la transazione. Senza
    # savepoint, un ticket cancellato da un altro finirebbe in un 500 con il ticket nuovo già
    # scritto: il caso esatto che il fail-soft deve coprire. `RecordNotUnique` è il gemello: due
    # salvataggi contemporanei sulla stessa coppia.
    def link(target)
      ApplicationRecord.transaction(requires_new: true) do
        record = Connections::TicketLink.new(ticket: @ticket, related: target, kind: @kind,
                                             created_by: @actor)
        unless record.save
          warn_skipped(target, record.errors.full_messages.to_sentence)
          raise ActiveRecord::Rollback
        end

        record_events(target)
        return true
      end
      false
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique => e
      warn_skipped(target, e.class.name)
      false
    end

    def warn_skipped(target, reason)
      Rails.logger.warn("LinkTickets: collegamento non scritto (#{target.id}): #{reason}")
    end

    # L'organizzazione è la stessa per tutti e due i capi di ogni collegamento (lo garantisce la
    # validazione del model, che ha già rifiutato le coppie cross-tenant): si risolve una volta e
    # serve tutti gli eventi del lotto.
    # `ticket` è lo snapshot umano (il codice, come per le dipendenze); `ticket_id` è il riferimento
    # STABILE al capo citato, e serve a decidere se chi legge la riga può conoscerlo (CYRA-789). Il
    # codice non basta: la chiave di progetto si rinomina, e può perfino essere riassegnata a un altro
    # progetto — un permesso deciso su quella stringa cambierebbe padrone insieme all'etichetta.
    def record_events(target)
      RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                          action: "linked", data: { ticket: target.code, ticket_id: target.id, kind: @kind },
                          organization: organization)
      RecordActivity.call(ticket: target, actor: @actor, true_actor: @true_actor,
                          action: "linked", data: { ticket: @ticket.code, ticket_id: @ticket.id, kind: @kind },
                          organization: organization)
    end

    def organization
      @organization ||= @ticket.project.organization
    end
  end
end
