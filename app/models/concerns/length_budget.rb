# frozen_string_literal: true

# Tetto di lunghezza su un campo di testo, con clausola di salvaguardia per il contenuto scritto
# prima che il tetto esistesse.
#
# La regola secca ("oltre N caratteri non salvi") intrappolerebbe chi ha già in DB un testo più
# lungo: non potrebbe più toccare la propria pagina nemmeno per correggere un refuso, e nemmeno per
# accorciarla progressivamente. Qui il superamento è un errore SOLO se il testo cresce: un record
# già oltre soglia resta salvabile finché il valore non si allunga (`<=`, non `<`, così anche il
# salvataggio che non tocca quel campo passa). Il rientro sotto soglia è quindi una scelta di chi
# scrive, non un muro; per un campo che era vuoto o già in regola il tetto vale pieno.
#
# Usato da Knowledge::Page (body/tech_spec) e Ticketing::Ticket (description/technical_analysis) —
# vedi Knowledge::Constants e Ticketing::Constants per i valori e il perché.
module LengthBudget
  extend ActiveSupport::Concern

  # Le textarea inviano i fine-riga come CRLF: normalizzarli a LF fa combaciare il conteggio del
  # server con quello del contatore nel browser (che vede il valore con LF) — altrimenti una pagina
  # di 100 righe "pesa" 100 caratteri in più solo lato server. Effetto collaterale desiderato:
  # niente \r nel DB, quindi niente re-embed spuri per un fine-riga diverso.
  def self.normalize_newlines(value)
    value.to_s.gsub("\r\n", "\n")
  end

  class_methods do
    def length_budget(attribute, maximum:)
      validate do
        # ENTRAMBI i lati passano dalla normalizzazione del model, sempre. Il valore appena
        # assegnato è già normalizzato (ripassarci è idempotente), ma quello LETTO da DB no: le
        # normalizzazioni valgono in scrittura, quindi un record scritto prima di questa regola
        # torna dal database con i suoi CRLF. Misurare un lato grezzo e uno normalizzato darebbe
        # confronti falsi in tutte e due le direzioni — testo che cresce di un carattere per riga
        # senza essere bloccato, oppure un salvataggio che non tocca il campo scambiato per crescita.
        value = self.class.normalize_value_for(attribute, public_send(attribute)).to_s
        next if value.length <= maximum

        # `_was` dentro una validazione = il valore in DB (nil per un record nuovo → "").
        previous = self.class.normalize_value_for(attribute, public_send(:"#{attribute}_was")).to_s
        next if previous.length > maximum && value.length <= previous.length

        errors.add(attribute, :length_budget_exceeded, count: maximum, actual: value.length)
      end
    end
  end
end
