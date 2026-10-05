# frozen_string_literal: true

module Errors
  # Titolo leggibile per un ticket nato da un errore (CYRA-399). Il titolo del gruppo è il messaggio
  # dell'eccezione così com'è (`ActiveRecord::ConnectionNotEstablished: connection to server at
  # "10.0.0.5", port 5432 failed`): finiva tale e quale in cima alla colonna più letta, alto quattro
  # righe, accanto a titoli scritti da persone.
  #
  # È DETERMINISTICO, non generato da un modello: la promozione parte da un clic e deve rispondere
  # subito, e il ticket stesso avverte che una generazione va messa fuori dal percorso caldo, con
  # fallback e rigenerazione asincrona. Qui non serve nessuna delle due cose, perché non si inventa
  # niente: si riconosce la FAMIGLIA dell'eccezione e si dice cosa è successo. Una famiglia che non
  # conosciamo ricade sul nome corto dell'eccezione — brutto ma vero, mai una frase inventata.
  #
  # Il messaggio tecnico integrale NON si perde: va nel corpo del ticket (vedi PromoteToTicket).
  class TicketTitle < ApplicationService
    MAX = 120

    # Le famiglie riconosciute, in ordine: la prima che combacia vince. Sono le eccezioni che si
    # vedono davvero in produzione — non un dizionario di tutto lo scibile, che invecchierebbe.
    FAMILIES = [
      [ /ConnectionNotEstablished|ConnectionBad|ConnectionTimeout|Mysql2::Error|PG::UnableToSend/i, "database_down" ],
      [ /Timeout|TimedOut/i,                                                                        "timeout" ],
      [ /RecordNotFound|RoutingError|NotFound/i,                                                    "not_found" ],
      [ /RecordInvalid|RecordNotUnique|NotNullViolation|InvalidForeignKey/i,                         "invalid_data" ],
      [ /NoMethodError|NameError|NoMatchingPatternError/i,                                          "missing_value" ],
      [ /Forbidden|NotAuthorized|AccessDenied|Unauthorized/i,                                       "forbidden" ],
      [ /JSON::ParserError|ParseError|MalformedRequest|BadRequest/i,                                "unreadable_input" ]
    ].freeze

    def initialize(group:)
      @group = group
    end

    def call
      subject = family_sentence || fallback_sentence
      where = location
      title = where.present? ? I18n.t("errors.ticket_title.with_location", subject:, location: where) : subject
      title.truncate(MAX)
    end

    # Il messaggio tecnico integrale, nella forma in cui è arrivato: va nel corpo del ticket.
    def self.technical_line(group) = group.title.to_s

    private

    # Il titolo del gruppo è `Tipo: messaggio` (Errors::Ingest::Normalize li unisce con ": "):
    # tagliare sul primo `:` spezzerebbe `ActiveRecord::ConnectionNotEstablished` a metà.
    def exception_type = @group.title.to_s.split(": ", 2).first.to_s.strip

    def family_sentence
      key = FAMILIES.find { |pattern, _| pattern.match?(exception_type) }&.last
      return nil if key.nil?

      I18n.t("errors.ticket_title.families.#{key}")
    end

    # Nessuna famiglia riconosciuta: il nome corto dell'eccezione, senza namespace. Brutto, ma è
    # quello che è successo — inventare una frase sarebbe peggio del messaggio grezzo.
    def fallback_sentence
      short = exception_type.split("::").last.presence || I18n.t("errors.ticket_title.unknown")
      I18n.t("errors.ticket_title.fallback", type: short)
    end

    # Dove è successo, in forma corta: `app/services/checkout/pay.rb in call` diventa `pay.rb in call`.
    # Il percorso intero non aiuta a leggere il titolo e resta nei dettagli tecnici.
    def location
      raw = @group.culprit.to_s.strip
      return nil if raw.blank?

      file, function = raw.split(" in ", 2)
      short_file = file.to_s.split("/").last
      [ short_file, function ].compact_blank.join(" · ").presence
    end
  end
end
