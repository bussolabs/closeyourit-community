# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::ApproveAutopilot do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:in_review) { create(:ticket_status, :in_review, organization:, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:actor) { create(:account) }

  # CYRA-612 — la fase «aspetta la tua approvazione» esiste solo dopo che il sistema ha aperto la
  # proposta e letto i controlli su quel codice: senza, non c'è niente da approvare.
  before do
    workflow.update!(autopilot_started_at: 2.minutes.ago, autopilot_completed_at: 1.minute.ago,
                     candidate_verified_at: 1.minute.ago)
  end

  it "timbra l'approvazione e sposta il ticket su in_progress non-gate (phase closer_staging_queued)" do
    result = described_class.call(workflow:, actor:)

    expect(result).to be_ok
    expect(result.value).to eq(workflow)
    expect(ticket.reload.status).to eq(in_progress)
    expect(workflow.reload).to have_attributes(
      autopilot_approved_by: actor, autopilot_approved_at: be_present, phase: "closer_staging_queued"
    )
  end

  # ── CYRA-622 ────────────────────────────────────────────────────────────────────────────────────
  #
  # L'approvazione decideva da sola in quale colonna finisce il ticket, con una regola sua: «il primo
  # stato di lavoro per posizione». Finché di stati di lavoro ce n'era uno solo funzionava per caso.
  # Con le parole nuove ce ne sono due — «In lavorazione» e «In chiusura» — e quella regola rimandava
  # il ticket appena approvato su «In lavorazione»: la stessa parola che aveva PRIMA del sì. Chi
  # guardava la bacheca vedeva lavoro ancora da fare mentre il ticket stava già andando al rilascio.
  describe "la parola dopo il sì (CYRA-622)" do
    let!(:in_chiusura) { create(:ticket_status, :in_progress, organization:, position: 5, label: "In chiusura") }

    it "il ticket approvato compare nella colonna della chiusura, non in quella del lavoro da fare" do
      described_class.call(workflow:, actor:)

      expect(ticket.reload.status).to eq(in_chiusura)
      expect(ticket.status).not_to eq(in_progress)
    end

    # Il cuore del ticket: la corrispondenza vive in UN posto solo, e l'approvazione la consuma. Se
    # invece se la portasse dietro, spostarla non cambierebbe niente e resterebbero due posti che
    # decidono la stessa parola — che è esattamente la cosa che si sta togliendo.
    it "spostando la corrispondenza su un terzo stato, l'approvazione la segue senza toccarla" do
      terzo = create(:ticket_status, :in_progress, organization:, position: 3, label: "In uscita")
      spostata = Agents::Workflows::StatusProjection::DESTINATIONS.merge(
        "closer_staging_queued" => Agents::Workflows::StatusProjection::Destination.new(
          category: :in_progress, execution_phase: "closer_staging",
          picker: ->(statuses) { statuses.find_by(label: "In uscita") }
        )
      )
      stub_const("Agents::Workflows::StatusProjection::DESTINATIONS", spostata)

      described_class.call(workflow:, actor:)

      expect(ticket.reload.status).to eq(terzo)
    end
  end

  it "si blocca se il workflow non è più in awaiting_autopilot_approval, senza mutare il ticket" do
    workflow.update!(autopilot_approved_at: Time.current)

    result = described_class.call(workflow:, actor:)

    expect(result.error.code).to eq("R409-WORKFLOW-003")
    expect(ticket.reload.status).to eq(in_review)
  end

  # La destinazione manca: il rifiuto resta quello di sempre, e resta senza scritture. Ora la data
  # dell'approvazione viene scritta PRIMA che la destinazione si risolva, quindi «senza mutare» non è
  # più gratis: se il rollback non ci fosse, resterebbe una lavorazione approvata su un ticket fermo.
  it "fallisce senza un in_progress non-gate di destinazione, senza mutare" do
    in_progress.update!(review_gate: true)

    result = described_class.call(workflow:, actor:)

    expect(result.error.code).to eq("R422-TICKET-008")
    expect(ticket.reload.status).to eq(in_review)
    expect(workflow.reload).to have_attributes(autopilot_approved_at: nil, autopilot_approved_by: nil,
                                               phase: "awaiting_autopilot_approval")
  end

  describe "gate dipendenze (CYRA-81)" do
    let(:open_status) { create(:ticket_status, organization:) }
    let(:blocker) { create(:ticket, organization:, project:, status: open_status, with_agent_workflow: true) }

    before { create(:ticket_dependency, ticket:, blocker:) }

    it "blocker aperto → err R422-TICKET-014 sul target in_progress (gated), niente mutazioni" do
      result = described_class.call(workflow:, actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
      expect(ticket.reload.status).to eq(in_review)
      expect(workflow.reload.autopilot_approved_at).to be_nil
    end

    it "prerequisito done → avanza a in_progress non-gate" do
      blocker.update!(status: create(:ticket_status, :done, organization:))

      result = described_class.call(workflow:, actor:)

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
    end

    # ── CYRA-622 ──────────────────────────────────────────────────────────────────────────────────
    #
    # «Va dopo» voleva dire «aspetta che l'altro sia vivo in produzione». Due ticket messi in fila e
    # destinati allo stesso rilascio si bloccavano a vicenda: il secondo non si poteva approvare
    # finché il primo non era uscito, e il primo usciva solo col rilascio. Mettere due ticket in
    # ordine costava al secondo un giro di rilascio intero, ogni volta.
    describe "«va dopo» chiede il codice unito, non il rilascio (CYRA-622)" do
      it "prerequisito unito e provato ma non ancora Fatto → l'approvazione riesce" do
        blocker.agent_workflow.update!(closer_staging_completed_at: 10.minutes.ago,
                                       closer_staging_verified_at: 5.minutes.ago)

        result = described_class.call(workflow:, actor:)

        expect(result).to be_ok
        expect(blocker.reload.status).to eq(open_status)
        expect(workflow.reload).to have_attributes(autopilot_approved_at: be_present,
                                                   phase: "closer_staging_queued")
        expect(ticket.reload.status).to eq(in_progress)
      end

      # La differenza che tiene in piedi tutto: il fatto lo scrive il verificatore dopo aver VISTO la
      # proposta unita. La dichiarazione della macchina è la parola che stiamo smettendo di credere,
      # e accettarla qui rimetterebbe in piedi il difetto da un'altra porta.
      it "staging chiuso dalla sola dichiarazione della macchina → resta rifiutato" do
        blocker.agent_workflow.update!(closer_staging_completed_at: 10.minutes.ago,
                                       closer_staging_verified_at: nil)

        result = described_class.call(workflow:, actor:)

        expect(result.error.code).to eq("R422-TICKET-014")
        expect(workflow.reload.autopilot_approved_at).to be_nil
      end

      # Scenario 2: l'ordine scritto viene rispettato davvero, e si sa quale ticket sta trattenendo.
      it "prerequisito col codice non ancora unito → rifiuto che nomina il ticket che trattiene" do
        result = described_class.call(workflow:, actor:)

        expect(result.error.code).to eq("R422-TICKET-014")
        expect(result.error.details[:dependencies].map { |d| d[:id] }).to include(blocker.id)
        expect(ticket.reload.status).to eq(in_review)
      end

      # Il cancello non deve poter essere spento da una configurazione mancante: la categoria da
      # proteggere si legge dalla FASE, non da una riga di stato che potrebbe non esistere. Prima si
      # risolveva la riga per prima, e senza destinazione il cancello non girava affatto.
      it "senza destinazione configurata risponde del prerequisito, non della destinazione" do
        in_progress.update!(review_gate: true)

        result = described_class.call(workflow:, actor:)

        expect(result.error.code).to eq("R422-TICKET-014")
        expect(workflow.reload).to have_attributes(autopilot_approved_at: nil,
                                                   phase: "awaiting_autopilot_approval")
        expect(ticket.reload.status).to eq(in_review)
      end
    end
  end
  # ── CYRA-617 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Fra il controllo e il clic chiunque poteva metterci dentro altro codice — una persona o una
  # sessione ripresa — e nel momento dell'approvazione nessuno ricontrollava niente: andava avanti
  # codice che nessuno aveva mai guardato, con tutte le spie verdi.
  describe "il codice al momento del sì" do
    let(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
    let(:candidato) do
      create(:agent_delivery_candidate, :verified_passing, workflow:, organization:,
                                        repository:, repository_full_name: "bussolabs/closeyourit-rails",
                                        number: 7, head_sha: "a" * 40)
    end

    before { workflow.update!(review_candidate: candidato) }

    def client_con(head_sha)
      instance_double(Github::Client).tap do |c|
        allow(c).to receive(:pull_request_state).and_return(head_sha: head_sha, base_ref: "main")
      end
    end

    def client_che_solleva(errore)
      instance_double(Github::Client).tap { |c| allow(c).to receive(:pull_request_state).and_raise(errore) }
    end

    it "rilegge la proposta col numero dell'installazione GitHub (CYRA-762)" do
      client = client_con("a" * 40)

      described_class.call(workflow:, actor:, client:)

      expect(client).to have_received(:pull_request_state)
        .with(repository.installation.installation_id, "bussolabs/closeyourit-rails", 7)
    end

    it "uguale: l'approvazione passa, come sempre" do
      result = described_class.call(workflow:, actor:, client: client_con("a" * 40))

      expect(result).to be_ok
      expect(workflow.reload.autopilot_approved_at).to be_present
    end

    it "diverso: non passa, e in produzione non va niente" do
      result = described_class.call(workflow:, actor:, client: client_con("b" * 40))

      expect(result.error.code).to eq("R409-WORKFLOW-005")
      expect(workflow.reload.autopilot_approved_at).to be_nil
    end

    # La lavorazione esce dalla pila delle decisioni e torna fra i lavori in corso: il sistema
    # ricontrolla da solo il codice nuovo e poi torna da chi deve approvare.
    it "diverso: la lavorazione torna fra i lavori in corso, con una riga nuova da controllare" do
      described_class.call(workflow:, actor:, client: client_con("b" * 40))

      expect(workflow.reload).to have_attributes(candidate_verified_at: nil, review_candidate_id: nil)
      expect(workflow.phase).to eq("verifying_candidate")
      nuova = Agents::DeliveryCandidate.where(workflow:, head_sha: nil).sole
      expect(nuova).to be_state_pending
      expect(nuova).to have_attributes(number: 7, repository_full_name: "bussolabs/closeyourit-rails",
                                       next_check_at: be_present)
    end

    # Il messaggio dice cosa avevi guardato e cosa c'è adesso: senza, «è cambiato» non si può
    # verificare da nessuna parte.
    it "diverso: il messaggio nomina le due versioni" do
      result = described_class.call(workflow:, actor:, client: client_con("b" * 40))

      expect(result.error.message).to include(("a" * 40).first(12), ("b" * 40).first(12))
    end

    # «Non ho potuto guardare» e «il codice è cambiato» sono due cose diverse e restano due messaggi
    # diversi: qui non si azzera niente e la lavorazione non risulta ferma.
    it "il servizio non risponde: non passa, e non si butta via niente" do
      errore = Github::Client::Error.new("timeout", code: "R502-GITHUB-001")

      result = described_class.call(workflow:, actor:, client: client_che_solleva(errore))

      expect(result.error.code).to eq("R409-WORKFLOW-006")
      expect(workflow.reload).to have_attributes(candidate_verified_at: be_present,
                                                 review_candidate_id: candidato.id,
                                                 blocked_at: nil, autopilot_approved_at: nil)
      expect(Agents::DeliveryCandidate.where(workflow:).count).to eq(1)
    end

    # Qui non c'è niente da ricontrollare, e infatti non si rimette nessuna riga da guardare.
    it "la proposta non esiste più: non passa, e non si riprova da soli" do
      errore = Github::Client::Error.new("assente", code: "R404-GITHUB-010", status: :not_found)

      result = described_class.call(workflow:, actor:, client: client_che_solleva(errore))

      expect(result.error.code).to eq("R409-WORKFLOW-007")
      expect(Agents::DeliveryCandidate.where(workflow:).count).to eq(1)
      expect(workflow.reload.review_candidate_id).to eq(candidato.id)
    end

    # Il verbale può essere stato sostituito da un altro giro di verifica fra la lettura e il lock:
    # allora il confronto appena fatto riguarda una cosa che non è più quella su cui si decide.
    it "se il verbale cambia sotto, non si approva su un confronto vecchio" do
      client = instance_double(Github::Client)
      allow(client).to receive(:pull_request_state) do
        # Un altro giro di verifica sostituisce il verbale mentre questa lettura è in volo: azzera e
        # riaggancia, come fa davvero chi va a guardare.
        workflow.update!(review_candidate: nil)
        workflow.update!(review_candidate: create(:agent_delivery_candidate, :verified_passing, workflow:,
                                                                            organization:))
        { head_sha: "a" * 40, base_ref: "main" }
      end

      result = described_class.call(workflow:, actor:, client:)

      expect(result.error.code).to eq("R409-WORKFLOW-003")
      expect(workflow.reload.autopilot_approved_at).to be_nil
    end

    # Una lavorazione senza verbale non è passata da questa strada: pretendere un confronto che non si
    # può fare fermerebbe lavoro sano.
    it "senza verbale non si pretende nessun confronto" do
      workflow.update!(review_candidate: nil)
      client = instance_double(Github::Client)
      allow(client).to receive(:pull_request_state).and_raise("non doveva chiamare GitHub")

      expect(described_class.call(workflow:, actor:, client:)).to be_ok
    end
  end
end
