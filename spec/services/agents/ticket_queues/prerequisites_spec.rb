# frozen_string_literal: true

require "rails_helper"

# ── CYRA-623 ──────────────────────────────────────────────────────────────────────────────────────
#
# La coda da cui la macchina prende il lavoro non guardava i prerequisiti: metteva in fila per
# priorità e numero, e basta. Un ticket che stava aspettando veniva preso lo stesso — esaminato,
# pianificato, approvato da una persona, scritto per intero, spinto su un ramo con la proposta aperta
# — e solo lì sbatteva contro il cancello. Il giro di macchina era già stato pagato tutto, il tempo di
# chi aveva approvato il piano pure, e su GitHub restava un ramo che nessuno voleva.
#
# Qui si prova la cosa che conta: la coda fa la STESSA domanda del cancello. Se fosse più permissiva
# il giro tornerebbe buttato; se fosse più severa due ticket messi in fila non uscirebbero mai insieme.
RSpec.describe "coda e prerequisiti", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:host) { host_che_vede(project) }

  # CYRA-621 — prendere in carico una fase di rilascio assegna il numero di versione, e per farlo il
  # server chiede a GitHub quali sono già uscite. Senza il finto la presa in carico fallirebbe per un
  # motivo che non è quello in prova.
  before { versioni_uscite("v0.1.0") }

  def host_che_vede(target)
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA",
                                                     project_ids: [ target.id ]).value
    create(:agent_host, organization:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ target.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def ticket_pronto(fase, numero_priorita: 0)
    ticket = create(:ticket, :agent_workable, organization:, project:,
                             priority: create(:ticket_priority, organization:, position: numero_priorita), with_agent_workflow: true)
    pronta_per!(ticket.agent_workflow, fase)
    # Il rilascio definitivo pretende il commit che il sistema ha visto atterrare (CYRA-620/621):
    # senza, la fase non parte per un motivo che non è quello in prova.
    commit_verificato!(ticket.agent_workflow) if fase == "closer_production"
    ticket
  end

  def coda_next = Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:)

  def coda_claim
    Agents::TicketQueues::ClaimNext.call(organization:, project_key: project.key, host:,
                                         params: { host_id: host.id, run_id: "run-#{SecureRandom.hex(4)}" })
  end

  # ── L'elenco delle fasi NON è scritto a mano: è quello da cui il sistema stesso le enumera. Una fase
  # aggiunta al sistema fa fallire questa prova finché non è coperta, e un elenco vuoto non passa.
  FASI_DELLA_CODA = Agents::PhaseProfile::PHASES
  it "il sistema dichiara cinque fasi: se ne aggiunge una, questa prova deve accorgersene" do
    expect(FASI_DELLA_CODA).to match_array(%w[triage planner autopilot closer_staging closer_production])
  end

  FASI_DELLA_CODA.each do |fase|
    describe "fase #{fase}" do
      # Il montaggio si prova per primo: senza, «non viene servito» passerebbe anche su un apparecchio
      # rotto, dove il ticket non sarebbe stato servito comunque.
      it "senza prerequisiti il ticket viene servito, e la fase consegnata è proprio questa" do
        atteso = ticket_pronto(fase)

        expect(coda_next.value).to eq(atteso)
        expect(coda_claim.value.lease.execution_phase).to eq(fase)
      end

      it "con un prerequisito che questa fase non ammette il ticket viene saltato, e la coda serve quello sotto" do
        trattenuto = ticket_pronto(fase, numero_priorita: 10)
        blocker = create(:ticket, organization:, project:, with_agent_workflow: true)
        create(:ticket_dependency, ticket: trattenuto, blocker:)
        libero = ticket_pronto(fase, numero_priorita: 5)

        # Il salto non lascia niente dietro di sé: nessuna presa in carico, nessun tentativo né aperto
        # né chiuso, nessun rinvio di coda. Il conteggio è preso PRIMA e DOPO perché il montaggio di
        # una fase di rilascio scrive già un tentativo suo: quello che si prova è che la coda non ne
        # aggiunga, non che non ce ne siano.
        suoi_tentativi = -> { Agents::Attempt.where(workflow_id: trattenuto.agent_workflow.id).count }
        expect do
          expect(coda_next.value).to eq(libero)
          expect(coda_claim.value.ticket).to eq(libero)
        end.not_to change(&suoi_tentativi)

        expect(Agents::Lease.where(ticket_id: trattenuto.id)).to be_empty
        expect(Agents::TicketQueueDeferral.where(ticket_id: trattenuto.id)).to be_empty
        # E il permesso di lavorazione automatica resta «consentito»: un salto che si paga con una
        # leva appiccicosa la dovrebbe poi togliere una persona a mano.
        expect(trattenuto.reload.agent_eligibility).to eq("allowed")
      end

      it "col solo ticket trattenuto la coda risponde «niente lavoro» invece di servirlo" do
        trattenuto = ticket_pronto(fase)
        create(:ticket_dependency, ticket: trattenuto, blocker: create(:ticket, organization:, project:, with_agent_workflow: true))

        expect(coda_next.value).to be_nil
        expect(coda_claim.value).to be_nil
      end

      it "soddisfatto il prerequisito il ticket torna in testa, anche con altri lavorabili sotto" do
        trattenuto = ticket_pronto(fase, numero_priorita: 10)
        blocker = create(:ticket, organization:, project:, with_agent_workflow: true)
        create(:ticket_dependency, ticket: trattenuto, blocker:)
        ticket_pronto(fase, numero_priorita: 5)
        blocker.update!(status: create(:ticket_status, :done, organization:))

        expect(coda_next.value).to eq(trattenuto)
      end

      # Il cuore del ticket. Se la coda fosse più PERMISSIVA del cancello, il giro di macchina
      # tornerebbe buttato — è il guasto. Se fosse più SEVERA, due ticket messi in fila non
      # uscirebbero mai insieme. Quindi non basta che si somiglino: devono dire la stessa cosa su
      # ogni stato del prerequisito, compreso quello di un altro progetto dello stesso cliente.
      [
        [ "nessun prerequisito", :nessuno ],
        [ "né unito né rilasciato", :aperto ],
        [ "unito ma non ancora rilasciato", :unito ],
        [ "rilasciato", :fatto ],
        [ "in un altro progetto dello stesso cliente", :altrove ]
      ].each do |etichetta, stato|
        it "il verdetto della coda coincide con quello del cancello: prerequisito #{etichetta}" do
          ticket = ticket_pronto(fase)
          prepara_prerequisito(ticket, stato)

          cancello = Ticketing::DependencyGuard.call(
            ticket:, target_category: "in_progress", mode: Ticketing::DependencyGuard.mode_for(fase)
          )

          expect(coda_next.value.present?).to eq(cancello.ok?),
            "coda=#{coda_next.value.present?} cancello=#{cancello.ok?} su prerequisito #{etichetta}"
        end
      end
    end
  end

  # La domanda vive in un posto solo. Sostituendola lì con una che rifiuta sempre devono cambiare
  # INSIEME il verdetto della coda e quello del cancello, senza toccare il codice di nessuno dei due:
  # è la prova che non ne esistono due copie destinate a divergere.
  it "sostituendo il criterio in un posto solo cambiano insieme coda e cancello" do
    ticket = ticket_pronto("autopilot")
    blocker = create(:ticket, organization:, project:, status: create(:ticket_status, :done, organization:), with_agent_workflow: true)
    create(:ticket_dependency, ticket:, blocker:)

    expect(coda_next.value).to eq(ticket)
    expect(Ticketing::DependencyGuard.call(ticket:, target_category: "in_progress", mode: :merged)).to be_ok

    allow(Connections::TicketDependency).to receive(:unmet).and_return(Connections::TicketDependency.all)

    expect(coda_next.value).to be_nil
    expect(Ticketing::DependencyGuard.call(ticket:, target_category: "in_progress", mode: :merged)).to be_err
  end

  # ── Le due attese ────────────────────────────────────────────────────────────────────────────────
  #
  # Per cominciare a lavorare basta che il codice del prerequisito sia unito e controllato: così due
  # ticket messi in fila escono con lo stesso rilascio. Per rilasciare in produzione no: lì l'ordine
  # deciso da una persona va rispettato alla lettera.
  describe "unito basta per lavorare, non per rilasciare" do
    let(:blocker) { create(:ticket, organization:, project:, with_agent_workflow: true) }

    it "col codice del prerequisito unito e visto dal server le prime quattro fasi partono, la quinta no" do
      prerequisito_unito!(blocker)

      servite = FASI_DELLA_CODA.select { |fase| serve_ticket_dipendente?(fase, blocker) }

      expect(servite).to eq(%w[triage planner autopilot closer_staging])
    end

    it "portando il prerequisito a Fatto parte anche il rilascio in produzione" do
      prerequisito_unito!(blocker)
      blocker.update!(status: create(:ticket_status, :done, organization:))

      expect(FASI_DELLA_CODA.select { |fase| serve_ticket_dipendente?(fase, blocker) }).to eq(FASI_DELLA_CODA)
    end

    # La differenza che tiene in piedi tutto: il fatto lo scrive il verificatore dopo aver VISTO la
    # proposta unita. La sola parola dell'agente è quella che si sta smettendo di credere, e
    # accettarla qui rimetterebbe in piedi il guasto da un'altra porta.
    it "con la sola dichiarazione dell'agente non parte nessuna delle cinque" do
      prerequisito_dichiarato!(blocker)

      expect(FASI_DELLA_CODA.select { |fase| serve_ticket_dipendente?(fase, blocker) }).to be_empty
    end
  end

  # La coincidenza si deve vedere FINO IN FONDO, non solo a tavolino: un ticket che la coda serve per
  # la scrittura del codice deve poi riuscire a muoversi. Finché il movimento poneva la domanda
  # severa, la coda era più permissiva del cancello e il giro di macchina era ancora buttato — che è
  # il guasto, spostato di un passo.
  it "un ticket servito per la scrittura del codice riesce poi ad arrivare davanti a una persona" do
    in_review = create(:ticket_status, :in_review, organization:)
    blocker = create(:ticket, organization:, project:, with_agent_workflow: true)
    prerequisito_unito!(blocker)
    ticket = ticket_pronto("autopilot")
    create(:ticket_dependency, ticket:, blocker:)

    expect(coda_next.value).to eq(ticket)

    # La macchina lavora e consegna; il sistema apre la proposta, legge i controlli e mette la scheda
    # davanti a una persona. È lì che il ticket si muove.
    workflow = ticket.agent_workflow
    workflow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                     candidate_verified_at: 1.minute.ago)

    expect(Agents::Workflows::StatusProjection.call(workflow:)).to be_ok
    expect(ticket.reload.status).to eq(in_review)
  end

  # ── La finestra dei cinque minuti ────────────────────────────────────────────────────────────────
  #
  # Esiste solo sul percorso in due passi: la presa in carico in un colpo solo firma e consuma la
  # selezione dentro la stessa transazione. Lì in mezzo un prerequisito può smettere di essere
  # soddisfatto, e senza un ricontrollo la macchina comincerebbe un lavoro già condannato.
  describe "fra la firma della selezione e la presa in carico" do
    let(:aperto) { create(:ticket_status, organization:) }
    let(:fatto) { create(:ticket_status, :done, organization:) }
    let(:blocker) { create(:ticket, organization:, project:, status: fatto, with_agent_workflow: true) }
    let(:ticket) { ticket_pronto("autopilot") }
    let(:token) { Agents::TicketQueues::Selection.issue(ticket:, host:) }

    def prendi_in_carico(con_token)
      Agents::TicketQueues::Claim.new(organization:, host:, selection_token: con_token,
                                      params: { host_id: host.id, run_id: "run-1", ttl_seconds: 3600 }).call
    end

    before { create(:ticket_dependency, ticket:, blocker:) }

    it "se il prerequisito smette di essere soddisfatto la presa in carico è rifiutata e non lascia niente" do
      firmato = token
      blocker.update!(status: aperto)
      # CYRA-682 — il montaggio della fase porta con sé il tentativo che ha prodotto il piano (un piano
      # non esiste senza, in produzione come qui). Ciò che si prova è che la presa in carico rifiutata
      # non ne lasci uno NUOVO: contare gli attempt in assoluto misurerebbe il montaggio, non il gesto.
      prima = Agents::Attempt.count

      esito = prendi_in_carico(firmato)

      expect(esito.error.code).to eq("R409-QUEUE-001")
      expect(Agents::Lease).not_to exist
      expect(Agents::Attempt.count).to eq(prima)
      expect(Agents::LimitReservation).not_to exist
    end

    # Che il rifiuto venga dal ricontrollo dei prerequisiti — e non da un'impronta del candidato
    # cambiata — si dimostra ripresentando lo STESSO token, senza rifirmarlo: se il prerequisito
    # torna a posto, quel token funziona.
    it "lo stesso token, senza rifirmarlo, funziona appena il prerequisito torna a posto" do
      firmato = token
      blocker.update!(status: aperto)
      expect(prendi_in_carico(firmato)).to be_err

      blocker.update!(status: fatto)

      expect(prendi_in_carico(firmato)).to be_ok
    end
  end

  # Il filtro sta dentro l'unica interrogazione che sceglie e blocca la testa della coda: il costo di
  # una richiesta di lavoro non può crescere col numero di ticket bloccati, o si sarebbe scambiato un
  # giro di macchina sprecato con una coda lenta.
  it "il costo di una richiesta di lavoro non cresce coi ticket bloccati" do
    pulito = ticket_pronto("autopilot")
    # Un giro a vuoto prima di misurare: la PRIMA chiamata paga anche le letture che si scaldano una
    # volta sola, e confrontarla con una successiva direbbe qualcosa su quelle, non sul filtro.
    coda_next
    con_uno_solo = captured_sql { Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:) }.size

    20.times do
      bloccato = ticket_pronto("autopilot", numero_priorita: 20)
      3.times { create(:ticket_dependency, ticket: bloccato, blocker: create(:ticket, organization:, project:, with_agent_workflow: true)) }
    end
    con_venti = captured_sql { Agents::TicketQueues::Next.call(organization:, project_key: project.key, host:) }

    expect(coda_next.value).to eq(pulito)
    expect(con_venti.size).to eq(con_uno_solo)
  end

  def prepara_prerequisito(ticket, stato)
    return if stato == :nessuno

    progetto = stato == :altrove ? create(:project, organization:, key: "ALT") : project
    blocker = create(:ticket, organization:, project: progetto, with_agent_workflow: true)
    create(:ticket_dependency, ticket:, blocker:)
    prerequisito_unito!(blocker) if stato == :unito
    blocker.update!(status: create(:ticket_status, :done, organization:)) if stato == :fatto
    blocker
  end

  # Lo STESSO apparecchio per tutte e cinque le fasi: un ticket che dipende da `blocker`, montato
  # sulla fase in prova. Cambia la fase, non altro.
  def serve_ticket_dipendente?(fase, blocker)
    dipendente = ticket_pronto(fase)
    create(:ticket_dependency, ticket: dipendente, blocker:)
    servito = coda_next.value == dipendente
    dipendente.update!(agent_eligibility: :blocked)
    servito
  end
end
