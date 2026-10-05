# frozen_string_literal: true

module Agents
  class Plan < ApplicationRecord
    belongs_to :workflow, class_name: "Agents::Workflow", inverse_of: :plans
    belongs_to :attempt, class_name: "Agents::Attempt"
    belongs_to :approved_by, class_name: "Accounts::Account", optional: true

    # Il piano è testo scritto da un agente e letto da una persona che deve approvarlo: l'ortografia
    # italiana si sistema prima del salvataggio (vedi Text::ItalianOrthography). scenarios/DoD/note
    # sono jsonb di forma variabile (stringhe o hash, a seconda del planner) → correzione ricorsiva
    # sulle sole stringhe. `change_request` resta fuori: quello lo scrive chi rifiuta il piano.
    normalizes :technical_analysis, with: ->(value) { Text::ItalianOrthography.correct(value).strip }
    normalizes :decision_brief, with: ->(value) { Text::ItalianOrthography.correct(value).strip.presence }
    normalizes :scenarios, with: ->(value) { Text::ItalianOrthography.correct_deep(value) }
    normalizes :definition_of_done, with: ->(value) { Text::ItalianOrthography.correct_deep(value) }
    normalizes :notes, with: ->(value) { Text::ItalianOrthography.correct_deep(value) }
    normalizes :content, with: ->(value) { PlanDocument.normalize_content(value) }

    # CYRA-601 — le due decisioni che l'operatore congela approvando il piano: su quali repository si
    # può lavorare per questo ticket, e come si proverà che il lavoro è arrivato davvero in fondo.
    # NULL = non ancora congelata; una volta scritta non si riscrive.
    FROZEN_DECISION_COLUMNS = %i[candidate_items completion_probe].freeze

    # CYRA-610 — le due decisioni, come le legge chi deve ancora approvare e come le scrive
    # l'approvazione. `missing` dice QUALE pezzo manca, non «manca qualcosa»: sono due configurazioni
    # diverse, si sistemano in due posti diversi, e un avviso che non lo distingue manda a cercare.
    #
    # Non è mai il payload dell'agente a comporla: si legge solo ciò che una persona ha già
    # configurato sul progetto. Un dato scritto dall'agente sarebbe una dichiarazione, ed è
    # esattamente quello che qui si sta togliendo di mezzo.
    Decision = Data.define(:candidate_items, :completion_probe, :missing) do
      def frozen? = missing.nil?
    end

    # Nessuna chiamata a GitHub: si leggono le colonne del collegamento progetto↔archivio, che una
    # persona ha compilato. Approvare un piano non deve poter restare appeso perché GitHub non
    # risponde — e sta dentro la transazione dell'approvazione.
    def self.decision_for(ticket)
      repository = ticket&.project&.github_repository
      return Decision.new(candidate_items: nil, completion_probe: nil, missing: :repository) if repository.nil?
      return Decision.new(candidate_items: nil, completion_probe: nil, missing: :probe) if repository.release_probe.blank?

      Decision.new(
        candidate_items: [ { "repo" => repository.full_name, "base" => repository.default_branch } ],
        completion_probe: probe_for(repository),
        missing: nil
      )
    end

    def document = PlanDocument.new(self)

    # `deploy_smoke` è l'unica prova che ha bisogno di una coordinata in più: senza l'ambiente di
    # produzione non si sa DOVE andare a guardare se il rilascio è in piedi. Il modello e il database
    # già impediscono quella scelta senza l'ambiente, quindi qui la coordinata c'è per costruzione.
    def self.probe_for(repository)
      probe = { "kind" => repository.release_probe, "repo" => repository.full_name }
      probe["environment_id"] = repository.production_environment_id if repository.release_probe_deploy_smoke?
      # CYRA-625 — su quale scaffale guardare e con che nome chiedere. Congelate qui insieme al
      # resto: fra l'approvazione e il rilascio qualcuno può cambiarle sul progetto, e la prova deve
      # cercare quello che si era deciso di cercare.
      probe.merge!("registry" => repository.registry, "package" => repository.package_name) if
        repository.release_probe_publish?
      probe
    end
    private_class_method :probe_for

    validates :technical_analysis, :ticket_snapshot_digest, presence: true
    validates :contract_version, inclusion: { in: [ 1, 2 ] }
    validate :structured_content_matches_contract
    validates :version, numericality: { only_integer: true, greater_than: 0 },
                        uniqueness: { scope: :workflow_id }
    before_validation :assign_version, on: :create
    # Non `attr_readonly`: con `load_defaults 8.1` solleva su una riga GIÀ SALVATA, e la scrittura
    # legittima di queste due colonne avviene proprio così — all'approvazione, su un piano salvato
    # da tempo. Bloccherebbe la scrittura giusta insieme a quelle sbagliate, e il difetto uscirebbe
    # solo al primo tentativo vero. Qui la regola è quella esatta: si scrive una volta, non zero.
    validate :frozen_decision_written_once, on: :update

    private

    def structured_content_matches_contract
      return if contract_version == 1 && content == {}
      return if contract_version == 2 && content.is_a?(Hash) && content.present?

      errors.add(:content, "non corrisponde alla versione del contratto")
    end

    # Fuori dalla guardia restano `update_all`, `update_columns` e l'SQL grezzo, che saltano le
    # validazioni per definizione: nessun punto dell'applicazione scrive queste colonne per quelle vie,
    # ed è uno spec a tenerlo vero (non basta dirlo qui).
    def frozen_decision_written_once
      FROZEN_DECISION_COLUMNS.each do |column|
        next unless will_save_change_to_attribute?(column)
        next if attribute_in_database(column).nil?

        errors.add(column, :readonly, message: "è già stata congelata all'approvazione e non si riscrive")
      end
    end

    def assign_version
      self.version ||= workflow&.plans&.maximum(:version).to_i + 1
    end
  end
end
