# frozen_string_literal: true

module Metrics
  # Una riga leggibile al posto dello SQL grezzo (CYRA-367). Sulla panoramica del progetto — la
  # pagina più vista — comparivano righe come `4500ms SELECT "ticketin…`: tagliate dopo poche
  # parole, illeggibili sia per chi il codice lo scrive sia per chi non lo scrive, e per giunta
  # spesso su tabelle del framework, cioè rumore.
  #
  # Deterministico e senza pretese: si riconosce il VERBO e la PRIMA tabella. Non si prova a
  # spiegare cosa faccia la query — quello lo dice la pagina del gruppo, dove lo SQL c'è per
  # intero — si dice cosa tocca e in che modo, che è quanto serve per decidere se aprirla.
  class QueryLabel
    # Tabelle dell'infrastruttura: code di lavoro, cache, canali realtime, metadati di schema.
    # Non sono il prodotto, e una lentezza lì non dice niente a chi guarda la panoramica di un
    # progetto. L'esclusione è DICHIARATA nella vista, mai silenziosa (rischio del ticket).
    SYSTEM_TABLE_PREFIXES = %w[
      solid_queue_ solid_cache_ solid_cable_ ar_internal_metadata schema_migrations active_storage_
    ].freeze

    OPERATIONS = {
      "select" => :read, "insert" => :write, "update" => :change, "delete" => :delete
    }.freeze

    def initialize(title)
      @title = title.to_s
    end

    # La tabella toccata, senza virgolette né schema: `public."ticketing_tickets"` →
    # `ticketing_tickets`. Stringa vuota quando non se ne riconosce una: il chiamante decide.
    def table
      @table ||= begin
        raw = @title[/\b(?:from|into|update|join)\s+([a-z0-9_."]+)/i, 1].to_s.delete('"')
        raw.split(".").last.to_s
      end
    end

    def operation = OPERATIONS[@title.strip[/\A\w+/].to_s.downcase]

    # Tabella dell'infrastruttura: la lentezza è del framework, non del prodotto.
    def system? = SYSTEM_TABLE_PREFIXES.any? { |prefix| table.start_with?(prefix) }

    # «Lettura · ticket». Senza tabella riconosciuta si ripiega sul titolo così com'è: meglio la
    # riga grezza che una riga inventata, e il caso è raro per costruzione (lo SQL arriva già
    # templatizzato dall'ingest).
    def to_s
      return @title if table.blank?

      subject = table.humanize.downcase
      operation ? I18n.t("metrics.query_label.#{operation}", subject:) : subject
    end
  end
end
