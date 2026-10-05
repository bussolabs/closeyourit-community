# frozen_string_literal: true

module Ingest
  # CYRA-735 — la rimozione dei dati personali dal dato in ingresso, in un punto solo. Il backend è
  # l'autorità PII: ri-scruba anche quando il client ha già scrubato a monte (difesa in profondità).
  # La applicano i tre canali che portano testo scritto dalle persone — errori, log, campioni dei
  # server — più il canale performance, che sovrascrive il criterio di chiave (vedi sotto).
  #
  # Prima viveva compiuta solo nel canale errori: i log redigevano le sole chiavi dei dati strutturati
  # e lasciavano intatto il testo del messaggio, i campioni dei server non redigevano niente pur
  # trasportando i log di sistema della macchina, che è la sorgente di testo più libera del prodotto.
  #
  # Denylist canonica condivisa con gli SDK: closeyourit-docs/decisions/2026-07-09-pii-scrub-parity.md.
  module PiiScrubbing
    REDACTED = "[FILTERED]"

    # Chiavi il cui valore va redatto (autorità PII backend). Va letta come sottostringa: si applica a
    # sezioni di metadati liberi, dove `user_email` e `authToken` devono cadere entrambi.
    SENSITIVE_KEY = /pass|secret|token|bearer|api[_-]?key|apikey|authorization|cookie|csrf|session|pin|credit|card|cvv|pan|iban|e[_-]?mail|phone|telephone|mobile|dob|birth|ssn|passport/i

    # Header sempre redatti per NOME (oltre a quelli che matchano SENSITIVE_KEY): autenticazione e
    # indirizzo di chi ha chiamato.
    SENSITIVE_HEADER_NAMES = %w[
      authorization proxy-authorization cookie set-cookie x-api-key x-auth-token
      x-forwarded-for x-real-ip true-client-ip forwarded
    ].freeze
    SENSITIVE_HEADER = /\A(?:#{Regexp.union(SENSITIVE_HEADER_NAMES).source})\z/i

    # Chiavi il cui valore è l'indirizzo di una pagina: strippane la query (può contenere token/email).
    URL_KEY = /\A(url|uri|href|location|referer|referrer)\z/i

    # Le quattro forme in cui un dato personale finisce dentro un testo libero. Tutte redigono il solo
    # valore e lasciano in piedi la frase: il testo resta leggibile e un messaggio non diventa mai
    # vuoto per effetto dello scrub.

    # 1. "chiave=valore". Il valore si ferma al punto interrogativo oltre che a spazio, & e #:
    # `url=https://x/a?token=SECRET` è una chiave innocua che si porta dietro una query sensibile, e
    # senza quella fermata il token uscirebbe in chiaro dentro il match della chiave innocua.
    INLINE_ASSIGNMENT = /([\w.\-]+)=([^\s&#?]+)/

    # 2. Intestazione scritta col due punti ("Authorization: Bearer …", "Cookie: a=1; sid=…"). Il
    # valore si prende fino a fine RIGA, non fino al primo spazio: uno schema di autenticazione è
    # fatto di due parole e un cookie di più coppie separate da punto e virgola — fermarsi prima
    # lascerebbe in chiaro proprio il segreto.
    HEADER_IN_TEXT = /\b(#{Regexp.union(SENSITIVE_HEADER_NAMES).source}):([ \t]*)[^\r\n]*/i

    # 3. Dato strutturato citato dentro il testo (il corpo di una richiesta finito nel log):
    # `"password": "hunter2"`. Il valore è delimitato dalle virgolette, quindi si redige con precisione.
    QUOTED_ASSIGNMENT = /"([\w.\-]+)"(\s*:\s*)"(?:[^"\\]|\\.)*"/

    # 4. Indirizzo email scritto per intero. Il TLD non può essere un suffisso di unit systemd: nei
    # log di sistema un servizio a istanze si scrive `getty@tty1.service`, con la stessa forma di un
    # indirizzo — redigerlo renderebbe illeggibile proprio la sorgente più libera che copriamo. Il TLD
    # dev'essere alfabetico, così `root@10.0.0.9` resta leggibile: è una macchina, non una persona.
    SYSTEMD_UNIT_SUFFIX = /(?:service|socket|mount|timer|target|device|swap|path|slice|scope|automount)/
    EMAIL_IN_TEXT = /\b[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)*\.(?!#{SYSTEMD_UNIT_SUFFIX}\b)[a-z]{2,24}\b/i

    # Applica lo scrub a qualsiasi valore: Hash → chiave per chiave, Array → ricorsione, scalari
    # invariati (il testo libero si redige con #scrub_message, che è una scelta del chiamante).
    def scrub_value(value)
      case value
      when Hash  then scrub_hash(value)
      when Array then value.map { |element| scrub_value(element) }
      else value
      end
    end

    def scrub_hash(hash)
      hash.each_with_object({}) do |(key, value), acc|
        acc[key] = scrub_entry(key, value)
      end
    end

    # Punto di variazione: il canale performance aggiunge il ramo per il testo SQL (che va
    # templatizzato, non redatto) chiamando `super` per il resto.
    def scrub_entry(key, value)
      if sensitive_key?(key)
        REDACTED
      elsif url_key?(key) && value.is_a?(String)
        strip_query(value)
      else
        scrub_value(value)
      end
    end

    # Punto di variazione: il canale performance scruba TUTTO il payload (non solo le sezioni libere)
    # e per questo ancora la denylist al segmento intero della chiave — `span_id` contiene "pan",
    # `mapping` contiene "pin", e redarli romperebbe la correlazione fra campione e richiesta.
    def sensitive_key?(key)
      SENSITIVE_KEY.match?(key.to_s)
    end

    def url_key?(key)
      URL_KEY.match?(key.to_s)
    end

    # Redige gli header il cui NOME matcha la denylist o è un noto header di autenticazione/indirizzo.
    def scrub_headers(headers)
      headers.each_with_object({}) do |(name, value), acc|
        acc[name] = sensitive_header?(name) ? REDACTED : value
      end
    end

    def sensitive_header?(name)
      SENSITIVE_HEADER.match?(name.to_s) || sensitive_key?(name)
    end

    # Redige i soli parametri sensibili di una query string, preservando la struttura.
    def scrub_query_string(query)
      query.split("&").map do |pair|
        key = pair.split("=", 2).first
        sensitive_key?(key) ? "#{key}=#{REDACTED}" : pair
      end.join("&")
    end

    # Rimuove la query (token/email) da un indirizzo, tenendo schema, host e percorso.
    def strip_query(url)
      return url unless url.is_a?(String) && url.include?("?")

      url.split("?", 2).first
    end

    # Redige i dati personali dentro un testo libero, nelle quattro forme in cui ci finiscono. L'ordine
    # conta: l'intestazione si prende tutta la riga, quindi va prima delle forme più strette, che
    # altrimenti redigerebbero un pezzo solo lasciando in chiaro il resto del valore.
    def scrub_message(message)
      return message unless message.is_a?(String)

      redacted = message.gsub(HEADER_IN_TEXT) { "#{Regexp.last_match(1)}:#{Regexp.last_match(2)}#{REDACTED}" }
      redacted = redacted.gsub(QUOTED_ASSIGNMENT) do
        key = Regexp.last_match(1)
        sensitive_key?(key) ? %("#{key}"#{Regexp.last_match(2)}"#{REDACTED}") : Regexp.last_match(0)
      end
      redacted = redacted.gsub(INLINE_ASSIGNMENT) do
        key = Regexp.last_match(1)
        sensitive_key?(key) ? "#{key}=#{REDACTED}" : Regexp.last_match(0)
      end
      redacted.gsub(EMAIL_IN_TEXT, REDACTED)
    end
  end
end
