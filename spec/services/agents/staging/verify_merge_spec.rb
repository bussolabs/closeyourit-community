# frozen_string_literal: true

require "rails_helper"

# CYRA-620 — il lavoro andava avanti perché la macchina scriveva «fatto». Se l'ultimo passaggio non
# riusciva — spedizione rifiutata, connessione caduta, copia di lavoro vecchia — nessuno se ne
# accorgeva: il passo dopo partiva lo stesso, e in produzione poteva uscire un codice diverso da
# quello approvato, o nessuno.
RSpec.describe Agents::Staging::VerifyMerge do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) do
    ticket.agent_workflow.tap do |w|
      w.update!(triage_started_at: 5.hours.ago, triaged_at: 4.hours.ago, planned_at: 4.hours.ago,
                approved_at: 3.hours.ago, autopilot_started_at: 3.hours.ago,
                autopilot_completed_at: 2.hours.ago, candidate_verified_at: 2.hours.ago,
                autopilot_approved_at: 2.hours.ago, closer_staging_started_at: 90.minutes.ago,
                closer_staging_completed_at: 1.minute.ago, ticket_snapshot_digest: "snapshot")
    end
  end
  let!(:candidate) do
    create(:agent_delivery_candidate, :verified_passing, workflow:, organization:, repository:,
                                      repository_full_name: "bussolabs/closeyourit-rails",
                                      head_sha: "a" * 40, base_ref: "main").tap do |riga|
      workflow.update!(review_candidate: riga)
    end
  end

  # Il commit che il closer DICHIARA di aver preparato: sta nel result del tentativo, che è audit
  # immutabile. Non si prende dal ramo, che si muove.
  def dichiara(commit = "b" * 40)
    create(:agent_attempt, workflow:, organization:, phase: "closer_staging", status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => commit })
  end

  def client_che_risponde(*esiti)
    coda = esiti.dup
    instance_double(Github::Client).tap do |c|
      allow(c).to receive(:commit_contained?) { coda.shift }
    end
  end

  it "interroga GitHub col numero dell'installazione, non con la chiave interna (CYRA-762)" do
    dichiara
    client = client_che_risponde(true, true)

    described_class.call(workflow:, client:)

    expect(client).to have_received(:commit_contained?)
      .with(repository.installation.installation_id, anything, anything, anything).at_least(:once)
  end

  it "vede il codice approvato atterrato: la prova è scritta e la produzione si apre" do
    dichiara

    described_class.call(workflow:, client: client_che_risponde(true, true))

    expect(workflow.reload).to have_attributes(closer_staging_verified_at: be_present,
                                               closer_staging_next_check_at: nil,
                                               closer_staging_last_error_code: nil)
    # CYRA-629 — la prova aperta apre la produzione davvero: non c'è più un pulsante in mezzo.
    expect(workflow.phase).to eq("closer_production_queued")
  end

  # A project whose proof of done is the merge itself has nothing to observe in production: the
  # production step used to refuse it ("no proof declared") and the work never became done.
  it "with the merge as proof of done, the verified merge completes the work" do
    create(:ticket_status, :done, organization:)
    congela_piano!(workflow, kind: "merge")
    dichiara

    described_class.call(workflow:, client: client_che_risponde(true, true))

    workflow.reload
    expect(workflow.completed_at).to be_present
    expect(workflow.ready_execution_phase).to be_nil
    expect(ticket.reload.status.category).to eq("done")
  end

  it "with a production proof, the verified merge opens production and completes nothing" do
    congela_piano!(workflow, kind: "deploy_smoke", environment_id: SecureRandom.uuid)
    dichiara

    described_class.call(workflow:, client: client_che_risponde(true, true))

    expect(workflow.reload.completed_at).to be_nil
    expect(workflow.phase).to eq("closer_production_queued")
  end

  # Le due domande non sono la stessa: una macchina che lavora su una copia vecchia può spingere
  # qualcosa che atterra benissimo e non è il codice che è stato approvato.
  it "il commit dichiarato è atterrato ma NON contiene il codice approvato: non passa" do
    dichiara

    described_class.call(workflow:, client: client_che_risponde(true, false))

    expect(workflow.reload.closer_staging_verified_at).to be_nil
    expect(workflow.phase).to eq("verifying_staging")
  end

  it "il commit dichiarato non è atterrato: aspetta e riprova, senza chiamare nessuno" do
    dichiara

    described_class.call(workflow:, client: client_che_risponde(false))

    expect(workflow.reload).to have_attributes(closer_staging_verified_at: nil, blocked_at: nil,
                                               closer_staging_next_check_at: be_present,
                                               closer_staging_last_error_code: "not_merged_yet")
  end

  # Oltre la finestra di grazia non è più «non ancora»: è «non è arrivato», e serve una persona.
  it "oltre la grazia smette di riprovare e chiama una persona" do
    dichiara
    workflow.update!(closer_staging_completed_at: 1.hour.ago)

    described_class.call(workflow:, client: client_che_risponde(false))

    expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_phase: "closer_staging",
                                               closer_staging_next_check_at: nil)
    expect(workflow.blocked_reason).to include("staging_proof", "staging_not_merged")
  end

  # «Non ho potuto guardare» non è «non è arrivato»: si aspetta, non si chiama nessuno.
  it "il servizio non risponde: riprova, e la lavorazione non risulta ferma" do
    dichiara
    client = instance_double(Github::Client)
    allow(client).to receive(:commit_contained?)
      .and_raise(Github::Client::Error.new("giù", code: "R502-GITHUB-001"))

    described_class.call(workflow:, client:)

    expect(workflow.reload).to have_attributes(blocked_at: nil, closer_staging_verified_at: nil,
                                               closer_staging_next_check_at: be_present,
                                               closer_staging_last_error_code: "R502-GITHUB-001")
  end

  it "una risposta definitiva chiama una persona invece di riprovare all'infinito" do
    dichiara
    client = instance_double(Github::Client)
    allow(client).to receive(:commit_contained?)
      .and_raise(Github::Client::Error.new("assente", code: "R404-GITHUB-001", status: :not_found))

    described_class.call(workflow:, client:)

    expect(workflow.reload.blocked_at).to be_present
    expect(workflow.closer_staging_next_check_at).to be_nil
  end

  # Senza il commit dichiarato non c'è niente da confrontare, e fingere che vada bene sarebbe il
  # guasto peggiore: si chiama una persona.
  it "senza il commit dichiarato chiama una persona, invece di passare" do
    described_class.call(workflow:, client: client_che_risponde(true, true))

    expect(workflow.reload.blocked_at).to be_present
    expect(workflow.blocked_reason).to include("staging_evidence_missing")
  end

  # Una prova già scritta non si riscrive: è la firma di ciò che il sistema ha visto.
  it "un secondo giro su una prova già scritta non la tocca" do
    dichiara
    described_class.call(workflow:, client: client_che_risponde(true, true))
    prima = workflow.reload.closer_staging_verified_at

    client = instance_double(Github::Client)
    allow(client).to receive(:commit_contained?).and_raise("non doveva guardare di nuovo")
    described_class.call(workflow: workflow.reload, client:)

    expect(workflow.reload.closer_staging_verified_at).to eq(prima)
  end
end
