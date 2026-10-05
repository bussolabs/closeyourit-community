# frozen_string_literal: true

module Monitoring
  # CYRA-340 — il periodo di tempo, uno solo per tutta l'area di controllo. Prima ogni pagina lo
  # chiedeva a modo suo (errori e prestazioni non lo chiedevano affatto, i log volevano due date
  # scritte a mano, i dettagli avevano le scelte rapide): passare da una pagina all'altra durante un
  # guasto significava perdere l'arco di tempo e non poterle confrontare.
  #
  # È un valore, non un record: si costruisce dai parametri dell'indirizzo (`range`, `from`, `to`) e
  # sa applicarsi a uno scope. Le scelte rapide sono le stesse degli istogrammi di dettaglio
  # (Errors::Group::RANGES / Metrics::Group::RANGES) — stesso vocabolario in tutta l'area.
  class TimeRange
    PRESETS = { "30m" => 30.minutes, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    CUSTOM = "custom"
    DEFAULT = "24h"
    KEYS = [ *PRESETS.keys, CUSTOM ].freeze

    attr_reader :key, :from, :to

    # `from`/`to` presenti VINCONO sulla scelta rapida: è il drill-down dell'istogramma (un blocco
    # cliccato manda from+to sull'indirizzo che porta ancora il preset di prima) e sono i deep-link
    # già in giro (viste salvate dei log con `from=24 ore fa`). Senza questa precedenza il blocco
    # cliccato non filtrerebbe niente, in silenzio.
    def self.resolve(key:, from: nil, to: nil, now: Time.current)
      starts_at = parse(from)
      ends_at = parse(to)
      starts_at, ends_at = ends_at, starts_at if starts_at && ends_at && starts_at > ends_at
      key_name = key.to_s
      return new(key: CUSTOM, from: starts_at, to: ends_at) if starts_at || ends_at || key_name == CUSTOM

      key_name = DEFAULT unless PRESETS.key?(key_name)
      new(key: key_name, from: now - PRESETS.fetch(key_name), to: nil)
    end

    # Estremo singolo (ISO8601 o `datetime-local` YYYY-MM-DDTHH:MM), fuso dell'app.
    # Illeggibile = assente: un estremo storto lascia quel lato aperto, non svuota la pagina.
    def self.parse(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def initialize(key:, from:, to:)
      @key = key
      @from = from
      @to = to
    end

    def custom? = key == CUSTOM
    def preset? = !custom?

    # Nessun estremo: il personalizzato lasciato in bianco non filtra (è «tutto»), e va detto perché
    # il selettore mostra comunque «Personalizzato».
    def unbounded? = from.nil? && to.nil?

    # Entrambi gli estremi INCLUSIVI, come già faceva il filtro dei log (CYRA-56): un incidente si
    # scopa scrivendo 14:00–14:10 e la voce delle 14:10 esatte deve esserci.
    def apply(scope, column:)
      scope = scope.where(column => from..) if from
      scope = scope.where(column => ..to) if to
      scope
    end

    # I parametri che questo periodo mette nell'indirizzo: la scelta rapida è la sola chiave, il
    # personalizzato porta gli estremi (in ISO8601, che regge il fuso; la vista li riformatta per
    # l'input `datetime-local`).
    def link_params
      return { range: key } if preset?

      { range: CUSTOM, from: from&.iso8601, to: to&.iso8601 }.compact
    end

    def ==(other) = other.is_a?(self.class) && other.key == key && other.from == from && other.to == to
    alias eql? ==

    def hash = [ key, from, to ].hash
  end
end
