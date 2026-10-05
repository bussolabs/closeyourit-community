# frozen_string_literal: true

# CYRA-694 — i filtri di un elenco si ricordano: uscendo e tornando li si ritrova.
#
# Stesse due regole di TimeRangeable, da cui discende tutto:
#   1. L'indirizzo comanda. I filtri nell'indirizzo vincono sempre su quelli ricordati, così il
#      collegamento mandato a un collega gli mostra ESATTAMENTE gli stessi dati.
#   2. Chi filtra se lo ritrova. La scelta finisce in sessione e, tornando sull'elenco senza filtri
#      nell'indirizzo, torna NELL'INDIRIZZO con un redirect: se restasse solo in sessione, la pagina
#      mostrerebbe righe che il suo stesso indirizzo non dichiara.
#
# Il marker `ft=1` (hidden della toolbar, e href del bottone Azzera) distingue «form inviato con i
# filtri svuotati» — che CANCELLA la memoria — da «arrivo nudo da sidebar/breadcrumb» — che la
# ripristina. La memoria è per-indirizzo (path), quindi bacheca e lista hanno set
# indipendenti; `page`/`per` non si ricordano mai (il form della toolbar già non manda `page`).
module RememberableFilters
  extend ActiveSupport::Concern

  SESSION_KEY = "remembered_filters"
  # Hidden della toolbar: «questo indirizzo dichiara i filtri, anche quando sono vuoti».
  MARKER_PARAM = :ft
  # Il cookie di sessione pesa ~4KB in tutto: si ricordano al più questi indirizzi (i più recenti)…
  MAX_PATHS = 10
  # …e un set di filtri sopra questo peso non entra proprio (una `q` chilometrica non deve far
  # troncare il cookie e con lui la login).
  MAX_ENTRY_BYTES = 600

  class_methods do
    # remembers_filters :kind, :status_id, :q, :sort, only: :index
    # Chiamabile più volte: azioni diverse dello stesso controller ricordano set diversi.
    # Le chiavi sono una whitelist: solo loro finiscono in sessione e nell'indirizzo del redirect.
    def remembers_filters(*keys, only:, exact_keys: [])
      before_action(only: only) { restore_remembered_filters(keys, exact_keys) }
      before_action(only: only) { remember_filters(keys, exact_keys) }
    end
  end

  private

  # L'indirizzo dichiara i filtri? O perché ne porta almeno uno, o perché porta il marker della
  # toolbar (submit esplicito, anche a mani vuote).
  def remembered_filters_declared?(keys, exact_keys)
    params[MARKER_PARAM].present? || keys.any? { |k| params[k].present? || (exact_keys.include?(k) && params[k].is_a?(String) && params[k] != "") }
  end

  # before_action: nessun filtro nell'indirizzo ma un set ricordato per QUESTO path → lo si rimette
  # nell'indirizzo. Solo su GET HTML: un redirect su una richiesta Turbo Stream o su un formato dati
  # non avrebbe senso. Nessun ciclo: dopo il redirect i filtri sono dichiarati.
  def restore_remembered_filters(keys, exact_keys)
    return if remembered_filters_declared?(keys, exact_keys) || !request.get? || !request.format.html?

    remembered = (session[SESSION_KEY] || {})[request.path]
    return if remembered.blank?

    redirect_to "#{request.path}?#{request.query_parameters.merge(remembered.to_h).to_query}"
  end

  # before_action: un indirizzo che dichiara i filtri diventa la memoria di questo path. Un set
  # risultante vuoto (submit svuotato, bottone Azzera) la cancella: azzerare è dimenticare.
  def remember_filters(keys, exact_keys)
    return unless request.get? && request.format.html? && remembered_filters_declared?(keys, exact_keys)

    values = keys.each_with_object({}) do |key, memo|
      value = params[key]
      value = value.compact_blank if value.is_a?(Array)
      exact = exact_keys.include?(key) && value.is_a?(String) && value != ""
      memo[key.to_s] = value if exact || (value.present? && (value.is_a?(Array) || value.is_a?(String)))
    end

    # La sessione rientra come hash a chiavi stringa: si riscrive sempre per intero. La riscrittura
    # in coda fa da LRU: i path più vecchi cadono per primi al taglio.
    store = (session[SESSION_KEY] || {}).to_h
    store.delete(request.path)
    if values.present? && values.to_query.bytesize <= MAX_ENTRY_BYTES
      store[request.path] = values
      store = store.to_a.last(MAX_PATHS).to_h
    end
    session[SESSION_KEY] = store
  end
end
