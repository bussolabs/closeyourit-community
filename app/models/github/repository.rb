# frozen_string_literal: true

module Github
  # Link repo GitHub ↔ progetto, 1:1 nei due sensi (un progetto ≤1 repo, un repo ≤1 progetto), più le
  # REGOLE di binding tag→release dal setting del progetto: `production_environment`/`staging_environment`
  # mappano stabilità→environment (tag stabile→prod, pre-release→staging), `tag_binding_enabled` abilita
  # il binding, `autoclose_on_merge` chiude il ticket alla merge della PR. Le chiamate API GitHub usano
  # l'`installation` dell'org (installation-token effimero).
  class Repository < ApplicationRecord
    # CYRA-106 — esito dell'ULTIMO invio dei secret verso GitHub. Il job che lo esegue è
    # fire-and-forget: un fallimento tornava come Result.err senza sollevare, quindi la scheda del
    # progetto restava identica a quella di un invio riuscito e la configurazione rotta si scopriva
    # giorni dopo, dai log della pipeline. `nil` è il terzo stato e va tenuto distinto dai due: «mai
    # tentato» non è «riuscito».
    SYNC_OK = "ok"
    SYNC_ERROR = "error"
    # Il messaggio libero di un errore di trasporto arriva da GitHub, quindi è testo che non scriviamo
    # noi: si conserva troncato, e la scheda lo mostra solo quando il codice non ha una spiegazione
    # nostra da leggere al suo posto.
    SYNC_ERROR_MESSAGE_LIMIT = 200

    # CYRA-601 — che fatto osservato vale come «rilasciato davvero» su questo repository:
    # `deploy_smoke` la produzione risponde con quella versione, `publish` il pacchetto compare sul
    # registro pubblico, `merge` il codice è unito e basta. NULL è il terzo stato e va tenuto distinto
    # dai tre: «non ancora deciso» non è «deploy», ed è il valore di tutti i repository esistenti.
    #
    # CYRA-605 — `validate:` non è cosmetico: senza, un valore che non sta nell'elenco solleva un 500
    # invece di rispondere «questo valore non esiste». Chi usa la riga di comando riceverebbe un
    # guasto del server al posto di un errore che si legge.
    #
    # `allow_nil` è obbligatorio, non un dettaglio: NULL è il terzo stato e il valore di OGNI
    # repository che esiste oggi. Con la validazione secca ogni progetto già agganciato diventerebbe
    # non salvabile — e non per qualcosa che qualcuno ha fatto, ma per non aver ancora scelto.
    enum :release_probe, { deploy_smoke: 0, publish: 1, merge: 2 }, prefix: true,
         validate: { allow_nil: true }

    # CYRA-625 — dove va a guardare chi installa il pacchetto, e con che nome lo chiede. Sono le due
    # coordinate che il sistema non aveva in casa: senza, l'unica strada sarebbe indovinare il nome
    # dal repository, e il nome del pacchetto non è quasi mai quello del repository.
    #
    # `docker` sta in elenco perché il descrittore lo deve poter dichiarare: la lettura di quello
    # scaffale ha bisogno di una credenziale di sola lettura che oggi non esiste, e la lavorazione lo
    # dice al momento della consegna invece di aspettare un'ora in silenzio.
    enum :registry, { npm: 0, pub: 1, rubygems: 2, pypi: 3, docker: 4 }, prefix: true,
         validate: { allow_nil: true }

    # Gemella del vincolo di database (`github_repositories_deploy_smoke_needs_production`). Il
    # vincolo copre chi scrive saltando il modello; questa copre chi passa dal modello, e risponde
    # con un errore leggibile invece che con una violazione di database.
    #
    # Vale nei DUE sensi: non si può scegliere «il rilascio è in piedi» senza l'ambiente di
    # produzione, e non si può togliere l'ambiente di produzione a un progetto che ha già fatto
    # quella scelta — la seconda è la strada per cui l'incoerenza entrerebbe di soppiatto.
    validate :deploy_smoke_needs_a_production_environment
    # Gemella del vincolo di database (`github_repositories_publish_needs_registry`), nei due sensi
    # come l'altra: chi dichiara «il pacchetto compare sullo scaffale» deve dire su quale e con che
    # nome, e non si tolgono le coordinate a un progetto che quella scelta l'ha già fatta.
    validate :publish_needs_registry_coordinates

    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :github_repository
    belongs_to :installation,
               class_name: "Github::Installation",
               inverse_of: :repositories
    # CYRA-762 — `installation_id` qui è la chiave interna (UUID); il NUMERO che GitHub vuole nelle
    # chiamate sta sull'installazione. Cinque servizi del flusso agenti passavano l'UUID al client,
    # GitHub rispondeva 404 e il sistema lo raccontava come «proposta mancante» o «tag illeggibili».
    delegate :installation_id, to: :installation, prefix: :github
    belongs_to :production_environment,
               class_name: "Types::Environment",
               optional: true
    belongs_to :staging_environment,
               class_name: "Types::Environment",
               optional: true
    belongs_to :preview_environment,
               class_name: "Types::Environment",
               optional: true

    has_many :branches,
             class_name: "Github::Branch",
             inverse_of: :repository,
             dependent: :destroy
    has_many :pull_requests,
             class_name: "Github::PullRequest",
             inverse_of: :repository,
             dependent: :destroy

    normalizes :full_name, with: ->(value) { value.to_s.strip }
    normalizes :default_branch, with: ->(value) { value.to_s.strip.presence || "main" }

    validates :project_id, uniqueness: true
    validates :repo_id, presence: true, uniqueness: { scope: :installation_id }
    validates :full_name, presence: true
    validates :default_branch, presence: true
    validate :installation_matches_project_organization
    validate :environments_declared_by_project

    # URL pubblico del repo su GitHub, derivato da full_name (owner/repo). A differenza di
    # Github::Branch/PullRequest, il repository non persiste html_url: è sempre su github.com.
    def html_url = "https://github.com/#{full_name}"

    # Environment target (code) per una release, data la stabilità del tag. nil se il mapping non è
    # configurato per quel lato → nessun binding.
    def target_environment_code(stable:)
      env = stable ? production_environment : staging_environment
      env&.code
    end

    def last_sync_ok? = last_sync_status == SYNC_OK
    def last_sync_failed? = last_sync_status == SYNC_ERROR

    def last_sync_error_code = last_sync_error["code"].presence
    def last_sync_error_message = last_sync_error["message"].presence
    def last_sync_error_slot = last_sync_error["slot"].presence
    def last_sync_error_details = last_sync_error["details"].presence.to_h

    # update_columns e non update!: l'esito è una traccia diagnostica scritta da un job, non una
    # modifica del repo. Non deve toccare updated_at (come già fa il tracciamento dei nomi
    # sincronizzati) né far girare validazioni su un record che qualcuno potrebbe aver riconfigurato
    # proprio mentre il sync girava.
    def record_sync_success!(at: Time.current)
      update_columns(last_sync_at: at, last_sync_status: SYNC_OK, last_sync_error: {})
    end

    # `slot` arriva dal chiamante solo per i guasti che nascono FUORI dal preflight (il trasporto che
    # si rompe a metà push): quelli di configurazione se lo portano già dentro i details.
    #
    # Col push spento non si registra niente: non è un fallimento, è la funzione che non deve girare.
    # Registrarlo dipingerebbe di rosso la scheda di ogni progetto che tiene il toggle giù.
    def record_sync_failure!(error, slot: nil, at: Time.current)
      return false unless sync_secrets?

      update_columns(last_sync_at: at, last_sync_status: SYNC_ERROR,
                     last_sync_error: sync_failure_payload(error, slot))
    end

    private

    def sync_failure_payload(error, slot)
      details = error.details.to_h.stringify_keys
      {
        "code" => error.code,
        "message" => error.message.to_s.truncate(SYNC_ERROR_MESSAGE_LIMIT),
        "slot" => details.delete("slot") || slot,
        "details" => details
      }.compact_blank
    end

    def installation_matches_project_organization
      return if project.blank? || installation.blank?

      errors.add(:installation, :invalid) if installation.organization_id != project.organization_id
    end

    # I due environment di mapping devono essere DICHIARATI dal progetto (subset), come per Projects::Token.
    def environments_declared_by_project
      return if project.blank?

      mapped_ids = [ production_environment_id, staging_environment_id, preview_environment_id ].compact
      errors.add(:base, :environment_not_declared) unless (mapped_ids - project.environment_ids).empty?
    end

    def deploy_smoke_needs_a_production_environment
      return unless release_probe_deploy_smoke?
      return if production_environment_id.present?

      errors.add(:release_probe,
                 "«il rilascio in produzione è in piedi» ha bisogno dell'ambiente di produzione: " \
                 "senza, nessun rilascio vivo verrebbe mai registrato e il lavoro resterebbe fermo")
    end

    def publish_needs_registry_coordinates
      return unless release_probe_publish?
      return if registry.present? && package_name.present?

      errors.add(:registry,
                 "serve lo scaffale e il nome del pacchetto per dire che un rilascio è arrivato davvero")
    end
  end
end
