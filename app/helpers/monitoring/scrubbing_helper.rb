# frozen_string_literal: true

module Monitoring
  # CYRA-379 — i valori OSCURATI dagli scrubber (di sistema o dell'SDK del progetto). A schermo un
  # valore nascosto va distinto da un valore assente: senza, uno stacktrace di "[FILTERED]" sembra un
  # guasto e nessuno capisce che è una scelta di riservatezza (CYRA-742).
  module ScrubbingHelper
    # Uno scrubber sostituisce i valori sensibili col letterale "[FILTERED]". A schermo va distinto da
    # un dato ASSENTE e reso con una dicitura comprensibile: senza, un intero stacktrace di "[FILTERED]"
    # sembra un guasto e nessuno capisce che è una scelta di riservatezza. Set in parità con
    # Projects::Source::PLACEHOLDER_CODES (bracket/case-insensitive: "[FILTERED]", "FILTERED", "REDACTED").
    SCRUBBED_CODES = %w[filtered redacted].freeze

    # Token oscurato EMBEDDED in una stringa composita (culprit "[FILTERED] in #deserialize", sdk
    # "[FILTERED] 1.0"): i bracket delimitano il solo token, il resto resta leggibile.
    SCRUBBED_TOKEN = /\[(?:filtered|redacted)\]/i

    # `true` se il valore È un placeholder di scrubbing (non un dato mancante). Bracket/case-insensitive.
    def error_scrubbed?(value)
      bare = value.to_s.strip.downcase.delete("[]").strip
      bare.present? && SCRUBBED_CODES.include?(bare)
    end

    # Rende un valore per la UI distinguendo l'oscuramento dall'assenza:
    #   - valore INTERO oscurato ("[FILTERED]", "FILTERED") → dicitura leggibile;
    #   - token oscurato dentro una stringa composita → sostituisce il solo token, preserva il resto;
    #   - qualsiasi altro valore (o non-stringa) → invariato (escape a carico della view).
    def error_value(value)
      return value unless value.is_a?(String)
      return error_scrubbed_tag if error_scrubbed?(value)
      return value unless value.match?(SCRUBBED_TOKEN)

      safe_join(value.split(SCRUBBED_TOKEN, -1), error_scrubbed_tag)
    end

    # Come #error_value ma sicuro per i valori COMPOSITI (params/context/extra possono annidare Hash/Array):
    # una stringa resta gestita da #error_value, una struttura viene serializzata sostituendo
    # ricorsivamente i placeholder col testo leggibile, così un "[FILTERED]" annidato non resta visibile.
    def error_value_deep(value)
      case value
      when String       then error_value(value)
      when Array, Hash  then error_deep_text(value).to_json
      else value
      end
    end

    # Sostituisce ricorsivamente i placeholder di scrubbing col testo leggibile dentro una struttura,
    # per la serializzazione JSON dei valori compositi (testo piano: questi blocchi sono resi raw in mono).
    def error_deep_text(value)
      case value
      when String then error_scrubbed?(value) ? t("member.monitoring.value_scrubbed") : value.gsub(SCRUBBED_TOKEN, t("member.monitoring.value_scrubbed"))
      when Array  then value.map { |element| error_deep_text(element) }
      when Hash   then value.transform_values { |v| error_deep_text(v) }
      else value
      end
    end

    # Il culprit ("filename in function") può avere il solo filename oscurato: stessa regola dei valori,
    # nome dedicato per leggibilità nelle view. Blank → nil (il chiamante gestisce l'assenza).
    def error_culprit(culprit)
      culprit.blank? ? nil : error_value(culprit)
    end

    # Versione TESTO PIANO del culprit oscurato per gli attributi (title/aria, che non rendono HTML):
    # coerente con #error_value → un placeholder INTERO (anche senza parentesi) diventa la label,
    # un token embedded viene sostituito; il resto resta invariato. Blank → invariato.
    def error_culprit_text(culprit)
      return culprit if culprit.blank?
      return t("member.monitoring.value_scrubbed") if error_scrubbed?(culprit)

      culprit.gsub(SCRUBBED_TOKEN, t("member.monitoring.value_scrubbed"))
    end

    # Dicitura del valore oscurato: lucchetto + "Nascosto", spiegazione nel title nativo. Muted e corsivo
    # per non confondersi con un dato reale. Il messaggio esteso + link alla config vive in _scrubbed_hint.
    def error_scrubbed_tag
      tag.span(
        safe_join([ render(Ui::IconComponent.new(name: "lock", class: "text-[10px]")),
                    t("member.monitoring.value_scrubbed") ]),
        class: "inline-flex items-center gap-1 italic text-gray-400 dark:text-zinc-500",
        title: t("member.monitoring.value_scrubbed_title"),
        data: { test: "scrubbed-value" }
      )
    end

    # `true` se un valore è oscurato, ovunque si trovi: stringa intera, token embedded o annidato in
    # Hash/Array. Base per decidere se mostrare l'avviso di riservatezza in una sezione.
    def deep_scrubbed?(value)
      case value
      when String then error_scrubbed?(value) || value.match?(SCRUBBED_TOKEN)
      when Array  then value.any? { |element| deep_scrubbed?(element) }
      when Hash   then value.values.any? { |v| deep_scrubbed?(v) }
      else false
      end
    end

    # `true` se ALMENO un valore della collezione è oscurato → per mostrare l'avviso una volta per sezione.
    def any_scrubbed?(values)
      Array(values).any? { |v| deep_scrubbed?(v) }
    end

    # `true` se ALMENO un frame ha il punto del codice (filename/module/function) oscurato.
    def frames_scrubbed?(frames)
      Array(frames).any? { |f| f.is_a?(Hash) && any_scrubbed?(f.values_at("filename", "module", "function")) }
    end
  end
end
