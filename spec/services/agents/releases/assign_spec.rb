# frozen_string_literal: true

require "rails_helper"

# CYRA-621 — l'assegnazione è quello che tiene insieme la versione di prova e quella definitiva, e
# che toglie la corsa fra due lavorazioni dello stesso progetto: prima leggevano lo stesso «ultimo
# numero» e sceglievano lo stesso nome, e la seconda pubblicazione veniva respinta.
RSpec.describe Agents::Releases::Assign do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  before { versioni_uscite("v1.4.2") }

  def assign(phase) = described_class.call(workflow:, execution_phase: phase)

  def staging_verificato!(commit = "a" * 40)
    workflow.update!(closer_staging_completed_at: 10.minutes.ago, closer_staging_verified_at: 5.minutes.ago)
    create(:agent_attempt, workflow:, organization:, phase: "closer_staging", status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.4.3-beta.1", "commit" => commit })
  end

  it "la prova porta il suffisso, e la definitiva lo stesso numero senza" do
    prova = assign("closer_staging").value
    expect(prova.version).to eq("v1.4.3-beta.1")

    staging_verificato!
    definitiva = assign("closer_production").value
    expect(definitiva.version).to eq("v1.4.3")
  end

  # Un secondo claim sulla stessa fase ritrova la riga: è la stessa fase, quindi lo stesso numero.
  it "è idempotente: un secondo giro non assegna un numero nuovo" do
    prima = assign("closer_staging").value

    expect { assign("closer_staging") }.not_to change(Agents::ReleaseAssignment, :count)
    expect(assign("closer_staging").value.id).to eq(prima.id)
  end

  # CYRA-1064 — a number assigned before someone else released the same version stayed forever: the
  # closer found its heading already on main and stopped, with no way out but a person.
  it "reassigns a staging number that a newer release has overtaken, while nothing is published" do
    stale = assign("closer_staging").value
    expect(stale.version).to eq("v1.4.3-beta.1")
    versioni_uscite("v1.4.2", "v1.4.3")

    fresh = assign("closer_staging").value

    expect(fresh.version).to eq("v1.4.4-beta.1")
    expect(Agents::ReleaseAssignment.exists?(stale.id)).to be(false)
  end

  # CYRA-1065 — on a repository without a staging channel no tag marks a staging release, so the stable tag
  # never moved: a sibling's higher number already merged to main left this one stuck below it (CYJS-43).
  it "reassigns a staging number that a sibling workflow already released above it" do
    stale = assign("closer_staging").value
    expect(stale.version).to eq("v1.4.3-beta.1")
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)
    described_class.call(workflow: altro.agent_workflow, execution_phase: "closer_staging")
    altro.agent_workflow.update!(closer_staging_completed_at: 1.minute.ago)

    expect(assign("closer_staging").value.version).to eq("v1.4.5-beta.1")
  end

  it "keeps a lower staging number while the sibling above it is not released yet" do
    first = assign("closer_staging").value
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)
    described_class.call(workflow: altro.agent_workflow, execution_phase: "closer_staging")

    expect(assign("closer_staging").value.id).to eq(first.id)
  end

  it "keeps the staging number once its release is out, even if it is overtaken" do
    first = assign("closer_staging").value
    workflow.update!(closer_staging_completed_at: 1.minute.ago)
    versioni_uscite("v1.4.2", "v1.4.3")

    expect(assign("closer_staging").value.id).to eq(first.id)
  end

  # CYRA-878 — a second workflow reaching staging before the first one reaches production used to
  # share its number as beta.2. Both CHANGELOG entries then sat under one heading, the first production
  # took the tag on its own older commit, and the second could never be released: no heading matched
  # its new number, and the old number already pointed elsewhere. It now gets the next number.
  it "two workflows pending production never share a version number" do
    assign("closer_staging")
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)

    seconda = described_class.call(workflow: altro.agent_workflow, execution_phase: "closer_staging")

    expect(seconda.value.version).to eq("v1.4.4-beta.1")
    expect(Agents::ReleaseAssignment.pluck(:version).uniq.size).to eq(2)
  end

  # CYRA-1031 — cancelling cannot take back a beta tag or a CHANGELOG section already published under that
  # number, so the number stays taken.
  it "a cancelled workflow keeps its number taken" do
    assign("closer_staging")
    workflow.update!(cancelled_at: Time.current)
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)

    expect(described_class.call(workflow: altro.agent_workflow, execution_phase: "closer_staging").value.version)
      .to eq("v1.4.4-beta.1")
  end

  it "production keeps the number of its own staging release" do
    assign("closer_staging")
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)
    described_class.call(workflow: altro.agent_workflow, execution_phase: "closer_staging")

    staging_verificato!
    expect(assign("closer_production").value.version).to eq("v1.4.3")
  end

  it "a number already released stops counting as pending" do
    assign("closer_staging")
    versioni_uscite("v1.4.2", "v1.4.3")
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)

    seconda = described_class.call(workflow: altro.agent_workflow, execution_phase: "closer_staging")

    expect(seconda.value.version).to eq("v1.4.4-beta.1")
  end

  # La versione definitiva pubblica il commit che il sistema ha VISTO atterrare, non quello che la
  # macchina dichiara: è la cosa che si sta smettendo di credere sulla parola.
  it "la definitiva porta il punto di codice verificato" do
    staging_verificato!("b" * 40)

    expect(assign("closer_production").value.sha).to eq("b" * 40)
  end

  # Senza quel punto la fase non parte: pubblicare «da qualche parte» è esattamente ciò che questo
  # lavoro toglie di mezzo.
  it "senza il punto verificato la definitiva non si assegna, e la fase non parte" do
    esito = assign("closer_production")

    expect(esito.error.code).to eq("R409-WORKFLOW-010")
    expect(Agents::ReleaseAssignment.count).to eq(0)
  end

  # Le fasi che non rilasciano non hanno un numero da assegnare, e pretenderlo le fermerebbe.
  it "sulle fasi che non rilasciano non assegna niente" do
    %w[triage planner autopilot].each do |phase|
      expect(assign(phase).value).to be_nil, phase
    end
    expect(Agents::ReleaseAssignment.count).to eq(0)
  end
end
