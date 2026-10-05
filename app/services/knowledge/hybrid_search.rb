# frozen_string_literal: true

module Knowledge
  # Ramo ricerca delle pagine KB, in UN posto solo per i due canali che cercano nello stesso
  # archivio (elenco web e CLI): pertinenza semantica PRIMA, match testuali non già inclusi POI.
  #
  # L'unione col testuale non è un ripiego, è la ricerca: Knowledge::SemanticSearch scarta le pagine
  # senza embedding, e senza embedding stanno sia la pagina appena creata (il job è asincrono) sia
  # — sempre, per scelta — le proposte in revisione e quelle scartate, che Knowledge::CreatePage non
  # accoda apposta. Chiedere gli stati non pubblicati serve a controllare i doppioni PRIMA di
  # proporre (CYRA-769): senza la coda testuale la ricerca risponderebbe «non esiste» proprio sulle
  # pagine per cui è stata allargata. Il canale CLI la faceva solo a servizio embedding giù, cioè
  # mai in produzione.
  #
  # Gli STATI non si decidono qui: lo scope arriva già filtrato per visibilità e per stato dal
  # chiamante (Knowledge::Page.visible_to). Allargare gli stati non allarga i permessi, perché
  # entrambi i rami cercano dentro quella stessa scope.
  #
  # `mode` dichiara come si è risposto: :semantic, :like (servizio giù o «parole esatte» chieste),
  # nil (nessuna query, nessuna ricerca fatta). Il chiamante la rende come preferisce — il banner del
  # web, `meta.search` della CLI — ma la calcola questo service, così i due canali non possono
  # dichiarare due cose diverse sulla stessa risposta.
  class HybridSearch < ApplicationService
    Outcome = Data.define(:scope, :mode)

    def initialize(scope:, query:, semantic: true, client: nil)
      @scope = scope
      @query = query.to_s.strip
      @semantic = semantic
      @client = client
    end

    def call
      return Outcome.new(scope: @scope, mode: nil) if @query.blank?
      return Outcome.new(scope: text_matches, mode: :like) unless @semantic

      result = SemanticSearch.call(scope: @scope, query: @query, client: @client)
      # Servizio embedding giù: si degrada al testuale, MAI un errore in faccia a chi cerca.
      return Outcome.new(scope: text_matches, mode: :like) if result.err?

      ordered_ids = result.value + (text_match_ids - result.value)
      return Outcome.new(scope: @scope.none, mode: :semantic) if ordered_ids.empty?

      # reorder(nil): l'ordine è la pertinenza (in_order_of filtra E ordina sugli id passati),
      # altrimenti prevarrebbe l'ordinamento dell'elenco.
      Outcome.new(scope: @scope.reorder(nil).in_order_of(:id, ordered_ids), mode: :semantic)
    end

    private

    # «Parole esatte» = titolo, corpo e parte tecnica, gli stessi tre campi che finiscono nel
    # vettore semantico (Knowledge::Page.text_search, CYRA-573).
    def text_matches = @scope.text_search(@query)

    # Solo gli id: la coda testuale serve a completare un ordine, non a caricare righe.
    #
    # `except(:includes, …)` come nel gemello Ticketing::Search::Query: `pluck` su una relation con
    # `includes` costruisce comunque i LEFT OUTER JOIN del preload, e una pagina collegata a 2
    # progetti torna 2 VOLTE — misurato, non dedotto (`eager_loading?` era false e l'SQL aveva i
    # join lo stesso). Gli id ripetuti finiscono nell'ORDER BY CASE di `in_order_of` e lo gonfiano.
    #
    # `reorder` esplicito, non `reorder(nil)`: questi id decidono anche la PAGINAZIONE, e senza
    # ORDER BY quale pagina mostra cosa lo sceglie il piano — fra pagina 1 e pagina 2, che sono due
    # query distinte, una riga può ripetersi o sparire. L'ordine è quello dell'elenco (`ordered`);
    # `id` chiude il pareggio, perché a parità di updated_at l'ordine fra i pari resta indefinito.
    def text_match_ids
      text_matches.except(:includes, :eager_load, :preload)
                  .reorder(updated_at: :desc, id: :desc).pluck(:id)
    end
  end
end
