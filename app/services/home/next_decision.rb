# frozen_string_literal: true

module Home
  # La prossima decisione da mettere davanti a questo account: la più vecchia della coda, saltando
  # quelle rimandate a domani e quelle messe da parte in questa sessione (CYRA-655).
  #
  # NON è una coda nuova: è un modo di leggere Home::Approvals::Queue, che resta l'unico posto in
  # cui vivono le quattro sorgenti, i loro gate e il loro ordine. La plancia continua a chiamarla
  # com'è sempre stata chiamata — i rimandi sono una faccenda della sola home, e infilarli nella
  # coda vorrebbe dire nascondere righe anche a chi guarda l'arretrato per capire dove si accumula.
  #
  # Sola lettura → ritorna un value object, non un Result (pattern Home::ActionInbox).
  #
  #   Home::NextDecision.call(account:, organization:, visible_projects:, visible_tickets:,
  #     skipped: []) → Next
  class NextDecision < ApplicationService
    # Quante card si prova a risolvere prima di arrendersi, quando quelle in testa continuano a
    # sparire sotto le mani (decise da altri fra il calcolo della coda e questo istante). Oltre non
    # è più una corsa persa con un collega: è la coda che non corrisponde più al database, e
    # continuare a interrogarlo riga per riga non la sistema.
    RESOLVE_ATTEMPTS = 10

    # `card` è già passata dai gate di Detail (nil se non c'è niente da decidere).
    # `item` è la RIGA DI CODA da cui la card è stata scelta: porta da quanto aspetta e quale
    # macchina l'ha lasciata lì, che la card non sa e che riderivare qui vorrebbe dire copiare la
    # logica della coda in un secondo posto.
    # `total` è il conteggio PIENO della coda, non al netto dei rimandi: dice quante decisioni ci
    # sono, non quante me ne sono nascoste. I rimandi hanno un numero loro.
    # `skipped_count` sono quelle messe da parte in questa sessione, che tornano domani da sé.
    # `totals` is the count per queue state and `oldest_at` the wait of the oldest loaded row: the
    # home bar reads both to say what kind of decisions are waiting (CYRA-884).
    Next = Data.define(:card, :item, :total, :deferred_count, :skipped_count, :totals, :oldest_at) do
      def card? = card.present?

      # C'è qualcosa in coda ma non lo sto vedendo perché l'ho messo da parte io: la differenza fra
      # «non aspetta niente» e «hai nascosto tutto», che sono due frasi diverse.
      def all_hidden? = card.nil? && total.positive?
    end

    def initialize(account:, organization:, visible_projects:, visible_tickets:, skipped: [])
      @account = account
      @organization = organization
      @visible_projects = visible_projects
      @visible_tickets = visible_tickets
      @skipped = Array(skipped).to_set
    end

    def call
      batch = queue
      deferred = ::Home::Deferral.live_keys_for(@account, organization: @organization)
      candidates = batch.items.reject { |item| deferred.include?(item.key) || @skipped.include?(item.key) }

      card, item = first_resolvable(candidates)
      Next.new(card:, item:, total: batch.total,
               deferred_count: deferred.size, skipped_count: @skipped.size,
               totals: batch.totals, oldest_at: batch.items.filter_map(&:sort_at).min)
    end

    private

    def queue
      Approvals::Queue.call(account: @account, organization: @organization,
                            visible_projects: @visible_projects, visible_tickets: @visible_tickets)
    end

    # La prima che risolve davvero. Fra il calcolo della coda e adesso una collega può aver deciso
    # la card in testa: Detail torna nil, e renderne il guscio vuoto sarebbe peggio che passare
    # oltre. Non è un caso di laboratorio — la coda è condivisa e in due la si smaltisce in due.
    def first_resolvable(candidates)
      candidates.first(RESOLVE_ATTEMPTS).each do |item|
        card = Approvals::Detail.call(account: @account, organization: @organization,
                                      visible_projects: @visible_projects,
                                      visible_tickets: @visible_tickets, key: item.key)
        return [ card, item ] if card
      end
      [ nil, nil ]
    end
  end
end
