# frozen_string_literal: true

# Helper condivisi per le pagine-lista (toolbar + filtri + paginazione):
# filtri multi (param array), ricerca testuale, paginazione offset nativa,
# ordinamento per colonna (Sortable#sorted).
module Listable
  extend ActiveSupport::Concern
  include Sortable

  private

  # Valori di un filtro multi (Ui::SelectComponent multiple), ripuliti dai blank.
  # Accetta scalare o array (regola forms-select).
  def filter_ids(key) = Array(params[key]).reject(&:blank?)

  # Termine della search box "q" (vuoto se assente).
  def search_q = params[:q].to_s.strip

  # Paginazione offset nativa → Pagination::Result. `page_param` permette tabelle multiple
  # sulla stessa pagina (es. members + inviti) con cursori indipendenti. `per:` sovrascrive
  # la densità di default (App::Constants::TABLE_PER_PAGE) per liste che vogliono più righe
  # per pagina (es. la fleet server, piccola: tutti gli host in una schermata).
  # CYRA-817 — anche `per_param` si sceglie: due elenchi sulla stessa pagina hanno cursori
  # indipendenti solo se è indipendente ANCHE la densità, altrimenti cambiare le righe di uno
  # riporta l'altro a pagina 1 (il link della densità azzera la pagina di proposito).
  def paginate(scope, page_param = :page, per: Pagination::DEFAULT_PER, per_param: :per)
    Pagination.call(scope, page: params[page_param], per: requested_per(per, per_param))
  end

  # CYRA-408 — quante righe per pagina, scelte da chi guarda e ricordate nell'indirizzo (così un
  # collegamento condiviso mostra la stessa cosa). Solo i valori dell'allowlist: un numero qualsiasi
  # sarebbe una leva per chiedere al server pagine enormi.
  def requested_per(default, per_param = :per)
    requested = params[per_param].to_i
    Pagination::PER_OPTIONS.include?(requested) ? requested : default
  end

  # Finestra temporale [from, to) dai param `from`/`to` (ISO8601): drill-down dell'istogramma
  # occorrenze (CYRA-46). Cliccare una barra apre la show con from=inizio&to=fine del blocco, così
  # le occorrenze si filtrano a quella finestra (correla lo spike a un deploy). Ritorna [from, to]
  # (Time) SOLO se entrambi parsabili e from < to; param assenti/malformati/incoerenti → nil (nessun
  # filtro, la vista mostra tutte le occorrenze).
  def time_window
    from = params[:from].present? ? Time.zone.parse(params[:from]) : nil
    to = params[:to].present? ? Time.zone.parse(params[:to]) : nil
    return nil unless from && to && from < to

    [ from, to ]
  rescue ArgumentError, TypeError
    nil
  end

  # Istante rispetto al quale è stato costruito un istogramma cliccabile. Il drill-down lo conserva
  # tra la request che genera i link e quella che filtra la tabella: senza questo anchor i bucket,
  # relativi a Time.current, scorrono e il conteggio del blocco attivo può divergere dalle righe.
  def time_anchor
    return nil if params[:chart_at].blank?

    Time.zone.parse(params[:chart_at])
  rescue ArgumentError, TypeError
    nil
  end

  # Un singolo estremo temporale (Time) dal param `key` (ISO8601 o `datetime-local`
  # `YYYY-MM-DDTHH:MM`), per un filtro range su un'index (from/to indipendenti, CYRA-56).
  # A differenza di #time_window (drill-down istogramma: entrambi obbligatori, half-open),
  # qui ogni estremo è a sé — from-solo = "da quell'istante", to-solo = "fino a". Param
  # assente/malformato → nil (estremo non vincolato). tz app (Rome) via Time.zone.parse,
  # coerente con since=today.
  def time_bound(key)
    return nil if params[key].blank?

    Time.zone.parse(params[key].to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
