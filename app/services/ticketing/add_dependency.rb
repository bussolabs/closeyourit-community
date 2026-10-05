# frozen_string_literal: true

module Ticketing
  # Aggiunge un prerequisito a un ticket (CYRA-82): `ticket` (A) DIPENDE da `blocker` (B), cioè B va
  # risolto prima di A. Gemello di Ticketing::ResolveDuplicate per la parte link+evento, ma qui la
  # relazione è direzionale e il grafo dei blocker resta aciclico (Connections::TicketDependency).
  #
  # Confine tenant/BOLA: il blocker si cerca SOLO tra i ticket visibili passati dal controller
  # (visible.tickets) — un id fuori scope (altra org, progetto non assegnato) non esiste, per
  # definizione, e torna 404. Il ticket A è già stato risolto nello stesso scope dal controller.
  # Mutazione + RecordActivity nella STESSA transazione (o si aggiunge e si logga, o niente): l'audit
  # non perde eventi. La topologia (self/cross-org/duplicato/ciclo) resta blindata dal model.
  class AddDependency < ApplicationService
    include DependencyBroadcasts

    def initialize(ticket:, blocker_id:, visible_tickets:, actor: nil, true_actor: nil)
      @ticket = ticket
      @blocker_id = blocker_id
      @visible_tickets = visible_tickets
      @actor = actor
      @true_actor = true_actor
    end

    def call
      forbidden = actor_forbidden
      return Result.err(forbidden) if forbidden

      blocker = @visible_tickets.find_by(id: @blocker_id)
      if blocker.nil?
        return Result.err(AppError.new(I18n.t("member.tickets.dependencies.errors.blocker_not_found"),
                                       code: "R404-TICKET-015", status: :not_found))
      end

      dependency = @ticket.dependencies.build(blocker: blocker, created_by: @actor)
      ApplicationRecord.transaction do
        dependency.save!
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            action: "dependency_added",
                            data: { code: blocker.code, title: blocker.title })
      end
      # Il ticket A può essere passato a "bloccato" (se il blocker è aperto): rinfresca la sua board.
      broadcast_dependency_board(@ticket)
      Result.ok(dependency)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotUnique
      # RecordInvalid = validazione normale (no_cycle, not_self, same_organization, uniqueness);
      # RecordNotSaved = throw :abort del before_create anti-ciclo sotto lock (race concorrente).
      # RecordNotUnique = due aggiunte CONCORRENTI dello stesso blocker: entrambe passano la validazione
      # applicativa uniqueness (nessuna vede ancora l'altra) e la seconda viola l'indice DB — senza
      # questo ramo propagherebbe come 500. La riga esiste comunque a fine corsa: è un 422 "già
      # associato", non un errore. RecordNotUnique NON popola `errors` (arriva dal DB) → validation_error
      # cade sul fallback invalid, che è la mappatura giusta per un duplicato.
      Result.err(validation_error(dependency))
    end

    private

      # CYRA-596 — prima di qualunque altra cosa, e prima di leggere il dato.
      #
      # Il discriminante e' l'ATTORE, non il canale: operatore e host usano lo STESSO canale CLI e lo
      # stesso tipo di token, quindi chiudere il canale chiuderebbe anche la persona.
      #
      # Sta PRIMA della ricerca di proposito. Rispondere «non trovato» a chi non aveva comunque il
      # diritto di chiedere direbbe la cosa sbagliata: farebbe credere che il problema sia il dato, e
      # cambierebbe risposta a seconda di che cosa esiste — cioe' racconterebbe a una macchina quali
      # prerequisiti ci sono sul ticket.
      def actor_forbidden
        return nil if @actor.present? && @actor.human?

        AppError.new(I18n.t("member.tickets.dependencies.errors.human_only"),
                     code: "R403-TICKET-001", status: :forbidden)
      end

    # Il ciclo ha messaggio e codice DEDICATI (la show lo rende come 422 sul form); ogni altra
    # violazione (self, cross-organizzazione, duplicato) cade su un unico errore di validazione.
    def validation_error(dependency)
      if dependency.errors.of_kind?(:base, :creates_cycle)
        return AppError.new(I18n.t("member.tickets.dependencies.errors.cycle"), code: "R422-TICKET-013")
      end

      AppError.new(I18n.t("member.tickets.dependencies.errors.invalid"), code: "R422-TICKET-017")
    end
  end
end
