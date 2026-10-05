# frozen_string_literal: true

module Secrets
  module Github
    # Valida e prepara tutti gli slot prima del sync. Gira sia nella request "Sync now" (feedback
    # immediato, prima di accodare) sia nel job (guard contro cambiamenti avvenuti dopo il preflight).
    #
    # Un valore null significa che il vault non possiede un plaintext valido e resta fail-closed
    # (CYRA-213). La stringa vuota, invece, è un valore esplicito e legittimo per configurazioni
    # opzionali: JSON la conserva come "", senza trasformarla nel token null.
    class Preflight < ApplicationService
      PreparedSlot = Data.define(:name, :bundle, :secrets_json)

      SLOTS = { "production" => :production_environment, "staging" => :staging_environment,
                "preview" => :preview_environment }.freeze

      def initialize(repository:, client: ::Github::Client.new)
        @repository = repository
        @client = client
      end

      def call
        return Result.err(guard_error("push dei secret non abilitato sul repo")) unless @repository&.sync_secrets?
        return Result.err(guard_error("installazione GitHub assente")) if @repository.installation&.installation_id.blank?

        installation_id = @repository.installation.installation_id
        # CYRA-637 — uno slot senza ambiente collegato veniva scartato in silenzio: il sync scriveva
        # sugli altri, scriveva «riuscita» e nessun campo diceva che mancava qualcosa. Il guasto
        # usciva mesi dopo, al primo rilascio in produzione, con la cassetta di quell'ambiente vuota
        # (visto su legalbloom-rails: staging pieno, production no, e nessuno se n'era accorto).
        #
        # Fail-closed, ma sulla domanda giusta: non «tutti e tre gli slot», che romperebbe chiunque
        # ne usi uno solo di proposito — bensì «il progetto ha un ambiente che porta questo nome e il
        # repository non lo mappa». Lì il silenzio non è una scelta di nessuno: è una svista.
        return Result.err(unmapped_error(unmapped_slots)) if unmapped_slots.any?

        slots = SLOTS.filter_map do |env_name, association|
          source_environment = @repository.public_send(association)
          next if source_environment.nil?

          # `account: nil` ESPLICITO (CYRA-79): questo bundle finisce nei secret di un repo, dove lo usa
          # chiunque faccia girare la pipeline. Gli override PERSONALI non devono entrarci mai — e il
          # nil dev'essere scritto, non sottinteso, perché è una decisione di sicurezza e non un default
          # capitato così.
          bundle = ::Secrets::Bundle.call(project: @repository.project, environment: source_environment,
                                          account: nil).value
                                    .except(*::Secrets::Github::SecretsJson::RESERVED_NAMES)
          unset = bundle.select { |_name, value| value.nil? }.keys.sort
          return Result.err(unset_error(unset, env_name)) if unset.any?

          derived = ::Secrets::Github::SecretsJson.call(
            repository: @repository, slot: env_name, bundle:, client: @client, installation_id:
          )
          return Result.err(with_slot(derived.error, env_name)) if derived.err?

          PreparedSlot.new(name: env_name, bundle:, secrets_json: derived.value)
        end

        # Nemmeno un ambiente da scrivere: il sync uscirebbe con {pushed: 0, deleted: 0} e si
        # dichiarerebbe riuscito senza aver toccato niente. Non è una sincronizzazione, è un nulla
        # che si firma.
        return Result.err(nothing_to_sync_error) if slots.empty?

        Result.ok(slots)
      rescue ::Github::Client::Error => e
        Result.err(AppError.new(e.message, code: e.code, status: e.status))
      end

      private

      def guard_error(message) = AppError.new(message, code: "R422-GITHUB-006")

      # Gli slot che avrebbero qualcosa da scrivere e che il repository non ha collegato.
      #
      # Uno slot occupato non è mai in questa lista, qualunque ambiente porti: quel mapping esiste, e
      # dichiararlo dimenticato fermerebbe un repository a posto (revisione Codex). Su uno slot libero
      # ci sono due modi di avere qualcosa da scrivere, e servono entrambi:
      #
      #   - il progetto ha l'ambiente omonimo e dentro c'è roba (variabili proprie o valori condivisi);
      #   - su quello slot il vault ha già scritto in passato (`synced_secret_names`), e quei valori
      #     sono rimasti su GitHub. Vale anche se l'ambiente che c'era portava un codice tutto suo:
      #     lì non esiste nessun ambiente omonimo da trovare, e senza questo ramo i valori orfani non
      #     li nominerebbe nessuno.
      #
      # NOTA su `preview`: la scelta «Nessun mapping» resta legittima nella UI, ma un ambiente
      # popolato e scollegato si ferma come gli altri. Oggi non tocca nessun progetto (nessuno ha
      # `preview` con dei valori dentro); il giorno che servisse tenerne uno fuori di proposito,
      # serve un consenso esplicito per slot — è un altro lavoro, non un caso da sottintendere qui.
      def unmapped_slots
        @unmapped_slots ||= begin
          mapped_ids = SLOTS.each_value.filter_map { |association| @repository.public_send(:"#{association}_id") }
          candidates = @repository.project.environments
                                 .where(code: SLOTS.keys).where.not(id: mapped_ids)
                                 .pluck(:id, :code)
          filled = environments_with_content(candidates.map(&:first))
          SLOTS.select do |code, association|
            id = candidates.find { |_id, candidate_code| candidate_code == code }&.first
            # I due criteri sono indipendenti (revisione Codex). Un ambiente omonimo pieno e collegato
            # a NESSUNO slot va detto anche quando lo slot che porta il suo nome è occupato da un
            # altro: il suo contenuto non finisce da nessuna parte, ed è il guasto del ticket. I nomi
            # tracciati invece parlano dello SLOT, quindi valgono solo se quello è libero.
            slot_free = @repository.public_send(:"#{association}_id").nil?
            (id && filled.include?(id)) || (slot_free && Array(@repository.synced_secret_names[code]).any?)
          end.keys
        end
      end

      # «Qualcosa da scrivere» sono entrambe le sorgenti che `Secrets::Bundle` unisce: le variabili del
      # progetto E i valori condivisi delegati (revisione Codex). Un ambiente che vive di soli valori
      # condivisi non è vuoto, e saltarlo in silenzio è lo stesso guasto.
      #
      # Due query fisse, mai una per candidato: qui si passa dentro una richiesta web, e Prosopite
      # boccia le ripetizioni.
      def environments_with_content(ids)
        return Set.new if ids.empty?

        project = @repository.project
        # I nomi che il sync calcola da sé non contano come roba da scrivere: il preflight li toglie
        # comunque dal bundle, quindi un ambiente che ha soltanto quelli non produce nessuna
        # sincronizzazione parziale, e fermarsi lì sarebbe un rosso su un lavoro che non esiste.
        #
        # Il filtro serve su ENTRAMBE le sorgenti, e non per prudenza (revisione Codex). La validazione
        # di `Secrets::Variable` guarda le scritture nuove, ma nel vault ci sono righe più vecchie di
        # quella regola: cinque progetti portano ancora `KAMAL_SECRETS_JSON` come variabile vera. Sui
        # valori condivisi quel divieto non c'è mai stato — `Secrets::Shared::Variable` vieta il solo
        # prefisso GITHUB_ — e lì il nome vive sulla variabile condivisa, non sulla delega né sul
        # valore: la join arriva fin là, come fa `Secrets::Bundle`.
        reserved = ::Secrets::Github::SecretsJson::RESERVED_NAMES
        with_variables = ::Secrets::Variable.where(project:, environment_id: ids)
                                           .where.not(name: reserved).distinct.pluck(:environment_id)
        with_delegations = ::Secrets::Shared::Delegation
                       .joins(shared_value: :shared_variable)
                       .where(project:, secrets_shared_values: { environment_id: ids })
                       .where.not("COALESCE(secrets_shared_delegations.local_name, secrets_shared_variables.name) IN (?)", reserved)
                       .distinct.pluck("secrets_shared_values.environment_id")
        (with_variables + with_delegations).to_set
      end

      def unmapped_error(names)
        AppError.new(
          "ambienti del progetto non collegati al repository: #{names.join(', ')}. " \
          "Una sincronizzazione che non può scrivere ovunque è attesa non si dichiara riuscita",
          code: "R422-GITHUB-011", details: { unmapped: names }
        )
      end

      def nothing_to_sync_error
        AppError.new(
          "nessun ambiente collegato: non c'è niente da sincronizzare",
          code: "R422-GITHUB-011", details: { unmapped: [] }
        )
      end

      def unset_error(names, slot)
        AppError.new("variabili senza valore", code: "R422-GITHUB-009", details: { unset: names, slot: })
      end

      # CYRA-106 — l'errore dice SEMPRE su quale slot si è fermato. Il sync esce al primo che fallisce
      # e gli altri non vengono nemmeno tentati: senza lo slot, chi legge l'esito nella scheda sa che
      # qualcosa non va ma non quale file di configurazione andare a correggere.
      def with_slot(error, slot)
        AppError.new(error.message, code: error.code, status: error.status,
                     details: error.details.to_h.merge(slot:))
      end
    end
  end
end
