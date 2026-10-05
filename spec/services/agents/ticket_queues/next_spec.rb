# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::TicketQueues::Next do
  subject(:result) { described_class.call(organization:, project_key:, host:) }

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:project_key) { project.key }
  let!(:repository) { create(:github_repository, project:) }
  # Host-first (CYAU-84): lo scope è la sola visibilità dell'host sul progetto (ProjectScope host-only, via il
  # service account dell'host). Nessun agente/comando nel percorso.
  let(:host) { host_seeing(project) }

  it "restituisce nil quando la coda non contiene ticket lavorabili" do
    expect(result).to be_ok
    expect(result.value).to be_nil
  end

  it "rifiuta un host storico non Linux" do
    host.update_column(:platform, "darwin")

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R403-AGENT-006", status: :forbidden)
  end

  # Il candidato viene caricato `strict_loading`: un'associazione che il serializer legge ma il preload non
  # copre non degrada a query, SOLLEVA — e il preflight dell'host traduce l'eccezione in «snapshot coda
  # ticket non disponibile», cioè l'intera coda del progetto si ferma. È successo con `approved_by` del
  # piano: qui il candidato viene serializzato davvero, non solo caricato, così il preload resta legato a
  # ciò che il serializer tocca.
  it "serializza un candidato con piano approvato senza violare strict_loading" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, organization:, workflow:)
    cto = create(:account, name: "Alessio")
    create(:membership, organization:, account: cto)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [], definition_of_done: [],
                         notes: [], ticket_snapshot_digest: "snapshot", approved_by: cto, approved_at: Time.current)

    candidate = result.value
    expect(candidate).to eq(ticket)
    payload = nil
    expect { payload = AgentTicketCandidateSerializer.new(candidate).as_json }
      .not_to raise_error
    expect(payload.dig("workflow", :current_plan)).to include(approved_by: "Alessio")
  end

  # Terza associazione, stessa storia: `review_candidate` porta all'host il commit approvato. Il
  # 2026-09-03 la coda CYRA e' morta con 500 per un'ora perche' il preload non la copriva, e il
  # difetto si sveglia solo quando una consegna e' gia' stata approvata — cioe' a lavoro avanzato.
  it "serializza un candidato con consegna approvata senza violare strict_loading" do
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    workflow.update!(ticket_snapshot_digest: "snapshot")
    repository = project.github_repository || create(:github_repository, project:, full_name: "bussolabs/app")
    candidato = create(:agent_delivery_candidate, :verified_passing, workflow:, organization:, repository:,
                                                  repository_full_name: repository.full_name, number: 7,
                                                  head_sha: "9" * 40, base_ref: "main")
    workflow.update!(review_candidate: candidato)

    payload = nil
    expect { payload = AgentTicketCandidateSerializer.new(result.value).as_json }.not_to raise_error
    expect(payload.dig("workflow", :frozen_candidate)).to include(head_sha: "9" * 40, number: 7)
  end

  it "può riproporre lo stesso candidato senza creare un claim" do
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect do
      expect(result.value).to eq(candidate)
      expect(described_class.call(organization:, project_key:, host:).value).to eq(candidate)
    end.not_to change(Agents::Lease, :count)
  end

  it "sceglie la priorità più alta e poi il numero più basso" do
    low = create(:ticket, :agent_workable, organization:, project:,
                          priority: create(:ticket_priority, organization:, position: 0), with_agent_workflow: true)
    high_later = create(:ticket, :agent_workable, organization:, project:,
                                 priority: create(:ticket_priority, organization:, position: 10), with_agent_workflow: true)
    high_first = create(:ticket, :agent_workable, organization:, project:,
                                 priority: high_later.priority, with_agent_workflow: true)

    expect(result.value).to eq(high_later)
    expect(result.value).not_to eq(low)
    expect(result.value).not_to eq(high_first)
  end

  it "considera gli status open e in_progress ma esclude i done" do
    done_status = create(:ticket_status, :done, organization:)
    progress_status = create(:ticket_status, :in_progress, organization:)
    create(:ticket, :agent_workable, organization:, project:, status: done_status,
                    priority: create(:ticket_priority, organization:, position: 20), with_agent_workflow: true)
    candidate = create(:ticket, :agent_workable, organization:, project:, status: progress_status, with_agent_workflow: true)

    expect(result.value).to eq(candidate)
  end

  it "esclude un ticket con lease attivo e include quello con lease scaduto" do
    now = Time.zone.parse("2026-07-14 02:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    active = create(:ticket, :agent_workable, organization:, project:,
                             priority: create(:ticket_priority, organization:, position: 20), with_agent_workflow: true)
    expired = create(:ticket, :agent_workable, organization:, project:,
                              priority: create(:ticket_priority, organization:, position: 10), with_agent_workflow: true)
    create(:agent_lease, organization:, ticket: active,
                         host: create(:agent_host, organization:), expires_at: now + 1.second)
    create(:agent_lease, organization:, ticket: expired,
                         host: create(:agent_host, organization:), expires_at: now)

    expect(result.value).to eq(expired)
  end

  # CYRA-293 — la coda filtra sul lease, non sul titolare: un ticket preso in carico da una persona
  # sparisce dalla coda degli agenti senza che la query debba saperne nulla.
  it "esclude un ticket tenuto da una persona esattamente come uno tenuto da un host" do
    now = Time.zone.parse("2026-07-14 02:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    held_by_person = create(:ticket, :agent_workable, organization:, project:,
                                     priority: create(:ticket_priority, organization:, position: 20), with_agent_workflow: true)
    free = create(:ticket, :agent_workable, organization:, project:,
                           priority: create(:ticket_priority, organization:, position: 10), with_agent_workflow: true)
    create(:agent_lease, organization:, ticket: held_by_person, host: nil, agent: nil,
                         account: create(:membership, organization:).account, expires_at: now + 1.hour)

    expect(result.value).to eq(free)
  end

  it "salta la head deferita per il proprio host+fase e la lascia visibile a un altro host" do
    now = Time.zone.parse("2026-07-14 02:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    head = create(:ticket, :agent_workable, organization:, project:,
                           priority: create(:ticket_priority, organization:, position: 20), with_agent_workflow: true)
    second = create(:ticket, :agent_workable, organization:, project:,
                             priority: create(:ticket_priority, organization:, position: 10), with_agent_workflow: true)
    other_host = host_seeing(project)
    create(:agent_ticket_queue_deferral, organization:, host:, ticket: head,
                                         created_at: now - 1.minute, retry_at: now + 1.second)
    create(:agent_ticket_queue_deferral, organization:, host:, ticket: head,
                                         created_at: now - 2.minutes, retry_at: now - 1.second)

    expect(result.value).to eq(second)
    expect(described_class.call(organization:, project_key:, host: other_host).value).to eq(head)
  end

  it "ripropone il ticket quando il defer del proprio host+fase raggiunge retry_at" do
    now = Time.zone.parse("2026-07-14 02:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    create(:agent_ticket_queue_deferral, organization:, host:, ticket: candidate,
                                         created_at: now - 1.minute, retry_at: now)

    expect(result.value).to eq(candidate)
  end

  # Host-first (CYAU-79): l'host reclama la PROSSIMA FASE PRONTA del ticket, non una fase fissa.
  it "reclama un ticket pronto per una fase avanzata (host-scoped)" do
    planner_ready = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    planner_ready.agent_workflow.update!(triage_started_at: 2.minutes.ago, triaged_at: 1.minute.ago)

    expect(result.value).to eq(planner_ready)
  end

  it "reclama un ticket pronto per un closer avanzato" do
    now = Time.current
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    candidate.agent_workflow.update!(
      triage_started_at: now, triaged_at: now, planned_at: now, approved_at: now, autopilot_started_at: now,
      autopilot_completed_at: now, autopilot_approved_at: now, closer_staging_started_at: now,
      # CYRA-504 — il via libera umano fa parte della catena: senza, la produzione non è reclamabile.
      closer_staging_completed_at: now, closer_staging_verified_at: 3.hours.ago, closer_production_approved_at: now
    )
    # CYRA-682 — una fase che tocca il repository non arriva in coda senza il vincolo congelato
    # all'approvazione: qui lo stato è montato a mano e va completato.
    congela_vincolo!(candidate.agent_workflow)

    expect(result.value).to eq(candidate) # fase pronta = closer_production
  end

  it "il defer di una fase non nasconde un ticket pronto per un'altra fase; sulla fase pronta sì" do
    now = Time.zone.parse("2026-07-14 02:00:00")
    allow(Agents::Leases::Clock).to receive(:current).and_return(now)
    planner_ready = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    planner_ready.agent_workflow.update!(triage_started_at: now - 2.minutes, triaged_at: now - 1.minute)
    # defer per la fase SBAGLIATA (triage) non correla con la fase pronta (planner) → resta visibile
    create(:agent_ticket_queue_deferral, organization:, host:, ticket: planner_ready,
                                         execution_phase: "triage", created_at: now - 1.minute, retry_at: now + 1.hour)

    expect(result.value).to eq(planner_ready)

    # defer sulla fase PRONTA (planner) correla per-riga → sparisce
    create(:agent_ticket_queue_deferral, organization:, host:, ticket: planner_ready,
                                         execution_phase: "planner", created_at: now, retry_at: now + 1.hour)

    expect(described_class.call(organization:, project_key:, host:).value).to be_nil
  end

  it "non attraversa il confine di progetto o tenant" do
    other_project = create(:project, organization:, key: "OTHR")
    foreign_project = create(:project, key: "CYAU")
    create(:ticket, :agent_workable, organization:, project: other_project,
                    priority: create(:ticket_priority, organization:, position: 20), with_agent_workflow: true)
    create(:ticket, :agent_workable, organization: foreign_project.organization, project: foreign_project,
                    priority: create(:ticket_priority, organization: foreign_project.organization, position: 30), with_agent_workflow: true)
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect(result.value).to eq(candidate)
  end

  # Host-first (CYAU-84): il capability gate agent-based è spostato host-side → la certificazione dell'host.
  it "rifiuta un host non certificato (gate host-side)" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    host.update!(certified_at: nil)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R403-AGENT-006", status: :forbidden)
  end

  it "rifiuta un progetto fuori dallo scope dell'host senza rivelarne l’esistenza" do
    other_project = create(:project, organization:, key: "OTHR")
    create(:github_repository, project: other_project, installation: repository.installation)

    result = described_class.call(organization:, project_key: other_project.key, host:)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-AGENT-002", status: :not_found)
  end

  it "accetta un progetto reso visibile all'host attraverso un gruppo" do
    group = create(:group, organization:)
    project.update!(group:)
    group_host = host_seeing_group(group)
    candidate = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

    expect(described_class.call(organization:, project_key:, host: group_host).value).to eq(candidate)
  end

  it "rifiuta un progetto di un altro tenant" do
    foreign_project = create(:project, key: "OTHR")
    create(:github_repository, project: foreign_project)

    result = described_class.call(organization:, project_key: foreign_project.key, host:)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-AGENT-002", status: :not_found)
  end

  it "rifiuta un progetto senza repository attestabile" do
    repository.destroy!

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-AGENT-002", status: :not_found)
  end

  it "non rivela il progetto se il service account dell'host non lo vede" do
    create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    blind_host = host_seeing_nothing

    result = described_class.call(organization:, project_key:, host: blind_host)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-AGENT-002", status: :not_found)
  end

  describe "gate di eleggibilità agenti (CYRA-184)" do
    it "esclude i ticket ancora da valutare" do
      create(:ticket, organization:, project:, with_agent_workflow: true)

      expect(result.value).to be_nil
    end

    it "esclude i ticket bloccati" do
      create(:ticket, :agent_blocked, organization:, project:, with_agent_workflow: true)

      expect(result.value).to be_nil
    end

    # Il gate precede l'ordinamento: un ticket vietato non viene "scelto e poi scartato", non entra
    # proprio nell'insieme dei candidati, nemmeno a priorità massima.
    it "salta un ticket bloccato a priorità più alta e serve quello consentito" do
      create(:ticket, :agent_blocked, organization:, project:,
                      priority: create(:ticket_priority, organization:, position: 90), with_agent_workflow: true)
      workable = create(:ticket, :agent_workable, organization:, project:,
                                 priority: create(:ticket_priority, organization:, position: 1), with_agent_workflow: true)

      expect(result.value).to eq(workable)
    end

    it "torna a servire un ticket appena viene consentito" do
      ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
      expect(result.value).to be_nil

      ticket.update!(agent_eligibility: :allowed)

      expect(described_class.call(organization:, project_key:, host:).value).to eq(ticket)
    end

    # CYRA-770 — è la prova che regge tutto il ticket: il parere dell'AI non apre nessuna coda.
    # Prima il verdetto del modello finiva nella stessa colonna che questa query interroga, quindi
    # bastava che l'AI dicesse «lavorabile» perché un agente prendesse il ticket senza che nessuna
    # persona lo avesse consentito.
    describe "il parere dell'AI non vale come consenso (CYRA-770)" do
      it "esclude un ticket con parere favorevole ma nessuna decisione" do
        create(:ticket, :agent_advice_allowed, organization:, project:, with_agent_workflow: true)

        expect(result.value).to be_nil
      end

      it "lo serve solo dopo che una persona lo ha consentito" do
        ticket = create(:ticket, :agent_advice_allowed, organization:, project:, with_agent_workflow: true)
        expect(result.value).to be_nil

        Ticketing::SetAgentEligibility.call(ticket:, source: :human, eligibility: "allowed",
                                            reason: "Lo seguo io.", actor: ticket.reporter)

        expect(described_class.call(organization:, project_key:, host:).value).to eq(ticket)
      end
    end

    # REGRESSIONE: il gate vive nella query di Next, NON dentro READY_EXECUTION_PHASE_SQL. Se qualcuno
    # lo spostasse nel CASE, un ticket bloccato risulterebbe "senza fase pronta" — una bugia che
    # farebbe divergere il gemello Ruby dal SQL e romperebbe Selection.issue.
    it "non altera la fase pronta calcolata dal workflow del ticket bloccato" do
      blocked = create(:ticket, :agent_blocked, organization:, project:, with_agent_workflow: true)

      expect(blocked.agent_workflow.ready_execution_phase).to eq("triage")
      expect(Agents::Workflow.where(id: blocked.agent_workflow.id)
                             .pick(Arel.sql(Agents::Workflow::READY_EXECUTION_PHASE_SQL))).to eq("triage")
    end
  end

  # Host che vede il progetto tramite il proprio service account (ProjectScope host-only). Handle
  # auto-dedotto e deduplicato da Accounts::Service::Create, quindi ogni host ottiene un handle unico.
  def host_seeing(project)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:)
  end

  def host_seeing_group(group)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA", group_ids: [ group.id ]).value
    create(:agent_host, organization:, service_account:)
  end

  def host_seeing_nothing
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA").value
    create(:agent_host, organization:, service_account:)
  end
end
