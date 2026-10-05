# frozen_string_literal: true

module Ticketing
  # Crea una riga di cronologia (Ticketing::Event). Va chiamato DENTRO la transazione del
  # service di mutazione: o muta+logga o niente (per un audit non si perdono eventi).
  # Snapshotta il nome attore (resiste alla cancellazione dell'account). actor/true_actor
  # opzionali (eventi senza attore identificato restano validi).
  #
  # Ritorna l'Event creato (NON un Result): è un helper interno chiamato dagli altri service,
  # non dal controller — non deve inquinare il loro Result pattern. Se `create!` solleva
  # (evento invalido = bug), l'eccezione propaga e la transazione del chiamante fa rollback.
  class RecordActivity < ApplicationService
    # CYRA-406 — `actor_name` senza account: alcune cose le fa un SISTEMA che non ha (né deve avere)
    # un account — la rietichettatura automatica dell'analisi, un webhook di GitHub. Prima quegli
    # eventi restavano senza autore e il riquadro di audit li presentava come una persona ignota,
    # proprio dove il prodotto promette di dire chi ha fatto cosa.
    # `organization`: l'organizzazione già in mano al chiamante. Serve a chi registra eventi IN CICLO
    # (più ticket collegati in un colpo): con il solo `organization_id` la validazione di presenza
    # dell'associazione fa una SELECT per evento — sempre la stessa riga, e il guard N+1 la ferma
    # alla seconda. Passandola risolta, la query si fa una volta e per tutti. Chi ne registra uno
    # solo la lascia stare e il comportamento è identico a prima.
    def initialize(ticket:, action:, data: {}, actor: nil, actor_name: nil, true_actor: nil,
                   organization: nil)
      @ticket = ticket
      @action = action
      @data = data
      @actor = actor
      @actor_name = actor_name
      @true_actor = true_actor
      @organization = organization
    end

    def call
      event = Ticketing::Event.create!(
        organization: @organization || @ticket.project.organization,
        ticket: @ticket,
        actor: @actor,
        true_actor: @true_actor,
        actor_name: @actor&.name.presence || @actor_name,
        action: @action,
        data: @data.deep_stringify_keys
      )
      broadcast_to_timeline(event)
      event
    end

    private

    # Append realtime dell'evento alla timeline del ticket. Choke point UNICO: RecordActivity è
    # chiamato da OGNI service di mutazione (ChangeStatus, AssignTicket, ChangeMilestone, DeleteComment,
    # UpdateTicket, CreateTicket…), quindi broadcastare qui fa apparire live in timeline ogni azione,
    # senza toccare i singoli service. Registrato come after-commit: RecordActivity gira DENTRO la
    # transazione del chiamante → il broadcast deve partire DOPO il commit (e MAI su rollback). Se non
    # c'è transazione aperta, `after_all_transactions_commit` esegue subito.
    def broadcast_to_timeline(event)
      ActiveRecord.after_all_transactions_commit do
        Turbo::StreamsChannel.broadcast_append_to(
          Realtime::Streams.ticket(@ticket),
          target: "ticket_timeline_#{@ticket.id}",
          partial: "member/tickets/event",
          locals: { event: event, ticket: @ticket, compact: true }
        )
      end
    end
  end
end
