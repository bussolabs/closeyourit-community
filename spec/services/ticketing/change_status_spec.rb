# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ChangeStatus do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true) }

  it "cambia lo status (Result.ok)" do
    other = create(:ticket_status, organization: org)
    result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: other.id)
    expect(result).to be_ok
    expect(ticket.reload.status).to eq(other)
  end

  it "status inesistente → Result.err R422-TICKET-003" do
    result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: SecureRandom.uuid)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-003")
  end

  it "status di un'altra org → err (anti-BOLA)" do
    foreign = create(:ticket_status, organization: create(:organization))
    result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: foreign.id)
    expect(result).to be_err
  end

  describe "cronologia" do
    let(:actor) { ticket.reporter }

    it "registra un evento status_changed con attore e label prima→dopo" do
      ticket.update!(status: status)
      target = create(:ticket_status, organization: org, label: "In corso")

      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: target.id, actor: actor)
      end.to change(Ticketing::Event, :count).by(1)

      event = Ticketing::Event.last
      expect(event.action).to eq("status_changed")
      expect(event.actor).to eq(actor)
      expect(event.data).to eq("status" => { "from" => status.label, "to" => "In corso" })
    end

    it "registra true_actor in impersonation" do
      god = create(:account)
      target = create(:ticket_status, organization: org)
      described_class.call(channel: :web, organization: org, ticket: ticket, status_id: target.id, actor: actor, true_actor: god)
      expect(Ticketing::Event.last.true_actor).to eq(god)
    end

    it "no-op (stesso status) → nessun evento" do
      ticket.update!(status: status)
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: status.id, actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end

    it "rollback atomico: se l'evento fallisce, lo status non cambia" do
      target = create(:ticket_status, organization: org)
      allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
      original = ticket.status_id
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: target.id, actor: actor)
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(ticket.reload.status_id).to eq(original)
    end
  end

  describe "gate dipendenze (CYRA-81)" do
    let(:in_progress) { create(:ticket_status, :in_progress, organization: org) }
    let(:done) { create(:ticket_status, :done, organization: org) }
    # A (ticket) dipende da B (blocker), inizialmente open → A è bloccato.
    let(:blocker) { create(:ticket, organization: org, project: project, status: status) }

    before { create(:ticket_dependency, ticket: ticket, blocker: blocker) }

    it "scenario 1 — verso in_progress con blocker aperto: err R422-TICKET-014, nessun update né evento" do
      result = nil
      expect do
        result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: in_progress.id)
      end.to not_change { ticket.reload.status_id }.and not_change(Ticketing::Event, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
    end

    it "scenario 2 — verso done (drag diretto open→done) con blocker aperto: err, A invariato" do
      result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: done.id)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
      expect(ticket.reload.status).to eq(status)
    end

    it "blocco → nessun NotifyJob accodato" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: in_progress.id)
      end.not_to have_enqueued_job(Ticketing::NotifyJob)
    end

    it "blocco → nessun broadcast sul board" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: in_progress.id)
      end.not_to have_broadcasted_to(Realtime::Streams.project_board(ticket.project))
    end

    it "scenario 3 — prerequisito done: la transizione verso in_progress riesce (evento status_changed)" do
      blocker.update!(status: done)
      result = nil
      expect do
        result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: in_progress.id)
      end.to change(Ticketing::Event, :count).by(1)

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(Ticketing::Event.last.action).to eq("status_changed")
    end

    it "scenario 4 — movimento tra due status open è sempre permesso, anche se bloccato" do
      other_open = create(:ticket_status, organization: org)
      result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: other_open.id)

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(other_open)
    end

    it "scenario 7 — A già done resta done (dipendenza aggiunta non retroattiva); la prossima uscita è gated" do
      ticket.update!(status: done)
      # Aggiungo un prerequisito aperto a un ticket già done.
      new_blocker = create(:ticket, organization: org, project: project, status: status)
      create(:ticket_dependency, ticket: ticket, blocker: new_blocker)

      # No-op done→done: nessun gate, A resta done.
      expect(described_class.call(channel: :web, organization: org, ticket: ticket, status_id: done.id)).to be_ok
      expect(ticket.reload.status).to eq(done)

      # Alla prossima transizione fuori da done il gate scatta.
      result = described_class.call(channel: :web, organization: org, ticket: ticket, status_id: in_progress.id)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
      expect(ticket.reload.status).to eq(done)
    end
  end

  # CYRA-675 — «post-commit» valeva finché questo service era il più esterno. Chiamato dentro la
  # transazione di un altro, la sua transazione interna non committa niente: il job partiva su un
  # evento non ancora visibile, `NotifyJob` usciva in silenzio sul `find_by` a vuoto, e la notifica
  # non arrivava a nessuno senza un errore da nessuna parte.
  describe "chiamato dentro la transazione di un altro service" do
    let(:done) { create(:ticket_status, :done, organization: org) }

    it "accoda la notifica solo dopo il commit vero" do
      accodamenti = []
      allow(Ticketing::NotifyJob).to receive(:perform_later) { accodamenti << :accodata }

      ApplicationRecord.transaction do
        described_class.call(organization: org, ticket:, status_id: done.id, channel: :workflow)
        expect(accodamenti).to be_empty, "la notifica è partita prima del commit"
      end

      expect(accodamenti).to contain_exactly(:accodata)
    end
  end

  describe "broadcast realtime (post-commit)" do
    let(:board_stream) { Realtime::Streams.project_board(ticket.project) }
    let(:ticket_stream) { Realtime::Streams.ticket(ticket) }
    let(:target) { create(:ticket_status, organization: org, label: "In corso") }
    # dom_id(Ticketing::Ticket) → "ticketing_ticket_<id>" (contratto target con la ticket-show).
    let(:card_id) { "ticketing_ticket_#{ticket.id}" }

    before { ticket.update!(status: status) }

    it "manda un solo refresh sulla board del progetto, senza HTML della card né conteggi" do
      seen = []
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: target.id)
      end.to have_broadcasted_to(board_stream).exactly(:once).with { |html| seen << html }

      expect(seen.first).to include(%(action="refresh"))
      # Il contenuto lo ri-rende la GET di ogni viewer, scopata sui SUOI progetti (CYRA-257):
      # nel broadcast non deve viaggiare nulla di renderizzato.
      expect(seen.first).not_to include(card_id, ticket.title, %(target="board_count_))
    end

    it "aggiorna il badge stato nello stream del ticket (ticket-show)" do
      # Lo stream del ticket riceve PIÙ messaggi sul cambio stato: il badge (questo service) +
      # l'evento di timeline (Ticketing::RecordActivity, post-commit). Catturo tutti e cerco il badge.
      seen = []
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: target.id)
      end.to have_broadcasted_to(ticket_stream).at_least(:once).with { |html| seen << html }

      expect(seen).to include(
        a_string_including(%(target="#{card_id}_status")).and(a_string_including("In corso"))
      )
    end

    # CYRA-819 — sul telefono lo stato si legge dal riepilogo compatto in testa alla pagina, non dal
    # pannello Dettagli: se l'aggiornamento realtime arrivasse solo al badge del pannello, il
    # riepilogo — l'unica cosa che si vede senza scorrere — resterebbe fermo sullo stato vecchio
    # senza che nulla lo segnali. Bersaglio distinto perché l'id non si può ripetere: con due
    # elementi dello stesso id Turbo ne aggiorna uno solo.
    it "aggiorna anche il riepilogo compatto dell'intestazione" do
      seen = []
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: target.id)
      end.to have_broadcasted_to(ticket_stream).at_least(:once).with { |html| seen << html }

      expect(seen).to include(
        a_string_including(%(target="#{card_id}_mobile_summary")).and(a_string_including("In corso"))
      )
    end

    it "isolamento: stream prefissati org:<id>: e board scopata al progetto del ticket" do
      expect(board_stream).to start_with("org:#{org.id}:")
      expect(ticket_stream).to start_with("org:#{org.id}:")
      # Per-progetto, non org-wide: chi il progetto non lo vede non è iscritto (CYRA-257).
      expect(board_stream).to end_with(":board:project:#{ticket.project_id}")
    end

    it "no-op (stesso status) → nessun broadcast sul board" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: ticket.status_id)
      end.not_to have_broadcasted_to(board_stream)
    end

    it "status inesistente → nessun broadcast sul board" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, status_id: SecureRandom.uuid)
      end.not_to have_broadcasted_to(board_stream)
    end
  end
  # ── CYRA-609 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Tre mani sulla stessa leva, e nessuna sapeva cosa facevano le altre: tu dalla pagina, la macchina
  # dal terminale, GitHub unendo il codice. Bastava che una segnasse «da revisionare» a lavoro ancora
  # in corso, o «fatto» prima che il rilascio partisse, perché quella parola smettesse di dire a che
  # punto è il lavoro — e nessuno veniva avvisato.
  describe "la leva ha un padrone solo mentre la lavorazione è in corso" do
    let(:altro) { create(:ticket_status, organization: org) }
    let(:persona) { create(:account).tap { |a| create(:membership, account: a, organization: org) } }

    def in_corso!
      ticket.agent_workflow.update!(triage_started_at: Time.current)
    end

    def presa_in_carico_da(account)
      create(:agent_lease, :held_by_account, organization: org, ticket:, account:,
                           expires_at: 1.hour.from_now)
    end

    it "dal terminale non si sposta" do
      in_corso!

      result = described_class.call(channel: :cli, organization: org, ticket:, status_id: altro.id,
                                    actor: persona)

      expect(result.error.code).to eq("R409-TICKET-020")
      expect(ticket.reload.status).to eq(status)
    end

    it "unendo il codice non si sposta" do
      in_corso!

      result = described_class.call(channel: :webhook, organization: org, ticket:, status_id: altro.id)

      expect(result.error.code).to eq("R409-TICKET-020")
      expect(ticket.reload.status).to eq(status)
    end

    # Rifiuto = rollback: non deve restare NIENTE. Un evento in cronologia direbbe che lo spostamento
    # c'è stato, e chi legge la scheda vedrebbe una mossa che non è mai avvenuta.
    it "il rifiuto non lascia né evento né notifica" do
      in_corso!

      expect do
        described_class.call(channel: :cli, organization: org, ticket:, status_id: altro.id)
      end.to not_change { Ticketing::Event.where(ticket:, action: "status_changed").count }

      # Il blocco, non la coda globale: `have_been_enqueued` guarda tutto ciò che è stato accodato
      # nella run, compresi gli altri esempi, e direbbe rosso per lavoro di qualcun altro.
      expect do
        described_class.call(channel: :cli, organization: org, ticket:, status_id: altro.id)
      end.not_to have_enqueued_job(Ticketing::NotifyJob)
    end

    # Dalla pagina lo sposti tu, a mano, a una condizione: aver preso in carico il ticket. È un clic, e
    # serve a rendere la mossa TUA — visibile a tutti — invece di un ripensamento anonimo.
    it "dalla pagina lo sposta chi ha preso in carico il ticket" do
      in_corso!
      presa_in_carico_da(persona)

      result = described_class.call(channel: :web, organization: org, ticket:, status_id: altro.id,
                                    actor: persona)

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(altro)
    end

    it "dalla pagina NON lo sposta chi non l'ha preso in carico" do
      in_corso!

      result = described_class.call(channel: :web, organization: org, ticket:, status_id: altro.id,
                                    actor: persona)

      expect(result.error.code).to eq("R409-TICKET-020")
    end

    # `Lease#human?` è vero anche per un account di servizio, cioè per la macchina che passa dal
    # terminale: accettarlo qui rimetterebbe la macchina sulla leva dalla porta del web.
    it "un account di servizio che ha la presa in carico non conta come persona" do
      in_corso!
      # Il titolare account dev'essere membro dell'organizzazione del lease, service account compreso.
      servizio = create(:account, :service).tap { |a| create(:membership, account: a, organization: org) }
      presa_in_carico_da(servizio)

      result = described_class.call(channel: :web, organization: org, ticket:, status_id: altro.id,
                                    actor: servizio)

      expect(result.error.code).to eq("R409-TICKET-020")
    end

    # CYRA-614 — il quarto canale non è una scappatoia: lo usa il sistema dopo aver aperto la proposta
    # e letto i controlli. È un fatto osservato, non una dichiarazione — ed è la cosa che le porte
    # chiuse proteggevano.
    it "il canale del sistema sposta, perché ha guardato" do
      in_corso!

      result = described_class.call(channel: :workflow, organization: org, ticket:, status_id: altro.id)

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(altro)
    end

    # Un canale che non conosciamo vale come il più stretto: una porta nuova non eredita in silenzio i
    # permessi della più permissiva.
    it "un canale sconosciuto vale come il terminale" do
      in_corso!
      presa_in_carico_da(persona)

      result = described_class.call(channel: :qualcosa, organization: org, ticket:, status_id: altro.id,
                                    actor: persona)

      expect(result.error.code).to eq("R409-TICKET-020")
    end

    # Sui ticket che nessuna macchina ha mai preso in mano non cambia niente: si spostano come sempre,
    # da ogni parte. Il blocco riguarda solo i lavori davvero in corso.
    it "su una lavorazione mai avviata si sposta da ogni canale" do
      %i[web cli webhook].each_with_index do |canale, indice|
        bersaglio = create(:ticket_status, organization: org)
        expect(described_class.call(channel: canale, organization: org, ticket:, status_id: bersaglio.id))
          .to be_ok, "canale #{canale} (giro #{indice})"
      end
    end

    # Una lavorazione conclusa o annullata non è «in corso»: la leva torna libera.
    it "su una lavorazione conclusa o annullata si sposta di nuovo" do
      [ { completed_at: Time.current }, { cancelled_at: Time.current } ].each do |fine|
        ticket.agent_workflow.update!(triage_started_at: Time.current, completed_at: nil, cancelled_at: nil, **fine)
        bersaglio = create(:ticket_status, organization: org)

        expect(described_class.call(channel: :cli, organization: org, ticket:, status_id: bersaglio.id))
          .to be_ok, fine.keys.first.to_s
      end
    end
  end
end
