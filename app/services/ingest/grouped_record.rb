# frozen_string_literal: true

module Ingest
  # CYRA-736 — la sequenza con cui si registra un dato RAGGRUPPATO, in un punto solo.
  #
  # Due domini arrivano qui: gli errori (un evento dentro un gruppo di errori) e le performance (un
  # campione dentro un gruppo di prestazione). Entrambi fanno gli stessi passi, nello stesso ordine:
  #
  #   1. la riga è già registrata? (idempotenza sulla chiave del delivery) → esci
  #   2. trova o crea il gruppo dall'impronta
  #   3. leggi dal gruppo ciò che serve PRIMA che i contatori si muovano (il tetto è uno di questi)
  #   4. scrivi la riga, col corpo o senza a seconda del tetto
  #   5. aggiorna gli aggregati del gruppo con un solo UPDATE atomico
  #   6. registra la fonte osservata, DOPO il commit
  #
  # Prima questa sequenza era scritta due volte, in Errors::Ingest::Record e Metrics::Ingest::Record:
  # una correzione al tetto o al tracciamento dell'origine andava fatta in entrambe le copie, e chi ne
  # correggeva una sola lasciava l'altro dominio col comportamento vecchio senza che niente lo dicesse.
  #
  # Qui vive la sequenza; NON vive la parte di dominio, che resta nelle sottoclassi e che è tanta: gli
  # errori riaprono su regressione, sondano gli spike, diradano il lavoro sotto raffica ed embeddano il
  # gruppo nuovo; le performance hanno anche un percorso a lotti che scrive N campioni con un solo
  # `insert_all`. Quelle differenze sono comportamento voluto, non duplicazione, e unificarle
  # cambierebbe cosa fa il prodotto.
  class GroupedRecord < ApplicationService
    # La dichiarazione di un dominio: le due associazioni sul PROGETTO (dove si cerca e dove si
    # scrive), la colonna su cui il delivery è idempotente, il contatore del gruppo su cui si misura
    # il tetto. È tutto ciò che cambia fra errori e performance nei passi qui sopra.
    Shape = Data.define(:groups, :occurrences, :key, :counter)

    # L'esito della sequenza: il gruppo (PRE-bump, come lo hanno visto le decisioni), la riga appena
    # scritta e la lettura pre-bump del dominio, che serve anche fuori dalla transazione.
    Stored = Data.define(:group, :occurrence, :reading)

    class << self
      # Dichiarazione del dominio, una riga per sottoclasse.
      def records_grouped_by(groups:, occurrences:, key:, counter:)
        @shape = Shape.new(groups: groups, occurrences: occurrences, key: key, counter: counter)
      end

      # Una sottoclasse che si dimentica la dichiarazione si ferma qui: senza, non saprebbe dove
      # cercare i propri gruppi e finirebbe per ereditare in silenzio quelli di un altro dominio.
      def shape
        @shape || raise(NotImplementedError, "#{name} non ha dichiarato records_grouped_by")
      end
    end

    def initialize(project:, payload: nil)
      @project = project
      @payload = payload || {}
    end

    private

    def shape = self.class.shape

    def groups = @project.public_send(shape.groups)

    def occurrences = @project.public_send(shape.occurrences)

    # Passo 1 — questo delivery è già stato registrato? Il canale è at-least-once: lo stesso evento
    # arriva più volte (replay dell'SDK, retry di rete) e deve contare una volta sola.
    def already_recorded(id) = occurrences.find_by(shape.key => id)

    # Passo 2 — find-first, non `create_or_find_by!`: la validazione di unicità farebbe fallire la
    # create con RecordInvalid prima che il DB sollevi RecordNotUnique, e il rescue non scatterebbe.
    # La race può emergere sia dalla validazione Rails sia dal vincolo SQL.
    def upsert_group(fingerprint, normalized)
      absorbed_group(fingerprint) ||
        groups.find_or_create_by!(fingerprint: fingerprint) { |group| new_group(group, normalized) }
    rescue ActiveRecord::RecordNotUnique
      groups.find_by!(fingerprint: fingerprint)
    rescue ActiveRecord::RecordInvalid => error
      # Recupera soltanto l'unicità dell'impronta: altri dati invalidi devono fallire.
      details = error.record.errors.details
      raise unless details.keys == [ :fingerprint ] && details[:fingerprint].all? { |item| item[:error] == :taken }

      groups.find_by(fingerprint: fingerprint) || raise
    end

    # Punto di variazione: un dominio può aver ASSORBITO quell'impronta in un altro gruppo (la fusione
    # degli errori, CYRA-192). Senza, la find_or_create_by! creerebbe un gruppo nuovo e quello appena
    # fuso ricomparirebbe nell'elenco alla prima occorrenza successiva.
    def absorbed_group(_fingerprint) = nil

    # Passo 3 — il tetto (CYRA-196): oltre soglia la riga si scrive SEMPRE, ma senza il corpo. Sono i
    # jsonb a pesare, non le righe, e la riga regge cose che il campionamento avrebbe rotto tutte:
    # l'idempotenza sulla chiave, il conteggio degli utenti distinti, gli istogrammi per bucket.
    #
    # Si misura sul contatore PRE-bump, quindi è una funzione pura di un numero già in memoria:
    # nessuna query, nessuna cache, costo zero anche a 500 eventi/sec — che è quando serve.
    def over_cap?(group) = over_cap_at?(group.public_send(shape.counter))

    # La regola nuda, sul conteggio delle righe già conservate per intero. Esposta a parte perché il
    # percorso a lotti la applica riga per riga su un conteggio calcolato, non sul contatore del gruppo.
    def over_cap_at?(count) = count.to_i >= Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT

    # Passi 2→5, nell'ordine che conta. Va chiamata DENTRO la transazione del dominio.
    #
    # L'ordine non è arbitrario: la lettura pre-bump precede la scrittura della riga perché il dominio
    # ci guarda dentro il gruppo com'era (gli errori chiedono «ho già visto questo utente?», e dopo la
    # create la risposta sarebbe sempre sì), e precede ovviamente l'UPDATE, che quei valori li muove.
    def store_occurrence(fingerprint:, occurrence_id:, normalized:)
      group = upsert_group(fingerprint, normalized)
      reading = pre_bump_reading(group, normalized)
      occurrence = occurrences.create!(
        occurrence_attributes(occurrence_id, normalized, drop_body: over_cap?(group)).merge(group: group)
      )
      bump_group!(group, normalized, reading)
      Stored.new(group: group, occurrence: occurrence, reading: reading)
    end

    # Punto di variazione: ciò che il dominio deve leggere dal gruppo mentre è ancora PRE-bump. Gli
    # errori ne ricavano sei fatti (nuovo, era risolto, era aperto, titolo cambiato, utente mai visto,
    # tocca lavorare in questa raffica); le performance non hanno niente da leggere e restano a nil.
    def pre_bump_reading(_group, _normalized) = nil

    # Passo 6 — fonte OSSERVATA (l'sdk che ha mandato il dato): upsert atomico autonomo FUORI dalla
    # transazione del gruppo (CYRA-42). Dentro contenderebbe la riga hot projects_sources tenendo il
    # lock fino al commit di una transazione già contesa sull'UPDATE degli aggregati. No-op se manca
    # l'identità del client.
    def track_source(normalized)
      ::Ingest::SourceTracking.track_one(project: @project, normalized: normalized)
    end

    # Stessa cosa per un lotto: una sola registrazione per POST, non una per campione.
    def track_source_batch(items)
      ::Ingest::SourceTracking.track_batch(project: @project, items: items)
    end

    # I tre pezzi che ogni dominio deve dichiarare per suo conto.
    def new_group(_group, _normalized) = raise(NotImplementedError)
    def occurrence_attributes(_id, _normalized, drop_body: false) = raise(NotImplementedError)
    def bump_group!(_group, _normalized, _reading) = raise(NotImplementedError)
  end
end
