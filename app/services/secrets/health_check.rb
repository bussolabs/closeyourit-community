# frozen_string_literal: true

module Secrets
  # Health-check org-wide del Vault (CYRA-137, Fase 3 pezzo 4/4): raccoglie in un solo posto, sui
  # progetti VISIBILI passati, 3 categorie di anomalia dei secret — invece di scoprirle progetto
  # per progetto. Pensato per Member::Vault::HealthController (gate org-level secrets_audit.view,
  # stesso permesso di Secrets::AuditQuery).
  #
  # Tutto il carico dati e' PRECARICATO in blocco (poche query fisse, indipendenti dal numero di
  # progetti passati) — MAI una query per-progetto dentro un loop: il guard Prosopite sui request
  # spec e' bloccante (raise = true, vedi spec/support/prosopite.rb).
  #
  # 1) Deleghe shared rotte/orfane (#broken_delegations): una Secrets::Shared::Delegation il cui
  #    shared_value punta a un ambiente che il progetto delegatario non dichiara piu' (join
  #    Connections::ProjectEnvironment assente — es. Member::ProjectEnvironmentsController#destroy,
  #    che rimuove la dichiarazione senza toccare le deleghe) o non ha piu' attivo (
  #    Types::Environment#active? false, togglabile in Member::EnvironmentsController#update senza
  #    alcuna validazione sull'uso esistente). Le altre due forme di "orfano" teoricamente possibili
  #    sono IMPOSSIBILI PER COSTRUZIONE e non sono quindi controllate qui:
  #      - shared_value/shared_variable cancellati: entrambi hanno dependent: :destroy lato Rails
  #        E on_delete: :cascade lato DB sulla FK di secrets_shared_delegations/secrets_shared_values
  #        (db/schema.rb) — una delega non puo' sopravvivere alla cancellazione del suo shared_value.
  #      - project cancellato: stessa doppia garanzia (dependent: :destroy su Project +
  #        on_delete: :cascade sulla FK project_id di secrets_shared_delegations).
  # 2) Progetti con buchi drift cross-ambiente (#drifted_projects): riusa Secrets::Drift (pezzo 1
  #    della stessa fase), ricostruendo rows/environments come fa
  #    Member::ProjectSecretsController#load_matrix ma sui dati gia' precaricati qui (nessuna query
  #    aggiuntiva per progetto).
  # 3) Coppie [progetto, ambiente] dichiarate+attive ma senza alcuna Secrets::Variable
  #    (#empty_environments).
  class HealthCheck
    BrokenDelegation = Data.define(:delegation, :project)
    DriftedProject = Data.define(:project, :holes_count, :affected_names_count)
    EmptyEnvironment = Data.define(:project, :environment)

    # Descrittore ATOMICO di una singola anomalia (CYRA-409): un buco = una cella [progetto, ambiente,
    # variabile], non un conteggio per progetto. È la forma su cui la pagina "Cosa non torna" costruisce
    # le righe (nome della variabile + ambiente in cui manca) e su cui Secrets::Health::RecordAnomalies
    # ritrova il record persistito. `identity` è la chiave stabile [project_id, environment_id, kind,
    # secret_name] usata sia dall'unique index sia dal match col record.
    Anomaly = Data.define(:kind, :project, :environment, :secret_name) do
      def identity = [ project.id, environment.id, kind, secret_name ]
    end

    def initialize(projects:)
      @projects = projects.to_a
      @project_ids = @projects.map(&:id)
    end

    # Deleghe la cui shared_value punta a un ambiente non (piu') dichiarato+attivo sul progetto
    # delegatario. `projects_by_id.fetch` non ha bisogno di un fallback nil-safe: `delegations` e'
    # gia' scoped a where(project_id: @project_ids), quindi ogni delegation.project_id compare
    # sempre in projects_by_id (stessa lista di id).
    def broken_delegations
      @broken_delegations ||= delegations.filter_map do |delegation|
        project = projects_by_id.fetch(delegation.project_id)
        active_ids = active_environment_ids_by_project[project.id] || []
        next if active_ids.include?(delegation.environment.id)

        BrokenDelegation.new(delegation: delegation, project: project)
      end.sort_by { |broken| [ broken.project.name.downcase, broken.delegation.effective_name ] }
    end

    # Progetti la cui matrice secrets ha almeno un buco cross-ambiente (Secrets::Drift#any?).
    def drifted_projects
      @drifted_projects ||= @projects.filter_map do |project|
        drift = drift_for(project)
        next unless drift.any?

        DriftedProject.new(project: project, holes_count: drift.holes_count,
                            affected_names_count: drift.affected_names_count)
      end.sort_by { |drifted| drifted.project.name.downcase }
    end

    # Coppie [progetto, ambiente] dichiarate+attive ma senza alcun Secrets::Variable.
    def empty_environments
      @empty_environments ||= @projects.flat_map do |project|
        environment_ids_with_values = variable_environment_ids_by_project[project.id] || []
        (active_environments_by_project[project.id] || []).filter_map do |environment|
          next if environment_ids_with_values.include?(environment.id)

          EmptyEnvironment.new(project: project, environment: environment)
        end
      end.sort_by { |empty_environment| [ empty_environment.project.name.downcase, empty_environment.environment.label.downcase ] }
    end

    def total_count
      broken_delegations.size + drifted_projects.size + empty_environments.size
    end

    def any?
      total_count.positive?
    end

    # Tutte le anomalie in forma ATOMICA e uniforme (CYRA-409): una per cella-buco (drift), una per
    # ambiente vuoto, una per delega rotta. È ciò che la pagina "Cosa non torna" mostra riga per riga e
    # che Secrets::Health::RecordAnomalies persiste per ricavarne first_seen_at e l'acknowledge. Riusa i
    # metodi esistenti e i dati già precaricati — nessuna query nuova.
    def anomalies
      @anomalies ||= drift_hole_anomalies + broken_delegation_anomalies + empty_environment_anomalies
    end

    private

    def drift_hole_anomalies
      @projects.flat_map do |project|
        environments_by_id = (active_environments_by_project[project.id] || []).index_by(&:id)
        drift_for(project).holes.flat_map do |name, environment_ids|
          environment_ids.map do |environment_id|
            Anomaly.new(kind: :drift_hole, project: project,
                        environment: environments_by_id.fetch(environment_id), secret_name: name)
          end
        end
      end
    end

    def broken_delegation_anomalies
      broken_delegations.map do |broken|
        Anomaly.new(kind: :broken_delegation, project: broken.project,
                    environment: broken.delegation.environment, secret_name: broken.delegation.effective_name)
      end
    end

    def empty_environment_anomalies
      empty_environments.map do |empty|
        Anomaly.new(kind: :empty_environment, project: empty.project,
                    environment: empty.environment, secret_name: "")
      end
    end

    def projects_by_id
      @projects_by_id ||= @projects.index_by(&:id)
    end

    # Deleghe dei SOLI progetti passati (scoping anti-BOLA: un progetto non incluso non contribuisce
    # al risultato). shared_value → environment/shared_variable precaricati (delegate su
    # Secrets::Shared::Delegation#name/#environment): 1 query + includes, non una per progetto.
    def delegations
      @delegations ||= ::Secrets::Shared::Delegation
        .where(project_id: @project_ids)
        .includes(shared_value: %i[environment shared_variable])
        .to_a
    end

    # Righe join dichiarate dai progetti passati, con l'ambiente precaricato — 1 query + includes,
    # non una per progetto.
    def project_environments
      @project_environments ||= ::Connections::ProjectEnvironment
        .where(project_id: @project_ids)
        .includes(:environment)
        .to_a
    end

    # { project_id => [Types::Environment dichiarati E attivi, ordinati] } — stesso filtro/ordine di
    # `@project.environments.active.ordered` nel controller (Member::ProjectSecretsController),
    # calcolato in Ruby sui dati gia' caricati (nessuna query per progetto).
    def active_environments_by_project
      @active_environments_by_project ||= project_environments.group_by(&:project_id).transform_values do |links|
        links.map(&:environment).select(&:active?).sort_by { |environment| [ environment.position, environment.label ] }
      end
    end

    def active_environment_ids_by_project
      @active_environment_ids_by_project ||=
        active_environments_by_project.transform_values { |environments| environments.map(&:id) }
    end

    # Variabili locali dei soli progetti passati. Niente .includes(:environment): qui serve solo
    # l'environment_id (già colonna sul record) — un preload in più sarebbe una query sprecata.
    def variables
      @variables ||= ::Secrets::Variable.where(project_id: @project_ids).to_a
    end

    def variable_environment_ids_by_project
      @variable_environment_ids_by_project ||=
        variables.group_by(&:project_id).transform_values { |vars| vars.map(&:environment_id) }
    end

    # { project_id => [[nome, {environment_id => Variable}], ...] } — stessa forma di @rows di
    # Member::ProjectSecretsController#load_matrix, costruita sui dati gia' caricati qui.
    def rows_by_project
      @rows_by_project ||= variables.group_by(&:project_id).transform_values do |vars|
        vars.group_by(&:name).transform_values { |vs| vs.index_by(&:environment_id) }.sort_by(&:first)
      end
    end

    def drift_for(project)
      ::Secrets::Drift.new(rows: rows_by_project[project.id] || [],
                            environments: active_environments_by_project[project.id] || [])
    end
  end
end
