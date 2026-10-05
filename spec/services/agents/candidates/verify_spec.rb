# frozen_string_literal: true

require "rails_helper"

# CYRA-614 — il sistema apre la proposta con le sue mani, mette per iscritto quale codice c'è dentro,
# e legge l'esito dei controlli automatici PROPRIO su quel codice.
#
# Prima, quando la macchina diceva «ho finito», il lavoro compariva subito fra le cose da revisionare:
# a chi approva veniva chiesto di dire sì sulla parola della stessa macchina che aveva fatto il lavoro.
RSpec.describe Agents::Candidates::Verify do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let!(:in_review) { create(:ticket_status, :in_review, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) do
    ticket.agent_workflow.tap do |w|
      w.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 2.hours.ago,
                approved_at: 1.hour.ago, autopilot_started_at: 1.hour.ago,
                autopilot_completed_at: Time.current, ticket_snapshot_digest: "snapshot")
    end
  end
  let(:candidate) do
    create(:agent_delivery_candidate, workflow:, repository:, organization:,
                                      repository_full_name: "bussolabs/closeyourit-rails", number: 7)
  end

  # Il finto client: risponde con la stessa forma di `Github::Client#pull_request_state`, che è il
  # contratto vero — un finto con una forma sua proverebbe qualcos'altro.
  def client_con(risposta)
    instance_double(Github::Client).tap do |c|
      allow(c).to receive(:pull_request_state).and_return(risposta)
    end
  end

  def client_che_solleva(errore)
    instance_double(Github::Client).tap do |c|
      allow(c).to receive(:pull_request_state).and_raise(errore)
    end
  end

  def risposta(checks:, checks_known: true, base_ref: "main", base_default: "main",
               head_sha: "a" * 40, committed_at: 1.hour.ago.iso8601)
    { head_sha:, base_ref:, state: "OPEN", draft: false, mergeable: "MERGEABLE", merge_commit: nil,
      checks:, checks_known:, base_repository: "bussolabs/closeyourit-rails",
      base_default_branch: base_default, head_committed_at: committed_at }
  end

  def check_run(conclusion) = { "__typename" => "CheckRun", "name" => "ci", "conclusion" => conclusion, "status" => "COMPLETED" }

  # ── Controlli verdi ───────────────────────────────────────────────────────────────────────────

  it "controlli verdi: congela il codice letto e mette il lavoro davanti a una persona" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("SUCCESS") ])))

    expect(candidate.reload).to be_state_verified_passing
    expect(candidate).to have_attributes(head_sha: "a" * 40, base_ref: "main", verified_at: be_present,
                                         checks_count: 1, next_check_at: nil)
    expect(workflow.reload).to have_attributes(candidate_verified_at: be_present,
                                               review_candidate_id: candidate.id)
    expect(ticket.reload.status).to eq(in_review)
    expect(workflow.phase).to eq("awaiting_autopilot_approval")
  end

  # Quello che approvi è il codice che il SISTEMA ha visto, non quello che l'agente aveva dichiarato:
  # se il ramo si è mosso mentre il sistema guardava, conta ciò che il sistema ha letto.
  it "il codice registrato è quello letto da GitHub, non quello dichiarato alla consegna" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("SUCCESS") ],
                                                                head_sha: "b" * 40)))

    expect(candidate.reload.head_sha).to eq("b" * 40)
  end

  # ── CYRA-868: con tutti i verdi la consegna va avanti da sola ────────────────────────────────
  #
  # Di decisione per ticket ne resta UNA, il piano. Qui si prova il giro INTERO dalla verifica: il
  # pezzo che decide sta in Agents::Workflows::AutoApprove, questo dice che la verifica lo chiama nel
  # momento giusto e col suo stesso client.
  describe "il sì automatico dopo i controlli verdi (CYRA-868)" do
    let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }
    let(:attempt) do
      create(:agent_attempt, workflow:, organization:, phase: "autopilot", status: :approved,
                             review_status: :accepted, reviewer_runtime: "codex")
    end
    let(:candidate) do
      create(:agent_delivery_candidate, workflow:, repository:, organization:, attempt:,
                                        repository_full_name: "bussolabs/closeyourit-rails", number: 7)
    end

    before do
      service_account = create(:account, :service).tap do |account|
        create(:project_membership, account:, project:)
      end
      create(:agent_host, organization:, service_account:, repositories: [ project.key ],
                          runtimes: [ { "name" => "claude", "present" => true } ])
    end

    it "controlli verdi e rilettura accettata: la lavorazione passa al rilascio senza nessun clic" do
      described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("SUCCESS") ])))

      expect(workflow.reload).to have_attributes(autopilot_approved_at: be_present,
                                                 autopilot_approved_by: nil,
                                                 phase: "closer_staging_queued")
      expect(ticket.reload.status).to eq(in_progress)
      expect(Ticketing::Event.where(ticket:, action: "autopilot_auto_approved")).to be_present
    end

    # Controlli rossi: qui il sì automatico non si pone nemmeno, la lavorazione si ferma e chiama una
    # persona col motivo scritto (comportamento CYRA-614, che questo ticket non tocca).
    it "controlli rossi: si ferma col motivo, e nessuno approva niente" do
      described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("FAILURE") ])))

      expect(workflow.reload).to have_attributes(autopilot_approved_at: nil, phase: "review_blocked")
      expect(workflow.blocked_reason).to include("checks_failing")
    end

    # «Ho guardato e di controlli non ce n'è» è una risposta, non un verde: resta la decisione umana.
    it "nessun controllo configurato: il lavoro resta davanti a una persona" do
      described_class.call(candidate:, client: client_con(risposta(checks: [])))

      expect(workflow.reload).to have_attributes(autopilot_approved_at: nil,
                                                 phase: "awaiting_autopilot_approval")
    end
  end

  # ── Nessun controllo configurato ──────────────────────────────────────────────────────────────

  it "nessun controllo configurato: il lavoro arriva lo stesso, ma la riga lo dice" do
    described_class.call(candidate:, client: client_con(risposta(checks: [], committed_at: 1.hour.ago.iso8601)))

    expect(candidate.reload).to be_state_verified_none_configured
    expect(candidate.checks_payload).to eq([])
    expect(candidate).to be_checked
    expect(ticket.reload.status).to eq(in_review)
  end

  # L'elenco vuoto sul commit appena spinto quasi sempre vuol dire «non sono ancora partiti»:
  # rispondere subito «non ce ne sono» farebbe passare per non-verificato un lavoro che i controlli
  # ce li ha eccome.
  it "elenco vuoto su un commit appena fatto: aspetta invece di dire «non ce ne sono»" do
    described_class.call(candidate:, client: client_con(risposta(checks: [], committed_at: 10.seconds.ago.iso8601)))

    expect(candidate.reload).to be_state_checks_running
    expect(candidate.verified_at).to be_nil
    expect(candidate.next_check_at).to be_present
    expect(ticket.reload.status).not_to eq(in_review)
  end

  # ── Non sono riuscito a guardare ──────────────────────────────────────────────────────────────

  # `unreachable` e `verified_none_configured` sono la coppia che non va mai confusa: la seconda è
  # una risposta, la prima è l'assenza di una risposta.
  it "GitHub non risponde: non chiede niente a nessuno, riprova da solo" do
    errore = Github::Client::Error.new("timeout", code: "R502-GITHUB-001")

    described_class.call(candidate:, client: client_che_solleva(errore))

    expect(candidate.reload).to be_state_unreachable
    expect(candidate).to have_attributes(verified_at: nil, next_check_at: be_present,
                                         last_error_code: "R502-GITHUB-001")
    expect(workflow.reload).to have_attributes(candidate_verified_at: nil, blocked_at: nil)
    expect(ticket.reload.status).not_to eq(in_review)
  end

  it "l'elenco dei controlli non è conoscibile: è «non lo so», mai «non ce ne sono»" do
    described_class.call(candidate:, client: client_con(risposta(checks: [], checks_known: false)))

    expect(candidate.reload).to be_state_unreachable
    expect(candidate.last_error_code).to eq("checks_unknown")
  end

  it "controlli ancora in corso: aspetta, senza firmare niente" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run(nil) ])))

    expect(candidate.reload).to be_state_checks_running
    expect(candidate.verified_at).to be_nil
  end

  # CYRA-762 — il client vuole il NUMERO dell'installazione GitHub, non la chiave interna del
  # repository: con l'UUID GitHub risponde 404 e il sistema lo traduceva in «proposta mancante».
  # Le prove col client finto non lo vedevano: qui l'argomento si controlla.
  it "chiede la proposta a GitHub col numero dell'installazione, non con la chiave interna" do
    client = client_con(risposta(checks: [ check_run("SUCCESS") ]))

    described_class.call(candidate:, client:)

    expect(client).to have_received(:pull_request_state)
      .with(repository.installation.installation_id, "bussolabs/closeyourit-rails", 7)
  end

  # ── Chiama una persona ────────────────────────────────────────────────────────────────────────

  it "controlli rossi: ferma la lavorazione e chiama una persona" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("FAILURE") ])))

    expect(candidate.reload).to be_state_verified_failing
    expect(candidate.verified_at).to be_present
    expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_kind: "candidate_check",
                                               candidate_verified_at: nil)
    expect(ticket.reload.status).not_to eq(in_review)
  end

  it "la proposta non esiste: è una risposta definitiva, non si riprova" do
    errore = Github::Client::Error.new("assente", code: "R404-GITHUB-010", status: :not_found)

    described_class.call(candidate:, client: client_che_solleva(errore))

    expect(candidate.reload).to be_state_rejected
    expect(candidate.next_check_at).to be_nil
    expect(workflow.reload.blocked_kind).to eq("candidate_check")
  end

  # CYRA-761 — «pull_request_missing» da solo non dice niente: lo stesso codice esce per una PR
  # davvero assente, per un token di installazione rifiutato e per un permesso mancante. Il motivo
  # che GitHub ha dato resta scritto nel blocco, dove una persona lo legge.
  it "il rifiuto conserva il messaggio e il codice dell'errore GitHub" do
    errore = Github::Client::Error.new("GitHub: risorsa assente o non accessibile (403)",
                                       code: "R404-GITHUB-010", status: :not_found)

    described_class.call(candidate:, client: client_che_solleva(errore))

    expect(workflow.reload.blocked_reason).to include("pull_request_missing on bussolabs/closeyourit-rails#7")
    expect(workflow.blocked_reason).to include("R404-GITHUB-010")
    expect(workflow.blocked_reason).to include("risorsa assente o non accessibile (403)")
  end

  # CYRA-618 — a decidere se chiamare una persona è lo STATO della risposta, non la classe
  # dell'errore. Prima 401 e 403 finivano in «non sono riuscito a guardare»: si riprovava all'infinito
  # su una credenziale che nessun tentativo sistema, e nessuno veniva avvisato.
  it "credenziale rifiutata: è una risposta, non un canale rotto" do
    [ :unauthorized, :forbidden ].each do |stato|
      riga = create(:agent_delivery_candidate, workflow:, repository:, organization:,
                                               repository_full_name: "bussolabs/closeyourit-rails")
      errore = Github::Client::Error.new("negato", code: "R403-GITHUB-001", status: stato)

      described_class.call(candidate: riga, client: client_che_solleva(errore))

      expect(riga.reload).to be_state_rejected, stato.to_s
      expect(riga.next_check_at).to be_nil
      expect(riga.last_error_code).to eq("access_denied")
    end
  end

  it "un guasto passeggero resta un guasto passeggero" do
    [ :bad_gateway, :service_unavailable, :too_many_requests ].each do |stato|
      riga = create(:agent_delivery_candidate, workflow:, repository:, organization:,
                                               repository_full_name: "bussolabs/closeyourit-rails")
      errore = Github::Client::Error.new("giù", code: "R502-GITHUB-001", status: stato)

      described_class.call(candidate: riga, client: client_che_solleva(errore))

      expect(riga.reload).to be_state_unreachable, stato.to_s
      expect(riga.next_check_at).to be_present
    end
    expect(workflow.reload.blocked_at).to be_nil
  end

  # CYRA-618 — il blocco passa dalla porta unica, e il motivo porta da DOVE è stato visto: «si è
  # fermata» e «si è fermata per questo, visto da qui» sono due cose diverse per chi legge l'archivio.
  it "il motivo del blocco dice da dove è stato visto" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("FAILURE") ])))

    expect(workflow.reload.blocked_reason).to start_with("candidate_check:")
    expect(workflow.blocked_reason).to include("checks_failing")
  end

  it "repository non collegato: si ferma senza nemmeno chiamare GitHub" do
    orfano = create(:agent_delivery_candidate, workflow:, repository: nil, organization:,
                                               repository_full_name: "qualcunaltro/repo", number: 3)
    client = instance_double(Github::Client)
    allow(client).to receive(:pull_request_state).and_raise("non doveva chiamare GitHub")

    described_class.call(candidate: orfano, client:)

    expect(orfano.reload).to be_state_rejected
    expect(orfano.last_error_code).to eq("repository_not_linked")
  end

  # Il ramo di destinazione va confrontato col ramo principale del repository di destinazione, letto
  # dalla STESSA risposta: prenderlo dal database vorrebbe dire confrontare quello che GitHub dice
  # adesso con quello che noi credevamo ieri.
  it "una proposta verso un ramo qualunque non passa" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("SUCCESS") ],
                                                                base_ref: "una-feature")))

    expect(candidate.reload).to be_state_rejected
    expect(candidate.last_error_code).to eq("base_not_default_branch")
    expect(ticket.reload.status).not_to eq(in_review)
  end

  # ── Idempotenza ───────────────────────────────────────────────────────────────────────────────

  # La riga verificata è la prova di cosa è stato approvato: un secondo giro non la tocca.
  it "un secondo giro su una riga già verificata non la riscrive" do
    described_class.call(candidate:, client: client_con(risposta(checks: [ check_run("SUCCESS") ])))
    primo = candidate.reload.verified_at

    described_class.call(candidate: candidate.reload,
                         client: client_con(risposta(checks: [ check_run("FAILURE") ])))

    expect(candidate.reload.verified_at).to eq(primo)
    expect(candidate).to be_state_verified_passing
  end
end
