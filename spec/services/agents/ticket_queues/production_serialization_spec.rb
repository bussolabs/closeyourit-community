# frozen_string_literal: true

require "rails_helper"

# CYRA-595 — la coda e la presa in carico rispettano «un rilascio in produzione alla volta».
#
# Due difese, non una: la coda filtra a monte, così un ticket che dovrebbe aspettare non viene
# nemmeno proposto; e la presa in carico ricontrolla sotto lock, perché fra la proposta e la presa
# può essere partito un altro rilascio. La coda da sola non basta, e il ricontrollo da solo farebbe
# girare a vuoto una macchina per ogni giro.
RSpec.describe "CYRA-595 — un rilascio in produzione alla volta" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:host) { host_ready_for(project) }

  def host_ready_for(target)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}",
                                                     project_ids: [ target.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ target.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  # Un ticket pronto per il rilascio in produzione: staging concluso e via libera dato.
  # CYRA-621 — il numero lo assegna il server, e per sapere da dove partire chiede quali versioni sono
  # già uscite: senza, la presa in carico fallisce per un motivo che non è quello in prova.
  before { versioni_uscite("v1.0.0") }

  def pronto_al_rilascio(progetto: project)
    ticket = create(:ticket, :agent_workable, organization:, project: progetto, with_agent_workflow: true)
    ticket.agent_workflow.update!(
      triaged_at: 1.hour.ago, planned_at: 1.hour.ago, approved_at: 1.hour.ago,
      autopilot_started_at: 1.hour.ago, autopilot_completed_at: 1.hour.ago,
      autopilot_approved_at: 1.hour.ago, closer_staging_started_at: 1.hour.ago,
      closer_staging_completed_at: 3.hours.ago, closer_staging_verified_at: 3.hours.ago, closer_production_approved_at: 10.minutes.ago,
    )
    # CYRA-621 — la produzione non parte senza il punto di codice che il sistema ha VISTO atterrare:
    # è quello che il server assegna insieme al numero di versione. Sta nel result del closer di
    # staging, che è audit immutabile.
    create(:agent_attempt, workflow: ticket.agent_workflow, organization:, phase: "closer_staging",
                           status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => "a" * 40 })
    # CYRA-682 — le fasi che toccano il repository non arrivano in coda senza il vincolo congelato
    # all'approvazione: qui lo stato è montato a mano, quindi va congelato a mano.
    congela_vincolo!(ticket.agent_workflow)
    ticket
  end

  def in_rilascio!(ticket)
    ticket.agent_workflow.update!(closer_production_started_at: 5.minutes.ago)
  end

  def coda = Agents::TicketQueues::Candidates.new(project:, host:).head_id

  describe "la coda" do
    it "propone il rilascio quando nessun altro sta rilasciando" do
      ticket = pronto_al_rilascio

      expect(coda).to eq(ticket.id)
    end

    it "NON lo propone mentre un altro rilascio è in corso sullo stesso repository" do
      in_rilascio!(pronto_al_rilascio)
      pronto_al_rilascio

      expect(coda).to be_nil
    end

    it "lo ripropone appena il rilascio in corso si conclude" do
      primo = pronto_al_rilascio
      in_rilascio!(primo)
      secondo = pronto_al_rilascio
      expect(coda).to be_nil

      primo.agent_workflow.update!(completed_at: Time.current)

      expect(coda).to eq(secondo.id)
    end

    # A essere irreversibile è l'ultimo passo, non la catena: fermare tutto sarebbe fermare la
    # fabbrica per proteggere una porta sola.
    it "le altre fasi continuano in parallelo mentre un rilascio è in corso" do
      in_rilascio!(pronto_al_rilascio)
      da_analizzare = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)

      expect(coda).to eq(da_analizzare.id)
    end

    it "un rilascio su un altro repository non ferma questo" do
      altro = create(:project, organization:, key: "CYSK")
      create(:github_repository, project: altro)
      in_rilascio!(pronto_al_rilascio(progetto: altro))
      mio = pronto_al_rilascio

      expect(coda).to eq(mio.id)
    end

    # Il ramo che sembra un di più: quando un rilascio va male la fase viene RIAPERTA e solo dopo
    # arriva il blocco. Senza, il rilascio successivo partirebbe proprio mentre quello prima è rotto.
    it "un rilascio fallito e in attesa di una persona tiene comunque la fila" do
      rotto = pronto_al_rilascio
      rotto.agent_workflow.update!(closer_production_started_at: nil, blocked_at: Time.current,
                                   blocked_phase: "closer_production", blocked_kind: "attempt_limit")
      pronto_al_rilascio

      expect(coda).to be_nil
    end
  end

  describe "la presa in carico" do
    # La coda filtra a monte, ma non è un lucchetto: fra la proposta e la presa può essere partito
    # un altro rilascio. Qui si simula esattamente quella finestra.
    it "rifiuta con un motivo suo se un altro rilascio è partito nel frattempo" do
      ticket = pronto_al_rilascio
      concorrente = pronto_al_rilascio
      token = Agents::TicketQueues::Selection.issue(ticket:, host:)
      in_rilascio!(concorrente)

      esito = Agents::TicketQueues::Claim.call(
        organization:, host:, selection_token: token,
        params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 },
      )

      expect(esito).to be_err
      expect(esito.error.code).to eq("R409-QUEUE-006")
      expect(esito.error.details[:code]).to eq(concorrente.code)
      expect(esito.error.details[:since]).to be_present
    end

    it "non lascia né prenotazione né tentativo quando rifiuta" do
      ticket = pronto_al_rilascio
      token = Agents::TicketQueues::Selection.issue(ticket:, host:)
      in_rilascio!(pronto_al_rilascio)

      Agents::TicketQueues::Claim.call(organization:, host:, selection_token: token,
                                       params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 })

      expect(Agents::Lease.where(ticket:)).not_to exist
      # La FASE che si stava prendendo in carico: il tentativo dello staging c'è per costruzione — è
      # quello che porta il punto di codice verificato — e contarlo direbbe che il rifiuto ha lasciato
      # qualcosa quando non ha lasciato niente.
      expect(Agents::Attempt.where(workflow: ticket.agent_workflow, phase: "closer_production"))
        .not_to exist
    end

    it "prende in carico normalmente quando la fila è libera" do
      ticket = pronto_al_rilascio
      token = Agents::TicketQueues::Selection.issue(ticket:, host:)

      esito = Agents::TicketQueues::Claim.call(organization:, host:, selection_token: token,
                                               params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 })

      expect(esito).to be_ok
      expect(Agents::Lease.where(ticket:)).to exist
    end
  end
end

# Il motivo leggibile: «aspetta una macchina libera» e «aspetta che finisca un altro rilascio» sono
# due attese diverse. La prima dura minuti e non dipende da niente; la seconda dipende da un lavoro
# preciso, che si può andare a guardare. Dirle con la stessa frase lascia chi legge senza il dato che
# serve.
RSpec.describe Member::AutomationSummary, "il motivo dell'attesa in produzione" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }

  def pronto_al_rilascio
    ticket = create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true)
    ticket.agent_workflow.update!(
      triaged_at: 1.hour.ago, planned_at: 1.hour.ago, approved_at: 1.hour.ago,
      autopilot_started_at: 1.hour.ago, autopilot_completed_at: 1.hour.ago,
      autopilot_approved_at: 1.hour.ago, closer_staging_started_at: 1.hour.ago,
      closer_staging_completed_at: 3.hours.ago, closer_staging_verified_at: 3.hours.ago, closer_production_approved_at: 10.minutes.ago,
    )
    # CYRA-682 — come sopra: qui si prova la frase dell'attesa in coda, e senza il vincolo congelato
    # la frase giusta sarebbe un'altra («non può partire»). Lo stato va montato per intero.
    congela_vincolo!(ticket.agent_workflow)
    ticket
  end

  def frase(ticket, decides: true)
    described_class.new(workflow: ticket.agent_workflow.reload, attempts: [], decides:).stopped
  end

  # Confrontare col TESTO legherebbe lo spec alla lingua in cui gira la suite: si confronta con la
  # frase tradotta della chiave attesa, che è la stessa cosa detta in modo stabile.
  def testo(chiave, **valori)
    I18n.t("member.tickets.automation.summary.stopped.#{chiave}", **valori)
  end

  it "senza nessun rilascio in corso dice che aspetta una macchina" do
    ticket = pronto_al_rilascio

    expect(frase(ticket)).to eq(testo("queued"))
  end

  it "con un rilascio in corso nomina il ticket che tiene la fila" do
    tenente = pronto_al_rilascio
    tenente.agent_workflow.update!(closer_production_started_at: 5.minutes.ago)
    mio = pronto_al_rilascio

    expect(frase(mio)).to eq(testo("production_busy", code: tenente.code))
  end

  # Il codice si mostra solo a chi può vedere quel ticket: dirgli «aspetta CYRA-42» quando CYRA-42
  # non è suo sarebbe rivelare l'esistenza di un lavoro che non deve vedere.
  it "a chi non decide dice che aspetta, senza nominare il ticket" do
    tenente = pronto_al_rilascio
    tenente.agent_workflow.update!(closer_production_started_at: 5.minutes.ago)
    mio = pronto_al_rilascio

    detto = frase(mio, decides: false)

    expect(detto).not_to include(tenente.code)
    expect(detto).to eq(testo("production_busy_anonymous"))
  end
end
