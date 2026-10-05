# frozen_string_literal: true

require "rails_helper"

# "Cosa ruotare" org-wide (CYRA-138, Fase 4 pezzo A1): raccoglie sui progetti VISIBILI passati le
# variabili con rotation_status due_soon/overdue — gemello di Secrets::HealthCheck. Query PRECARICATA
# in blocco (project+environment), calcolo dello stato in RUBY sui dati già caricati: nessuna query
# per-progetto in loop (guard Prosopite bloccante sui request spec, vedi
# spec/requests/member/vault/rotation_spec.rb).
RSpec.describe Secrets::RotationReport do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

  def variable_overdue(name:, days_ago_rotated: 2, target_project: project, target_environment: environment)
    create(:secret_variable, project: target_project, environment: target_environment, name:,
           rotation_interval_days: 1, rotated_at: Time.current - days_ago_rotated.days)
  end

  def variable_due_soon(name:, target_project: project, target_environment: environment)
    create(:secret_variable, project: target_project, environment: target_environment, name:,
           rotation_interval_days: 14, rotated_at: Time.current)
  end

  def variable_ok(name:, target_project: project, target_environment: environment)
    create(:secret_variable, project: target_project, environment: target_environment, name:,
           rotation_interval_days: 90, rotated_at: Time.current)
  end

  # Segreto SENZA regola di rotazione (rotation_interval_days nil) con un'età del valore nota
  # (rotated_at): il caso su cui il ticket vuole dare visibilità (copertura + età), non più nascosto.
  def variable_uncovered(name:, value_age_days:, target_project: project, target_environment: environment)
    create(:secret_variable, project: target_project, environment: target_environment, name:,
           rotation_interval_days: nil, rotated_at: Time.current - value_age_days.days)
  end

  describe "#variables" do
    it "include le variabili :due_soon e :overdue" do
      due_soon = variable_due_soon(name: "DUE_SOON")
      overdue = variable_overdue(name: "OVERDUE")

      report = described_class.new(projects: [ project ])

      expect(report.variables).to contain_exactly(due_soon, overdue)
    end

    it "esclude le variabili :ok e :none" do
      variable_ok(name: "OK_VAR")
      create(:secret_variable, project:, environment:, name: "NONE_VAR", rotation_interval_days: nil)

      report = described_class.new(projects: [ project ])

      expect(report.variables).to be_empty
    end

    it "ordina overdue PRIMA di due_soon, poi per rotate_by crescente (il più urgente in cima)" do
      most_urgent_overdue = variable_overdue(name: "MOST_URGENT", days_ago_rotated: 2) # rotate_by = ora - 1g
      less_urgent_overdue = create(:secret_variable, project:, environment:, name: "LESS_URGENT",
                                    rotation_interval_days: 1, rotated_at: Time.current - 1.5.days) # rotate_by = ora - 0.5g
      soon = variable_due_soon(name: "SOON") # rotate_by = ora + 14g

      report = described_class.new(projects: [ project ])

      expect(report.variables).to eq([ most_urgent_overdue, less_urgent_overdue, soon ])
    end

    it "scoping: le variabili di un progetto non incluso non contribuiscono al risultato" do
      other_project = create(:project, organization: org)
      other_environment = create(:environment, organization: org).tap { |e| other_project.environments << e }
      variable_overdue(name: "OTHER_OVERDUE", target_project: other_project, target_environment: other_environment)

      report = described_class.new(projects: [ project ])

      expect(report.variables).to be_empty
    end
  end

  describe "#overdue_count / #due_soon_count" do
    it "conta separatamente le due categorie" do
      variable_overdue(name: "OVERDUE")
      variable_due_soon(name: "DUE_SOON")
      variable_ok(name: "OK_VAR")

      report = described_class.new(projects: [ project ])

      expect(report.overdue_count).to eq(1)
      expect(report.due_soon_count).to eq(1)
    end
  end

  describe "#any?" do
    it "false quando non c'è nulla da ruotare" do
      variable_ok(name: "OK_VAR")
      expect(described_class.new(projects: [ project ]).any?).to be(false)
    end

    it "true con almeno una variabile da ruotare" do
      variable_due_soon(name: "DUE_SOON")
      expect(described_class.new(projects: [ project ]).any?).to be(true)
    end

    it "false su una lista di progetti vuota" do
      expect(described_class.new(projects: []).any?).to be(false)
    end
  end

  describe "copertura (#total_count / #covered_count / #uncovered_count / #any_policy?)" do
    it "il totale conta TUTTI i segreti visibili, con e senza regola" do
      variable_ok(name: "WITH_POLICY")
      variable_uncovered(name: "NO_POLICY", value_age_days: 10)

      report = described_class.new(projects: [ project ])

      expect(report.total_count).to eq(2)
    end

    it "la copertura conta solo i segreti con una regola; il resto è scoperto" do
      variable_ok(name: "WITH_POLICY")
      variable_due_soon(name: "ALSO_WITH_POLICY")
      variable_uncovered(name: "NO_POLICY_1", value_age_days: 5)
      variable_uncovered(name: "NO_POLICY_2", value_age_days: 30)

      report = described_class.new(projects: [ project ])

      expect(report.covered_count).to eq(2)
      expect(report.uncovered_count).to eq(2)
    end

    it "any_policy? è false quando nessun segreto ha una regola (il falso verde da smascherare)" do
      variable_uncovered(name: "NO_POLICY", value_age_days: 10)

      expect(described_class.new(projects: [ project ]).any_policy?).to be(false)
    end

    it "any_policy? è true con almeno una regola configurata" do
      variable_ok(name: "WITH_POLICY")
      variable_uncovered(name: "NO_POLICY", value_age_days: 10)

      expect(described_class.new(projects: [ project ]).any_policy?).to be(true)
    end

    it "coverage_tone è neutro sul vault vuoto (0 / 0 non è un falso verde da segnalare in rosso)" do
      expect(described_class.new(projects: [ project ]).coverage_tone).to eq(:neutral)
    end

    it "coverage_tone è rosso con secret presenti ma nessuna regola (il falso verde smascherato)" do
      variable_uncovered(name: "NO_POLICY", value_age_days: 10)

      expect(described_class.new(projects: [ project ]).coverage_tone).to eq(:red)
    end

    it "coverage_tone è ambra a copertura parziale e emerald a copertura piena" do
      covered = described_class.new(projects: [ project ])
      variable_ok(name: "WITH_POLICY")
      expect(covered.coverage_tone).to eq(:emerald)

      partial = described_class.new(projects: [ project ])
      variable_uncovered(name: "NO_POLICY", value_age_days: 10)
      expect(partial.coverage_tone).to eq(:amber)
    end

    it "lo scoping vale anche per il totale: un progetto non incluso non conta" do
      other_project = create(:project, organization: org)
      other_environment = create(:environment, organization: org).tap { |e| other_project.environments << e }
      variable_uncovered(name: "OTHER", value_age_days: 1,
                         target_project: other_project, target_environment: other_environment)

      expect(described_class.new(projects: [ project ]).total_count).to eq(0)
    end
  end

  describe "#uncovered_preview / #uncovered_overflow_count" do
    it "elenca solo i segreti SENZA regola, il valore più vecchio in cima" do
      newer = variable_uncovered(name: "NEWER", value_age_days: 5)
      older = variable_uncovered(name: "OLDER", value_age_days: 100)
      variable_ok(name: "HAS_POLICY")

      report = described_class.new(projects: [ project ])

      expect(report.uncovered_preview).to eq([ older, newer ])
    end

    it "limita l'anteprima e conta i rimanenti (niente dump di tutto il vault)" do
      stub_const("Secrets::RotationReport::UNCOVERED_PREVIEW_LIMIT", 2)
      variable_uncovered(name: "OLDEST", value_age_days: 300)
      variable_uncovered(name: "MIDDLE", value_age_days: 200)
      variable_uncovered(name: "NEWEST", value_age_days: 100)

      report = described_class.new(projects: [ project ])

      expect(report.uncovered_preview.map(&:name)).to eq(%w[OLDEST MIDDLE])
      expect(report.uncovered_overflow_count).to eq(1)
    end

    it "overflow zero quando i segreti senza regola stanno tutti nell'anteprima" do
      variable_uncovered(name: "ONLY", value_age_days: 10)

      expect(described_class.new(projects: [ project ]).uncovered_overflow_count).to eq(0)
    end
  end
end
