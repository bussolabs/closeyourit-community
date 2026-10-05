# frozen_string_literal: true

module Text
  # Ripassa l'ortografia italiana sui testi GIÀ in tabella (CYRA-411).
  #
  # Le `normalizes` dei model valgono da quando esistono: tutto ciò che le automazioni hanno scritto
  # prima resta com'era, e la Definition of Done chiede che un controllo sui ticket recenti non trovi
  # più parole senza accento. Questo service è quel ripasso, e riusa esattamente la stessa funzione
  # delle normalizes — nessuna seconda regola da tenere allineata.
  #
  # Scrive con `update_columns`: SALTA validazioni, callback e `updated_at`. È voluto e vale su tre
  # fronti. Un ticket legacy oltre il tetto di lunghezza non è salvabile con `save` (e resterebbe
  # senza accenti per sempre); la data di aggiornamento non deve muoversi, perché mettere un accento
  # non è "qualcuno ha toccato il ticket"; e nessun evento di cronologia va scritto per una
  # correzione tipografica. Effetto collaterale accettato: l'embedding del ticket resta quello
  # calcolato sul testo vecchio finché qualcuno non lo risalva — la distanza semantica fra «gia» e
  # «già» non vale un re-embed dell'intero parco.
  #
  # La normalizzazione dei model NON è scavalcata da questa scelta: `normalizes` decora il TIPO
  # dell'attributo, quindi passa anche da `update_columns`. La correzione è idempotente, quindi le
  # due passate coincidono; ma è la ragione per cui un record "storico" si ricrea solo con una UPDATE
  # grezza, e lo spec di questo service lo fa così.
  #
  # I Ticketing::Report restano FUORI di proposito: sono append-only per contratto (attr_readonly), e
  # una versione già consegnata non si riscrive nemmeno per un accento. I resoconti nuovi nascono
  # comunque corretti, come tutto il resto.
  #
  # Idempotente: alla seconda passata non trova più niente da correggere.
  class BackfillOrthography < ApplicationService
    # Modello → colonne di testo da ripassare. Le colonne jsonb (scenari, DoD e note di un piano)
    # passano da correct_deep, che tocca le sole stringhe di valore.
    TARGETS = [
      [ "Ticketing::Ticket", %i[title description technical_analysis agent_eligibility_reason] ],
      [ "Ticketing::Comment", %i[body] ],
      [ "Ticketing::Scenario", %i[title step_given step_when step_then step_expected] ],
      [ "Ticketing::Condition", %i[text] ],
      [ "Agents::Plan", %i[technical_analysis scenarios definition_of_done notes] ]
    ].freeze

    # dry_run: true è il default perché qui si riscrive il testo scritto da qualcun altro — stessa
    # scelta di `analysis_relabel` e `comment_compaction`.
    def initialize(dry_run: true, limit: nil)
      @dry_run = dry_run
      @limit = limit
    end

    # => Result.ok({"Ticketing::Ticket" => {scanned:, corrected:}, ...})
    def call
      Result.ok(TARGETS.to_h { |model_name, columns| [ model_name, sweep(model_name.constantize, columns) ] })
    end

    private

    def sweep(model, columns)
      scanned = 0
      corrected = 0
      scope(model).find_each do |record|
        scanned += 1
        changes = corrections_for(record, columns)
        next if changes.empty?

        corrected += 1
        record.update_columns(**changes) unless @dry_run
        break if @limit && corrected >= @limit
      end
      { scanned:, corrected: }
    end

    # Il limite è per MODELLO, non globale: serve a provare la passata su poche righe di ciascuna
    # tabella, non a correggerne una sola in tutto il database.
    def scope(model)
      @limit ? model.limit(@limit) : model.all
    end

    # Solo le colonne che cambiano davvero: un update senza differenze sarebbe una scrittura inutile
    # su ogni riga già a posto.
    def corrections_for(record, columns)
      columns.filter_map do |column|
        current = record.public_send(column)
        next if current.blank?

        fixed = Text::ItalianOrthography.correct_deep(current)
        next if fixed == current

        [ column, fixed ]
      end.to_h
    end
  end
end
