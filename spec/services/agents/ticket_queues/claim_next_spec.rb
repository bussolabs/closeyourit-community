# frozen_string_literal: true

require "rails_helper"

# CYRA-588 — presa in carico atomica: sceglie il candidato E lo prende in carico dentro la stessa
# transazione, così due postazioni sulla stessa coda ottengono ticket diversi invece di contendersi la
# testa. Le proprietà di sicurezza sono riasserite QUI, sul percorso nuovo: non si ereditano per fiducia
# dal percorso in due passi solo perché il corpo del claim è lo stesso.
RSpec.describe Agents::TicketQueues::ClaimNext do
  subject(:result) { described_class.call(organization:, project_key:, host:, params:) }

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:project_key) { project.key }
  let!(:repository) { create(:github_repository, project:) }
  let(:host) { host_ready_for(project) }
  let(:params) { { host_id: host.id, run_id: "run-1" } }

  it "risponde «niente lavoro» quando la coda non ha candidati" do
    expect(result).to be_ok
    expect(result.value).to be_nil
    expect(Agents::Lease).not_to exist
    expect(Agents::LimitReservation).not_to exist
  end

  it "consegna in un colpo solo lo snapshot del candidato, il lease e il tentativo" do
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect(result).to be_ok
    outcome = result.value
    expect(outcome.ticket).to eq(candidate)
    expect(outcome.fresh_acquisition).to be(true)
    expect(outcome.lease).to have_attributes(
      ticket_id: candidate.id, host_id: host.id, run_id: "run-1", execution_phase: "triage", agent: nil
    )
    expect(outcome.attempt).to have_attributes(phase: "triage", host_id: host.id, status: "running")
    expect(Agents::LimitReservation.sole).to have_attributes(project:, host:, outcome: "granted")
  end

  # CYRA-681 — la scheda del candidato cita la versione del piano CONGELATO all'approvazione, e il
  # caricamento è in modalità severa apposta: un'associazione non precaricata solleva invece di fare
  # una query a sorpresa. `frozen_plan` non era nell'elenco, quindi il primo candidato con un piano
  # approvato abbatteva la richiesta — e con lei la coda intera di quel progetto, per sempre.
  #
  # Latente dal giorno in cui il campo è entrato nella scheda: finché nessun piano è approvato la
  # chiave esterna è vuota, Rails non fa nessuna query e la modalità severa non ha niente da vietare.
  # In produzione si è visto solo quando il lavoro ha cominciato ad avanzare davvero: 25 ore di coda
  # ferma con l'host acceso e in salute.
  it "consegna il candidato anche quando il suo piano è già stato approvato e congelato" do
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = candidate.agent_workflow
    workflow.update!(triaged_at: 2.hours.ago)
    attempt = create(:agent_attempt, workflow:, organization:, phase: "planner")
    # Il vincolo congelato c'è (CYRA-682 lo pretende per le fasi che scrivono): qui si prova che la
    # scheda del candidato si compone senza esplodere, non l'assenza del vincolo.
    plan = Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [],
                                definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot",
                                candidate_items: [ { "repo" => "bussolabs/x", "base" => "main" } ],
                                completion_probe: { "kind" => "merge", "repo" => "bussolabs/x" })
    # Lo stato reale: il piano è stato approvato, quindi è stato anche congelato e la fase pronta è
    # l'implementazione. È esattamente il momento in cui in produzione la coda si è impiantata.
    workflow.update!(planned_at: 1.hour.ago, approved_at: 30.minutes.ago,
                     frozen_plan: plan, plan_frozen_at: 30.minutes.ago)

    expect(result).to be_ok
    expect(result.value.ticket).to eq(candidate)
  end

  # CYRA-682 — la fase che SCRIVE codice non parte senza il vincolo congelato all'approvazione: su
  # quale archivio può nascere il lavoro e qual è la prova che dirà «fatto». È una regola dell'host, ed
  # è giusta: meglio un ticket fermo che una macchina che inventa dove aprire la proposta.
  #
  # Ma il rifiuto arriva DOPO la presa in carico, e la presa in carico marca già la fase come avviata e
  # apre un tentativo. Nessuno lo esegue, il permesso scade, il tentativo muore orfano — e gli orfani
  # contano nel tetto. Due giri e la lavorazione si blocca, per sempre.
  #
  # Il server sa già, PRIMA di proporre, che quel vincolo non c'è: il piano congelato ce l'ha scritto
  # sopra. Quindi non lo propone, e il ticket resta in coda intatto finché il progetto non dichiara la
  # sua prova di rilascio — allora riparte da sé, senza che nessuno lo sblocchi.
  describe "una fase che scrive senza il vincolo congelato" do
    def piano_approvato(ticket, congelato:)
      workflow = ticket.agent_workflow
      workflow.update!(triaged_at: 2.hours.ago)
      attempt = create(:agent_attempt, workflow:, organization:, phase: "planner")
      plan = Agents::Plan.create!(
        workflow:, attempt:, technical_analysis: "Piano", scenarios: [], definition_of_done: [ "RSpec" ],
        notes: [], ticket_snapshot_digest: "snapshot",
        **(congelato ? { candidate_items: [ { "repo" => "bussolabs/x", "base" => "main" } ],
                         completion_probe: { "kind" => "merge", "repo" => "bussolabs/x" } } : {})
      )
      workflow.update!(planned_at: 1.hour.ago, approved_at: 30.minutes.ago,
                       frozen_plan: plan, plan_frozen_at: 30.minutes.ago)
      workflow
    end

    it "non viene proposta: il ticket resta in coda invece di bruciarsi" do
      ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
      workflow = piano_approvato(ticket, congelato: false)

      expect(workflow.ready_execution_phase).to eq("autopilot"), "il montaggio non descrive il caso"
      expect(result).to be_ok
      expect(result.value).to be_nil
      expect(Agents::Lease).not_to exist
      expect(Agents::Attempt.where(phase: "autopilot")).not_to exist
    end

    it "viene proposta appena il vincolo c'è" do
      ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
      piano_approvato(ticket, congelato: true)

      expect(result).to be_ok
      expect(result.value.ticket).to eq(ticket)
      expect(result.value.attempt.phase).to eq("autopilot")
    end

    # Le fasi che LEGGONO non hanno un vincolo da rispettare e non devono essere toccate dal filtro:
    # producono un giudizio e un documento, non aprono niente e non rilasciano niente.
    it "non tocca le fasi che leggono soltanto" do
      ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

      expect(ticket.agent_workflow.ready_execution_phase).to eq("triage")
      expect(result).to be_ok
      expect(result.value.ticket).to eq(ticket)
    end
  end

  # Il client non può dichiarare un TTL: la fase la sceglie il server insieme al ticket, e con lei il
  # timeout autoritativo del profilo. Nel percorso in due passi il TTL arriva dal client solo perché lì
  # la fase è già nota (l'ha vista nel preflight).
  it "fissa il TTL dal profilo della fase pronta, senza chiederlo al client" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect(result).to be_ok
    expect(Agents::Lease.sole).to have_attributes(authoritative_ttl_seconds: 3600)
    expect(Agents::LimitReservation.sole.requested_ttl_seconds).to eq(3600)
  end

  it "sceglie la priorità più alta e, a parità, il numero più basso" do
    create(:ticket, :agent_workable, organization:, project:,
                    priority: create(:ticket_priority, organization:, position: 0), with_agent_workflow: true)
    high_priority = create(:ticket_priority, organization:, position: 10)
    first = create(:ticket, :agent_workable, organization:, project:, priority: high_priority, with_agent_workflow: true)
    create(:ticket, :agent_workable, organization:, project:, priority: high_priority, with_agent_workflow: true)

    expect(result.value.ticket).to eq(first)
  end

  # Scenario 1/2 in versione sequenziale: la seconda richiesta non riceve «non più valido» e non
  # ripropone il ticket appena consegnato — lo trova già preso e passa al successivo.
  it "due richieste di fila ottengono due ticket diversi, poi «niente lavoro»" do
    first = create(:ticket, :agent_workable, organization:, project:,
                            priority: create(:ticket_priority, organization:, position: 10), with_agent_workflow: true)
    second = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect(result.value.ticket).to eq(first)

    following = described_class.call(organization:, project_key:, host:, params: params.merge(run_id: "run-2"))
    expect(following.value.ticket).to eq(second)

    empty = described_class.call(organization:, project_key:, host:, params: params.merge(run_id: "run-3"))
    expect(empty).to be_ok
    expect(empty.value).to be_nil
    expect(Agents::Lease.count).to eq(2)
  end

  it "non prende un ticket fuori dalla coda: vietato agli agenti, chiuso, già tenuto o deferito" do
    now = Time.zone.parse("2026-08-17 09:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    create(:ticket, :agent_blocked, organization:, project:, with_agent_workflow: true)
    create(:ticket, :agent_workable, organization:, project:, status: create(:ticket_status, :done, organization:), with_agent_workflow: true)
    held = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    create(:agent_lease, organization:, ticket: held, host: create(:agent_host, organization:),
                         expires_at: now + 1.hour)
    deferred = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    create(:agent_ticket_queue_deferral, organization:, ticket: deferred, host:,
                                         created_at: now - 1.minute, retry_at: now + 1.minute)

    expect(result).to be_ok
    expect(result.value).to be_nil
  end

  it "rifiuta un host non certificato" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    host.update!(certified_at: nil)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R403-AGENT-006", status: :forbidden)
    expect(Agents::Lease).not_to exist
  end

  it "rifiuta un host storico non Linux prima di riservare risorse" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    host.update_column(:platform, "darwin")

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R403-AGENT-006", status: :forbidden)
    expect(Agents::Lease).not_to exist
    expect(Agents::LimitReservation).not_to exist
  end

  it "rifiuta un progetto fuori dallo scope dell'host senza rivelarne l'esistenza" do
    other_project = create(:project, organization:, key: "OTHR")
    create(:github_repository, project: other_project, installation: repository.installation)
    create(:ticket, :agent_workable, organization:, project: other_project, with_agent_workflow: true)

    outcome = described_class.call(organization:, project_key: other_project.key, host:, params:)

    expect(outcome).to be_err
    expect(outcome.error).to have_attributes(code: "R404-AGENT-002", status: :not_found)
    expect(Agents::Lease).not_to exist
  end

  it "nega la presa in carico quando il tetto delle lavorazioni in parallelo è saturo" do
    create(:agent_limit_policy, organization:, max_parallel: 0)
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R409-QUEUE-002", status: :conflict)
    expect(result.error.details).to eq({ reason: "max_parallel" })
    expect(Agents::Lease).not_to exist
    expect(Agents::LimitReservation.sole).to have_attributes(outcome: "denied", denial_reason: "max_parallel")
  end

  # La presa in carico vive dentro la transazione che ha scelto il candidato: se qualcosa cade DOPO la
  # prenotazione del budget, quella prenotazione dev'essere annullata come nel percorso in due passi. Un
  # rollback che si limitasse a unirsi alla transazione esterna verrebbe inghiottito in silenzio, e qui
  # resterebbero scritti budget consumato e lease.
  it "annulla prenotazione, consumo e lease se l'host viene revocato dopo la prenotazione" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    allow_any_instance_of(Agents::TicketQueues::Claim).to receive(:after_limit_reserved).and_wrap_original do |original, value|
      Agents::Host.where(id: host.id).update_all(revoked_at: Time.current)
      original.call(value)
    end

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-QUEUE-001", status: :not_found)
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
    expect(Agents::Lease).not_to exist
  end

  it "rifiuta una richiesta di lease non valida senza consumare limiti" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    outcome = described_class.call(organization:, project_key:, host:, params: params.merge(run_id: ""))

    expect(outcome).to be_err
    expect(outcome.error).to have_attributes(code: "R422-LEASE-001", status: :unprocessable_content)
    expect(Agents::Lease).not_to exist
    expect(Agents::LimitReservation).not_to exist
  end

  it "rifiuta un host_id che non coincide con l'host autenticato" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    other_host = create(:agent_host, organization:)

    outcome = described_class.call(organization:, project_key:, host:, params: params.merge(host_id: other_host.id))

    expect(outcome).to be_err
    expect(outcome.error).to have_attributes(code: "R403-LEASE-001", status: :forbidden)
    expect(Agents::Lease).not_to exist
  end

  # La visibilità del service account dell'host è il gate di progetto: se sparisce, la coda del progetto
  # non esiste più per quell'host — nemmeno dal percorso nuovo.
  it "smette di servire la coda quando il progetto esce dallo scope dell'host" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    Connections::ProjectMembership.where(account: host.service_account, project:).delete_all

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-AGENT-002", status: :not_found)
    expect(Agents::Lease).not_to exist
  end

  it "non attraversa il confine di tenant" do
    foreign_project = create(:project, key: "CYAU")
    create(:github_repository, project: foreign_project)
    create(:ticket, :agent_workable, organization: foreign_project.organization, project: foreign_project, with_agent_workflow: true)

    expect(result).to be_ok
    expect(result.value).to be_nil
  end

  def host_ready_for(target)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA",
                                                     project_ids: [ target.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ target.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end
end
