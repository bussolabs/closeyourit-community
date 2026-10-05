# frozen_string_literal: true

module Logs
  # CYRA-348 — la vista raggruppata: gli stessi filtri della lista completa, ma una riga per messaggio
  # invece di una per occorrenza, con quante volte è comparso e la prima e l'ultima volta.
  #
  # Il raggruppamento è per impronta (Logs::Fingerprint), calcolata all'ingresso. Le righe più vecchie
  # dell'impronta non ce l'hanno: restano fuori dalla vista raggruppata invece di finire tutte in un
  # gruppo unico che non vuol dire niente. Il conteggio scoperto lo dichiara la pagina.
  # CYRA-578 — i gruppi si sfogliano come la lista, invece di fermarsi ai primi cinquanta senza
  # dirlo: i gruppi piccoli sono quelli comparsi oggi per la prima volta, cioè proprio quelli che si
  # cercano qui, ed erano gli unici a restare fuori. Il piede dichiara quanti messaggi diversi ci sono.
  class GroupedMessages < ApplicationService
    Row = Data.define(:fingerprint, :message, :level, :count, :first_seen_at, :last_seen_at)

    def initialize(scope:, page: nil, per: Pagination::DEFAULT_PER)
      @scope = scope
      @page = page
      @per = per
    end

    # CYRA-794 — la pagina costa quanto la pagina, non quanto lo storico: ordine, conteggio e taglio
    # stanno nel database. Prima l'aggregato usciva INTERO (una riga per ogni messaggio distinto del
    # filtro), veniva riordinato in memoria da Ruby e solo alla fine affettato: dieci righe mostrate,
    # G righe trasferite e G·log G confronti, per ogni pagina. Tre letture in tutto, tutte limitate:
    # quanti messaggi diversi ci sono, la pagina dell'aggregato, gli esempi di quella pagina.
    # Ritorna un Pagination::Result, come ogni altra lista: Ui::PaginationComponent non distingue.
    def call
      base = @scope.where.not(fingerprint: nil).reorder(nil)

      Pagination.from_query(total: base.distinct.count(:fingerprint), page: @page, per: @per) do |offset, limit|
        rows_for(base, offset: offset, limit: limit)
      end
    end

    private

    # L'aggregato della sola pagina chiesta, più un messaggio d'esempio per ognuna delle sue impronte.
    # `DISTINCT ON` prende gli esempi senza una seconda query per gruppo, e gli esempi si leggono SOLO
    # per la pagina mostrata: sono la parte cara, e le altre pagine non si vedono.
    def rows_for(base, offset:, limit:)
      aggregated = base.group(:fingerprint)
                      # A parità di occorrenze decide l'impronta: senza un secondo criterio l'ordine
                      # non è deciso, e sfogliando si rivedrebbe un gruppo due volte perdendone un altro.
                      .order(Arel.sql("COUNT(*) DESC, fingerprint ASC"))
                      .offset(offset).limit(limit)
                      .pluck(Arel.sql("fingerprint, COUNT(*), MIN(occurred_at), MAX(occurred_at)"))
      samples = samples_for(aggregated.map(&:first))
      aggregated.filter_map do |fingerprint, count, first_seen, last_seen|
        sample = samples[fingerprint]
        next if sample.nil?

        Row.new(fingerprint:, message: sample.message, level: sample.level,
                count: count, first_seen_at: first_seen, last_seen_at: last_seen)
      end
    end

    # L'occorrenza più recente di ogni impronta: è quella che si vuole leggere, perché è lo stato
    # attuale del guasto. Presa dallo stesso scope filtrato, mai da tutto lo stream.
    def samples_for(fingerprints)
      @scope.where(fingerprint: fingerprints)
            .reorder(fingerprint: :asc, occurred_at: :desc)
            .select("DISTINCT ON (fingerprint) logs_entries.*")
            .index_by(&:fingerprint)
    end
  end
end
