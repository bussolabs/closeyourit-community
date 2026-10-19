# frozen_string_literal: true

require "rails_helper"

# CYRA-1030 — «Rimanda allo staging»: un rilascio fermo in produzione per un difetto nel codice
# preparato torna alla prova. Si cancellano il tentativo in produzione e la conclusione della prova,
# così la prova rifà il codice e la fila dei rilasci del repository si libera.
RSpec.describe Agents::Workflows::SendBackToStaging do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end

  before { organization.update!(cto:) }

  # La macchina ha preso la produzione col codice sigillato e si è fermata lì.
  def ferma_in_produzione(staging: "v0.89.0-beta.1", production: "v0.89.0")
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = pronta_per!(ticket.agent_workflow, "closer_production")
    sha = commit_verificato!(workflow)
    assigned_version(workflow, "closer_staging", version: staging)
    assigned_version(workflow, "closer_production", version: production, sha:)
    workflow.update!(closer_staging_checks_count: 2, closer_production_started_at: Time.current)
    Agents::Workflows::Block.call(workflow:, phase: "closer_production", kind: "agent_blocked",
                                  reason: "agent_blocked: il rilascio non parte")
    workflow.reload
  end

  # Scenari 1, 2 — DOD-2, DOD-3.
  it "rimette in coda la prova, toglie il blocco e libera la fila dei rilasci" do
    workflow = ferma_in_produzione
    altro = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true).agent_workflow
    expect(Agents::Workflows::ProductionLock.locked?(project:, except: altro)).to be(true)

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_ok
    expect(workflow.reload).to have_attributes(
      blocked_at: nil, blocked_kind: nil, blocked_phase: nil,
      closer_production_started_at: nil, closer_production_completed_at: nil,
      closer_production_by_host_id: nil, closer_production_by_service_account_id: nil,
      closer_staging_started_at: nil, closer_staging_completed_at: nil,
      closer_staging_verified_at: nil, closer_staging_next_check_at: nil, closer_staging_checks_count: 0
    )
    expect(workflow.ready_execution_phase).to eq("closer_staging")
    expect(workflow.phase).to eq("closer_staging_queued")
    expect(Agents::Workflows::ProductionLock.locked?(project:, except: altro)).to be(false)
  end

  # Scenario 3 — DOD-4, DOD-5, R-2: il numero di prova avanza, il definitivo resta, il punto sigillato sparisce.
  it "avanza il numero di prova, tiene il definitivo e cancella il punto di codice sigillato" do
    workflow = ferma_in_produzione

    described_class.call(workflow:, actor: cto)

    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_production")).to be_nil
    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_staging").version)
      .to eq("v0.89.0-beta.2")
  end

  it "salta un numero di prova già preso nello stesso repository" do
    workflow = ferma_in_produzione(staging: "v0.89.0-beta.1")
    altro = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true).agent_workflow
    assigned_version(altro, "closer_staging", version: "v0.89.0-beta.2")

    described_class.call(workflow:, actor: cto)

    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_staging").version)
      .to eq("v0.89.0-beta.3")
  end

  # DOD-4: il numero resta quello la cui intestazione è già sulla linea principale; Releases::Assign lo
  # legge da `landed_at` e non lo rinumera.
  it "segna il numero di prova come già unito, al momento in cui la prova era stata vista atterrare" do
    workflow = ferma_in_produzione
    visto = workflow.closer_staging_verified_at

    described_class.call(workflow:, actor: cto)

    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_staging").landed_at)
      .to be_within(1.second).of(visto)
  end

  # Un'altra lavorazione prende lo stesso nome fra la lettura e la scrittura: si rilegge e si riprova.
  def numero_preso_nel_frattempo(service, volte:)
    presi = 0
    allow(service).to receive(:next_beta).and_wrap_original do |original, *args|
      original.call(*args).tap do |version|
        next if presi >= volte

        presi += 1
        altro = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true).agent_workflow
        assigned_version(altro, "closer_staging", version:)
      end
    end
  end

  it "un numero preso da un'altra lavorazione nel frattempo viene ricalcolato" do
    workflow = ferma_in_produzione
    service = described_class.new(workflow:, actor: cto)
    numero_preso_nel_frattempo(service, volte: 1)

    expect(service.call).to be_ok
    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_staging").version)
      .to eq("v0.89.0-beta.3")
  end

  it "se il numero viene preso due volte di fila rifiuta senza toccare niente" do
    workflow = ferma_in_produzione
    service = described_class.new(workflow:, actor: cto)
    numero_preso_nel_frattempo(service, volte: 2)

    result = service.call

    expect(result).to be_err
    expect(result.error.code).to eq("R409-WORKFLOW-009")
    expect(workflow.reload).to have_attributes(blocked_phase: "closer_production", closer_staging_verified_at: be_present)
    expect(Agents::ReleaseAssignment.where(workflow:).pluck(:version)).to contain_exactly("v0.89.0-beta.1", "v0.89.0")
  end

  # R-1 — DOD-2: niente di vecchio riapre la produzione prima che la nuova prova riesca.
  it "la produzione non è proposta finché la nuova prova non è verificata" do
    workflow = ferma_in_produzione

    described_class.call(workflow:, actor: cto)
    workflow.reload.update!(closer_staging_started_at: Time.current, closer_staging_completed_at: Time.current)

    expect(workflow.ready_execution_phase).to be_nil
    expect(workflow.phase).to eq("verifying_staging")
  end

  # Scenario 6.
  it "chiude la verifica del rilascio ancora aperta, annotando chi l'ha chiusa" do
    workflow = ferma_in_produzione
    probe = workflow.probes.create!(kind: "deploy_smoke", bound_at: 5.minutes.ago, next_check_at: 1.minute.ago,
                                    expected: { "version" => "v0.89.0", "sha" => "a" * 40 })

    described_class.call(workflow:, actor: cto)

    expect(probe.reload.closed_at).to be_present
    expect(probe.next_check_at).to be_nil
    expect(probe.evidence).to include("closed_by" => "human", "account_id" => cto.id,
                                      "reason" => "sent_back_to_staging")
  end

  it "riporta il ticket allo stato della prova" do
    in_review = create(:ticket_status, :in_review, organization:, position: 98)
    create(:ticket_status, :in_progress, organization:, position: 99)
    workflow = ferma_in_produzione
    workflow.ticket.update_columns(status_id: in_review.id)

    described_class.call(workflow:, actor: cto)

    expect(workflow.ticket.reload.status).to have_attributes(category: "in_progress", review_gate: false)
  end

  # Scenario 4 — DOD-6.
  it "lo può fare solo il CTO effettivo" do
    workflow = ferma_in_produzione
    altro = create(:account).tap { |account| create(:membership, :owner, account:, organization:) }

    result = described_class.call(workflow:, actor: altro)

    expect(result).to be_err
    expect(result.error.code).to eq("R403-WORKFLOW-001")
    expect(workflow.reload).to have_attributes(blocked_phase: "closer_production", closer_staging_verified_at: be_present)
  end

  # Scenario 5 — DOD-6, R-3: ferma nella prova, già conclusa, o già rimandata da un primo clic.
  it "rifiuta una lavorazione ferma nella prova senza toccare niente" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = pronta_per!(ticket.agent_workflow, "closer_staging")
    workflow.update!(closer_staging_started_at: Time.current)
    Agents::Workflows::Block.call(workflow:, phase: "closer_staging", kind: "agent_blocked", reason: "agent_blocked: x")

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-WORKFLOW-017")
    expect(workflow.reload).to have_attributes(blocked_phase: "closer_staging", closer_staging_started_at: be_present)
  end

  it "rifiuta una lavorazione già conclusa" do
    workflow = ferma_in_produzione
    workflow.update!(completed_at: Time.current)

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-WORKFLOW-017")
    expect(Agents::ReleaseAssignment.where(workflow:).count).to eq(2)
  end

  it "un secondo clic non la rimanda indietro due volte" do
    workflow = ferma_in_produzione
    expect(described_class.call(workflow:, actor: cto)).to be_ok

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-WORKFLOW-017")
    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_staging").version)
      .to eq("v0.89.0-beta.2")
  end
end
