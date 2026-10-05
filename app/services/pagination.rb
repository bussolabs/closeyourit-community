# frozen_string_literal: true

# Paginazione offset nativa ActiveRecord (no gem pagy/kaminari, regola dependencies).
# Riusabile da ogni controller-lista: `Pagination.call(scope, page: params[:page])`.
# Ritorna un oggetto immutabile consumato da Ui::PaginationComponent.
class Pagination
  DEFAULT_PER = App::Constants::TABLE_PER_PAGE
  # Default page size of the API and CLI envelopes. It stays 10 when the web lists move to 12 rows,
  # so a client that pages through results sees the same pages as before.
  MACHINE_DEFAULT_PER = 10
  MAX_PER = 200 # tetto anti-DoS: nessun endpoint serve pagine illimitate (?per=enorme)
  # CYRA-408 — quante righe per pagina si può chiedere. Allowlist, non un numero libero: 1163 ticket
  # a dieci per pagina fanno 117 pagine, ma «quante ne vuoi» sarebbe una leva per far male al server.
  PER_OPTIONS = [ 12, 25, 50, 100 ].freeze
  WINDOW = 2 # numeri pagina mostrati a sinistra/destra della corrente

  Result = Data.define(:records, :page, :per, :total, :total_pages) do
    def prev? = page > 1
    def next? = page < total_pages
    def multiple_pages? = total_pages > 1

    # Indice 1-based della prima/ultima riga mostrata (0 se lista vuota).
    def from = total.zero? ? 0 : ((page - 1) * per) + 1
    def to = [ page * per, total ].min

    # Finestra contigua di numeri pagina attorno alla corrente (vuota se 1 sola pagina).
    # Gli eventuali "…" + prima/ultima li aggiunge il componente.
    def window
      return [] unless multiple_pages?

      first = [ page - WINDOW, 1 ].max
      last = [ page + WINDOW, total_pages ].min
      (first..last).to_a
    end
  end

  # scope: una ActiveRecord::Relation non ancora paginata.
  def self.call(scope, page:, per: DEFAULT_PER)
    per = clamp_per(per)

    total = scope.count
    total = total.size if total.is_a?(Hash) # difesa: GROUP BY count → conta le chiavi
    total_pages = pages_for(total, per)
    page = clamp_page(page, total_pages)

    records = scope.offset((page - 1) * per).limit(per).to_a

    Result.new(records: records, page: page, per: per, total: total, total_pages: total_pages)
  end

  # list: righe GIÀ in memoria (un jsonb espanso, un'aggregazione fatta in Ruby) — offset/limit non
  # esistono, ma il Result è lo stesso, così Ui::PaginationComponent non distingue le due sorgenti.
  def self.from_array(list, page:, per: DEFAULT_PER)
    per = clamp_per(per)

    total = list.size
    total_pages = pages_for(total, per)
    page = clamp_page(page, total_pages)

    Result.new(records: list.slice((page - 1) * per, per) || [],
               page: page, per: per, total: total, total_pages: total_pages)
  end

  # CYRA-794 — righe che il database ha GIÀ ordinato, contato e tagliato: `total` arriva da una query
  # di conteggio e il blocco riceve offset e limite normalizzati, quindi legge SOLO la pagina. È la
  # variante per le liste la cui riga è un aggregato (un GROUP BY): con `.from_array` bisognerebbe
  # portare in memoria un aggregato per OGNI gruppo del filtro per mostrarne dieci, e quel costo
  # cresce con lo storico invece che con la pagina. La pagina si clampa PRIMA di leggere: chiedere
  # la 999ª deve leggere l'ultima, non un offset oltre la fine.
  def self.from_query(total:, page:, per: DEFAULT_PER)
    per = clamp_per(per)
    total_pages = pages_for(total, per)
    page = clamp_page(page, total_pages)
    # Niente da mostrare: nemmeno la query per scoprirlo, il conteggio l'ha già detto.
    records = total.zero? ? [] : yield((page - 1) * per, per)

    Result.new(records: records, page: page, per: per, total: total, total_pages: total_pages)
  end

  def self.clamp_per(per)
    per = per.to_i
    return DEFAULT_PER if per <= 0

    [ per, MAX_PER ].min
  end
  private_class_method :clamp_per

  def self.clamp_page(page, total_pages) = page.to_i.clamp(1, total_pages)
  private_class_method :clamp_page

  def self.pages_for(total, per) = total.zero? ? 1 : (total.to_f / per).ceil
  private_class_method :pages_for
end
