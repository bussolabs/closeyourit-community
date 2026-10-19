# frozen_string_literal: true

require "rails_helper"

# CYRA-1047 — il numero di prova lungo il percorso vero: la macchina prende la fase e si ferma, il CTO
# preme Riprova, la macchina la riprende e consegna. Le prove di Agents::Releases::Assign coprono il
# pezzo che assegna; qui si guarda che fra sblocco, presa in carico e consegna il numero superato venga
# sostituito, e quello ancora valido resti dov'è.
RSpec.describe "CYRA-1047 — il numero di prova dopo Riprova", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, :agent_workable, organization:, project:, kind: :bug, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) { create(:account) }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value
  end
  let(:host) { registration.fetch(:host) }
  let(:headers) { { "Authorization" => "Bearer #{registration.fetch(:secret)}" } }

  before do
    host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ],
                 automator_version: "0.39.0", runtimes: [ { "name" => "claude", "present" => true } ])
    create(:project_membership, account: host.service_account, project:)
    create(:membership, :owner, organization:, account: cto)
    create(:project_membership, project:, account: cto)
    organization.update!(cto:)
    workflow.update!(ticket_snapshot_digest: "snapshot")
    versioni_uscite("v0.88.0")
    post login_path, params: { email: cto.email, password: "Secret123!" }
  end

  # Il percorso ripete di proposito le stesse richieste (prendere, consegnare, riprendere): le query
  # di ogni giro sono quelle di una richiesta sola, non un N+1. La guardia per richiesta resta negli
  # spec dei singoli endpoint.
  def presa_in_carico(run_id)
    allow_n_plus_one do
      post "/api/v1/ticket_queue/next_claim", params: { project_key: project.key, host_id: host.id, run_id: },
                                              headers:, as: :json
    end
    expect(response).to have_http_status(:created)
    response.parsed_body.fetch("data")
  end

  def consegna(incarico, result)
    attempt = Agents::Attempt.find(incarico.fetch("attempt_id"))
    allow_n_plus_one do
      put api_v1_agent_attempt_result_path(attempt),
          params: { runtime: attempt.runtime, reviewer_runtime: attempt.reviewer,
                    result: result.merge(code: ticket.code), review: review_for(attempt.phase),
                    observed: observed_head },
          headers:, as: :json
    end
    response
  end

  # La macchina chiude il suo turno: senza, il lease ancora vivo terrebbe il ticket fuori dalla coda.
  def rilascia(incarico)
    allow_n_plus_one do
      post "/api/v1/leases/#{ticket.code}/release",
           params: { ticket: ticket.code, host_id: host.id, run_id: incarico.fetch("run_id") }, headers:, as: :json
    end
    expect(response).to have_http_status(:ok)
  end

  # La macchina prende la fase e dichiara che serve una persona: la lavorazione resta ferma lì.
  def ferma!(run_id, fase)
    incarico = presa_in_carico(run_id)
    expect(incarico.fetch("execution_phase")).to eq(fase)
    expect(consegna(incarico, state: "blocked", tag: nil, reason: "La CI è rossa.")).to have_http_status(:ok)
    rilascia(incarico)
    expect(workflow.reload).to have_attributes(blocked_phase: fase, blocked_kind: "agent_blocked")
    incarico
  end

  def riprova!
    allow_n_plus_one { post member_ticket_automation_unblock_path(ticket) }
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.blocked.retried"))
    expect(workflow.reload.blocked_at).to be_nil
  end

  def rilasciata!(version, completed: true)
    altro = create(:ticket, organization:, project:, kind: :bug, with_agent_workflow: true)
    assigned_version(altro.agent_workflow, "closer_staging", version:)
    altro.agent_workflow.update!(closer_staging_completed_at: 1.minute.ago) if completed
    altro.agent_workflow
  end

  describe "un numero di prova superato" do
    let!(:vecchio) { assigned_version(pronta_per!(workflow, "closer_staging"), "closer_staging", version: "v0.89.0-beta.1") }

    # Scenari 1, 3 — DOD-1, DOD-3, DOD-4.
    it "dopo Riprova porta un numero sopra l'ultima versione uscita, e il vecchio non torna più" do
      prima = ferma!("run-1", "closer_staging")
      expect(prima.fetch("release")).to eq("version" => "v0.89.0-beta.1", "sha" => nil)

      versioni_uscite("v0.88.0", "v0.89.0", "v0.90.0")
      riprova!
      seconda = presa_in_carico("run-2")

      expect(seconda.fetch("execution_phase")).to eq("closer_staging")
      expect(seconda.fetch("release")).to eq("version" => "v0.90.1-beta.1", "sha" => nil)
      expect(Agents::ReleaseAssignment.exists?(vecchio.id)).to be(false)

      # Il numero vecchio è rifiutato: quel rilascio non risulta fatto, e la fase torna in coda.
      esito = consegna(seconda, state: "staging-released", tag: "v0.89.0-beta.1", commit: "c" * 40)
      expect(esito).to have_http_status(:conflict)
      expect(esito.parsed_body.dig("error", "code")).to eq("R409-ATTEMPT-005")
      expect(workflow.reload.closer_staging_completed_at).to be_nil
      rilascia(seconda)

      # Un'altra presa in carico non torna indietro: stesso numero nuovo, nessuna assegnazione nuova.
      terza = nil
      expect { terza = presa_in_carico("run-3") }.not_to change(Agents::ReleaseAssignment, :count)
      expect(terza.fetch("release")).to eq("version" => "v0.90.1-beta.1", "sha" => nil)

      esito = consegna(terza, state: "staging-released", tag: "v0.90.1-beta.1", commit: "c" * 40)
      expect(esito).to have_http_status(:ok)
      expect(workflow.reload.closer_staging_completed_at).to be_present
      expect(Agents::ReleaseAssignment.where(workflow:).pluck(:version)).to eq([ "v0.90.1-beta.1" ])
    end

    # Scenario 2 — DOD-2: a superarlo è un'altra lavorazione già in prova, senza una versione stabile nuova.
    it "superato da un'altra lavorazione già in prova, riceve un numero sopra quello dell'altra" do
      ferma!("run-1", "closer_staging")
      rilasciata!("v0.90.0-beta.1")

      riprova!
      incarico = presa_in_carico("run-2")

      expect(incarico.fetch("release")).to eq("version" => "v0.90.1-beta.1", "sha" => nil)
      versions = Agents::ReleaseAssignment.for_phase("closer_staging").pluck(:version)
      expect(versions).to contain_exactly("v0.90.0-beta.1", "v0.90.1-beta.1")
    end

    # Scenario 6 — DOD-6: un numero di una lavorazione annullata può essere già pubblicato, e resta preso.
    it "salta il numero di una lavorazione annullata" do
      ferma!("run-1", "closer_staging")
      versioni_uscite("v0.88.0", "v0.90.0")
      rilasciata!("v0.90.1-beta.1", completed: false).update!(cancelled_at: Time.current)

      riprova!
      incarico = presa_in_carico("run-2")

      expect(incarico.fetch("release")).to eq("version" => "v0.90.2-beta.1", "sha" => nil)
      expect(Agents::ReleaseAssignment.where(version: "v0.90.1-beta.1")).to exist
    end
  end

  # Scenario 4 — DOD-5.
  it "un numero di prova che nessuno ha superato resta lo stesso dopo Riprova" do
    vecchio = assigned_version(pronta_per!(workflow, "closer_staging"), "closer_staging", version: "v0.89.0-beta.1")
    ferma!("run-1", "closer_staging")
    rilasciata!("v0.88.5-beta.1", completed: false)

    riprova!
    incarico = nil
    expect { incarico = presa_in_carico("run-2") }.not_to change(Agents::ReleaseAssignment, :count)

    expect(incarico.fetch("release")).to eq("version" => "v0.89.0-beta.1", "sha" => nil)
    expect(Agents::ReleaseAssignment.find_by(workflow:, execution_phase: "closer_staging").id).to eq(vecchio.id)
  end

  # Scenario 5: la prova è già uscita col suo numero, e la produzione pubblica quello, anche se nel
  # frattempo è uscita una versione più alta.
  it "un rilascio di prova già uscito tiene il suo numero, e la produzione usa quello" do
    pronta_per!(workflow, "closer_production")
    sha = commit_verificato!(workflow)
    provato = assigned_version(workflow, "closer_staging", version: "v0.89.0-beta.1")
    prima = ferma!("run-1", "closer_production")
    expect(prima.fetch("release")).to eq("version" => "v0.89.0", "sha" => sha)

    versioni_uscite("v0.88.0", "v0.90.0")
    riprova!
    incarico = presa_in_carico("run-2")

    expect(incarico.fetch("execution_phase")).to eq("closer_production")
    expect(incarico.fetch("release")).to eq("version" => "v0.89.0", "sha" => sha)
    expect(provato.reload.version).to eq("v0.89.0-beta.1")
  end

  # CYRA-1030 — «Rimanda allo staging»: fermo in produzione per un difetto nel codice preparato, la
  # prova riparte col numero di prova successivo e la produzione pubblica il codice della nuova prova.
  it "rimandata allo staging, la prova prende il numero successivo e la produzione il codice nuovo" do
    pronta_per!(workflow, "closer_production")
    vecchio_sha = commit_verificato!(workflow)
    assigned_version(workflow, "closer_staging", version: "v0.89.0-beta.1")
    prima = ferma!("run-1", "closer_production")
    expect(prima.fetch("release")).to eq("version" => "v0.89.0", "sha" => vecchio_sha)

    allow_n_plus_one { post member_ticket_automation_staging_send_back_path(ticket) }
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.blocked.sent_back"))
    expect(Agents::Workflows::ProductionLock.locked?(project:)).to be(false)

    # Scenario 3 — DOD-4: stesso numero definitivo, numero di prova successivo.
    prova = presa_in_carico("run-2")
    expect(prova.fetch("execution_phase")).to eq("closer_staging")
    expect(prova.fetch("release")).to eq("version" => "v0.89.0-beta.2", "sha" => nil)

    nuovo_sha = "b" * 40
    esito = consegna(prova, state: "staging-released", tag: "v0.89.0-beta.2", commit: nuovo_sha)
    expect(esito).to have_http_status(:ok)
    rilascia(prova)

    # R-1 — DOD-2: finché la nuova prova non è verificata la produzione non è proposta.
    expect(workflow.reload.ready_execution_phase).to be_nil

    # La verifica dell'unione (Staging::VerifyMerge) la dà per vista, oltre l'attesa prima della produzione.
    workflow.update!(closer_staging_verified_at: (Agents::Workflows::ProductionHold::DEFAULT_HOURS + 1).hours.ago)

    # DOD-5: la produzione pubblica il punto di codice della nuova prova, con lo stesso numero.
    produzione = presa_in_carico("run-3")
    expect(produzione.fetch("execution_phase")).to eq("closer_production")
    expect(produzione.fetch("release")).to eq("version" => "v0.89.0", "sha" => nuovo_sha)
  end

  # CYRA-1030 — DOD-4 anche quando la fila liberata fa uscire prima un rilascio più alto: l'intestazione
  # v0.89.0 è già sulla linea principale, quindi il numero definitivo non si rinumera.
  it "rimandata allo staging, tiene il numero definitivo anche se nel frattempo esce un rilascio più alto" do
    pronta_per!(workflow, "closer_production")
    commit_verificato!(workflow)
    assigned_version(workflow, "closer_staging", version: "v0.89.0-beta.1")
    ferma!("run-1", "closer_production")

    allow_n_plus_one { post member_ticket_automation_staging_send_back_path(ticket) }
    expect(flash[:notice]).to eq(I18n.t("member.tickets.automation.blocked.sent_back"))

    # Scenario 2: un'altra lavorazione passa avanti, unita e pubblicata come versione stabile.
    rilasciata!("v0.90.0-beta.1")
    versioni_uscite("v0.88.0", "v0.90.0")

    prova = presa_in_carico("run-2")
    expect(prova.fetch("release")).to eq("version" => "v0.89.0-beta.2", "sha" => nil)

    nuovo_sha = "d" * 40
    expect(consegna(prova, state: "staging-released", tag: "v0.89.0-beta.2", commit: nuovo_sha))
      .to have_http_status(:ok)
    rilascia(prova)
    workflow.update!(closer_staging_verified_at: (Agents::Workflows::ProductionHold::DEFAULT_HOURS + 1).hours.ago)

    produzione = presa_in_carico("run-3")
    expect(produzione.fetch("release")).to eq("version" => "v0.89.0", "sha" => nuovo_sha)
  end
end
