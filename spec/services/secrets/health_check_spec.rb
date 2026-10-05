# frozen_string_literal: true

require "rails_helper"

# Health-check org-wide del Vault (CYRA-137, Fase 3 pezzo 4): raccoglie sui progetti VISIBILI
# passati le 3 categorie di anomalia. Nessuna query per-progetto in loop (vedi commenti nel
# service) — verificato anche dal request spec (guard Prosopite bloccante).
RSpec.describe Secrets::HealthCheck do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  # Crea (se serve) un Types::Environment con quel code nell'org e lo dichiara sul progetto
  # (Connections::ProjectEnvironment) — passi separati ed espliciti, mai la scorciatoia
  # `project.environments << env` usata altrove nel repo (qui servirebbe rifare il join a mano
  # per "romperlo" più avanti, quindi meglio costruirlo esplicitamente fin da subito).
  def declare_environment(target_project, code:)
    environment = create(:environment, organization: target_project.organization, code: code)
    create(:project_environment, project: target_project, environment: environment)
    environment
  end

  describe "#broken_delegations" do
    it "rileva una delega shared rotta quando il progetto non dichiara più l'ambiente del valore condiviso" do
      production = declare_environment(project, code: "production")
      shared = Secrets::Shared::Save.call(organization: org, environment: production, name: "API_KEY", value: "one").value
      Secrets::Shared::Delegate.call(shared_value: shared, project: project)
      # Member::ProjectEnvironmentsController#destroy: rimuove la dichiarazione, la delega resta.
      project.project_environments.find_by(environment: production).destroy

      health = described_class.new(projects: [ project ])

      expect(health.broken_delegations.size).to eq(1)
      broken = health.broken_delegations.first
      expect(broken.project).to eq(project)
      expect(broken.delegation.name).to eq("API_KEY")
      expect(health.any?).to be(true)
    end

    it "rileva una delega shared rotta quando l'ambiente collegato è disattivato per l'intera organizzazione" do
      production = declare_environment(project, code: "production")
      shared = Secrets::Shared::Save.call(organization: org, environment: production, name: "DB_URL", value: "one").value
      Secrets::Shared::Delegate.call(shared_value: shared, project: project)
      # Member::EnvironmentsController#update: l'ambiente resta dichiarato ma non più attivo.
      production.update!(active: false)

      health = described_class.new(projects: [ project ])

      expect(health.broken_delegations.size).to eq(1)
      expect(health.broken_delegations.first.delegation.name).to eq("DB_URL")
    end

    it "non segnala una delega ancora valida (ambiente dichiarato e attivo)" do
      production = declare_environment(project, code: "production")
      shared = Secrets::Shared::Save.call(organization: org, environment: production, name: "OK_VAR", value: "one").value
      Secrets::Shared::Delegate.call(shared_value: shared, project: project)

      health = described_class.new(projects: [ project ])

      expect(health.broken_delegations).to be_empty
    end
  end

  describe "#drifted_projects" do
    it "un progetto con buchi drift compare (riusa Secrets::Drift)" do
      production = declare_environment(project, code: "production")
      declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "PARTIAL")
      # PARTIAL manca in staging → 1 buco.

      health = described_class.new(projects: [ project ])

      expect(health.drifted_projects.size).to eq(1)
      drifted = health.drifted_projects.first
      expect(drifted.project).to eq(project)
      expect(drifted.holes_count).to eq(1)
      expect(drifted.affected_names_count).to eq(1)
      expect(health.any?).to be(true)
    end

    it "nessun progetto con buchi quando la matrice è completa su tutti gli ambienti attivi" do
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "COMPLETE")
      create(:secret_variable, project: project, environment: staging, name: "COMPLETE")

      health = described_class.new(projects: [ project ])

      expect(health.drifted_projects).to be_empty
    end
  end

  describe "#empty_environments" do
    it "un ambiente dichiarato e attivo senza alcun secret compare" do
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "ONLY_PROD")
      # staging è dichiarato+attivo ma senza nessuna Secrets::Variable.

      health = described_class.new(projects: [ project ])

      expect(health.empty_environments.size).to eq(1)
      empty_environment = health.empty_environments.first
      expect(empty_environment.project).to eq(project)
      expect(empty_environment.environment).to eq(staging)
      expect(health.any?).to be(true)
    end

    it "nessun ambiente vuoto quando ogni ambiente dichiarato ha almeno un secret" do
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "A")
      create(:secret_variable, project: project, environment: staging, name: "B")

      health = described_class.new(projects: [ project ])

      expect(health.empty_environments).to be_empty
    end
  end

  describe "stato pulito" do
    it "zero anomalie in tutte le categorie quando non c'è nulla da segnalare" do
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "OK")
      create(:secret_variable, project: project, environment: staging, name: "OK")

      health = described_class.new(projects: [ project ])

      expect(health.broken_delegations).to be_empty
      expect(health.drifted_projects).to be_empty
      expect(health.empty_environments).to be_empty
      expect(health.any?).to be(false)
    end

    it "un progetto senza alcun ambiente dichiarato non genera anomalie" do
      health = described_class.new(projects: [ project ])

      expect(health.any?).to be(false)
    end
  end

  describe "#anomalies (forma atomica, CYRA-409)" do
    it "un buco drift diventa un'anomalia per cella [progetto, ambiente, variabile]" do
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "PARTIAL")
      # PARTIAL presente in production, assente in staging → 1 buco su staging.

      health = described_class.new(projects: [ project ])
      drift = health.anomalies.select { |a| a.kind == :drift_hole }

      expect(drift.size).to eq(1)
      expect(drift.first.secret_name).to eq("PARTIAL")
      expect(drift.first.environment).to eq(staging)
      expect(drift.first.project).to eq(project)
    end

    it "una variabile assente in due ambienti diventa due anomalie distinte" do
      production = declare_environment(project, code: "production")
      declare_environment(project, code: "staging")
      declare_environment(project, code: "preprod")
      create(:secret_variable, project: project, environment: production, name: "ONLY_PROD")

      health = described_class.new(projects: [ project ])
      drift = health.anomalies.select { |a| a.kind == :drift_hole }

      expect(drift.size).to eq(2)
      expect(drift.map(&:secret_name).uniq).to eq([ "ONLY_PROD" ])
    end

    it "un ambiente vuoto e una delega rotta compaiono con la loro categoria" do
      production = declare_environment(project, code: "production")
      declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "ONLY_PROD")
      # staging dichiarato+attivo, senza secret → ambiente vuoto.
      shared = Secrets::Shared::Save.call(organization: org, environment: production, name: "BROKEN", value: "x").value
      Secrets::Shared::Delegate.call(shared_value: shared, project: project)
      project.project_environments.find_by(environment: production).destroy

      health = described_class.new(projects: [ project ])

      empty = health.anomalies.select { |a| a.kind == :empty_environment }
      broken = health.anomalies.select { |a| a.kind == :broken_delegation }
      expect(empty.map { |a| a.environment.code }).to include("staging")
      expect(empty.first.secret_name).to eq("")
      expect(broken.first.secret_name).to eq("BROKEN")
    end

    it "ogni anomalia espone una identità stabile [project_id, environment_id, kind, secret_name]" do
      production = declare_environment(project, code: "production")
      declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "PARTIAL")

      anomaly = described_class.new(projects: [ project ]).anomalies.first

      expect(anomaly.identity).to eq([ anomaly.project.id, anomaly.environment.id, anomaly.kind, anomaly.secret_name ])
    end
  end

  describe "scoping ai soli progetti passati" do
    it "le anomalie di un progetto non incluso non contribuiscono al risultato" do
      other_project = create(:project, organization: org)
      other_production = declare_environment(other_project, code: "other_production")
      declare_environment(other_project, code: "other_staging")
      # 2 anomalie sul progetto NON passato al service: delega rotta (other_production viene
      # dichiarata, delegata e poi ri-tolta) + ambiente vuoto (other_staging resta dichiarato e
      # attivo ma senza alcun secret).
      shared = Secrets::Shared::Save.call(organization: org, environment: other_production, name: "OTHER_KEY", value: "one").value
      Secrets::Shared::Delegate.call(shared_value: shared, project: other_project)
      other_project.project_environments.find_by(environment: other_production).destroy

      # Il progetto passato al service è invece pulito.
      production = declare_environment(project, code: "production")
      staging = declare_environment(project, code: "staging")
      create(:secret_variable, project: project, environment: production, name: "OK")
      create(:secret_variable, project: project, environment: staging, name: "OK")

      health = described_class.new(projects: [ project ])

      expect(health.broken_delegations).to be_empty
      expect(health.drifted_projects).to be_empty
      expect(health.empty_environments).to be_empty
      expect(health.any?).to be(false)
    end
  end
end
