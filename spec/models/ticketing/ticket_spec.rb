require "rails_helper"

RSpec.describe Ticketing::Ticket, type: :model do
  describe "factory" do
    it "produce un ticket valido" do
      expect(build(:ticket)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede title" do
      expect(build(:ticket, title: nil)).not_to be_valid
    end

    it "rifiuta title di soli spazi" do
      expect(build(:ticket, title: "   ")).not_to be_valid
    end

    it "richiede project" do
      expect(build(:ticket, project: nil)).not_to be_valid
    end

    it "richiede reporter" do
      expect(build(:ticket, reporter: nil)).not_to be_valid
    end

    it "richiede status" do
      expect(build(:ticket, status: nil)).not_to be_valid
    end

    it "richiede priority" do
      expect(build(:ticket, priority: nil)).not_to be_valid
    end

    it "ha assignee opzionale" do
      expect(build(:ticket, assignee: nil)).to be_valid
    end

    it "ha reviewer opzionale" do
      expect(build(:ticket, reviewer: nil)).to be_valid
    end
  end

  describe "corpo minimo (description OPPURE almeno uno scenario con contenuto)" do
    it "un ticket con la sola description (nessuno scenario) è valido, per ogni kind" do
      expect(build(:ticket, :plain_bug)).to be_valid
      expect(build(:ticket, :story)).to be_valid
      expect(build(:ticket, :task)).to be_valid
    end

    it "un ticket con almeno uno scenario (senza description) è valido" do
      expect(build(:ticket)).to be_valid # il factory aggiunge uno scenario di default
    end

    it "un ticket senza description né scenari è invalido (body_required su :description)" do
      empty = build(:ticket, with_default_body: false, description: nil)
      expect(empty).not_to be_valid
      expect(empty.errors[:description]).to be_present
    end

    it "spazi soli nella description non contano come corpo" do
      blank = build(:ticket, with_default_body: false, description: "   ")
      expect(blank).not_to be_valid
      expect(blank.errors[:description]).to be_present
    end

    it "uno scenario di soli step blank non conta come corpo" do
      ticket = build(:ticket, with_default_body: false, description: nil)
      ticket.scenarios.build(step_given: "  ", step_when: "  ", step_then: "  ", step_expected: "  ")
      expect(ticket).not_to be_valid
      expect(ticket.errors[:description]).to be_present
    end

    it "una story con uno scenario (senza description) è valida — il corpo vale per tutti i kind" do
      feature = build(:ticket, :story, description: nil, with_default_body: false)
      feature.scenarios.build(step_given: "utente sulla dashboard", step_when: "clicca esporta")
      expect(feature).to be_kind_story
      expect(feature).to be_valid
    end

    it "normalizza (strip) description" do
      feature = create(:ticket, :story, description: "  serve dark mode  ")
      expect(feature.description).to eq("serve dark mode")
    end
  end

  describe "ortografia italiana del corpo" do
    it "mette gli accenti mancanti nella descrizione" do
      ticket = create(:ticket, description: "nasce gia in stato saltata, che e' definitivo")

      expect(ticket.description).to eq("nasce già in stato saltata, che è definitivo")
    end

    it "mette gli accenti mancanti nell'analisi tecnica" do
      ticket = create(:ticket, technical_analysis: "la ereditarieta non e' rispettata")

      expect(ticket.technical_analysis).to eq("la ereditarietà non è rispettata")
    end

    it "mette gli accenti mancanti nella motivazione di eleggibilità agenti" do
      ticket = create(:ticket)
      ticket.update!(agent_eligibility_reason: "Rilievo di audit UX con proposta gia definita")

      expect(ticket.agent_eligibility_reason).to eq("Rilievo di audit UX con proposta già definita")
    end

    it "non tocca il codice nell'analisi tecnica" do
      ticket = create(:ticket, technical_analysis: "il campo `gia_visto` e' nullo")

      expect(ticket.technical_analysis).to eq("il campo `gia_visto` è nullo")
    end
  end

  describe "scenari BDD (has_many :scenarios)" do
    it "il default è bug" do
      expect(build(:ticket)).to be_kind_bug
    end

    it "accetta N scenari" do
      ticket = create(:ticket, :with_scenarios, scenarios_count: 3)
      expect(ticket.scenarios.count).to eq(3)
    end

    it "restituisce gli scenari ordinati per position" do
      ticket = create(:ticket, with_default_body: false, description: "corpo")
      third  = ticket.scenarios.create!(position: 2, step_given: "c")
      first  = ticket.scenarios.create!(position: 0, step_given: "a")
      second = ticket.scenarios.create!(position: 1, step_given: "b")
      expect(ticket.scenarios.reload.to_a).to eq([ first, second, third ])
    end

    it "cascade destroy: elimina gli scenari col ticket" do
      ticket = create(:ticket, :with_scenarios, scenarios_count: 2)
      expect { ticket.destroy }.to change(Ticketing::Scenario, :count).by(-2)
    end

    it "via scenarios_attributes scarta le righe senza alcuno step (reject_if)" do
      ticket = build(
        :ticket, with_default_body: false, description: "corpo",
        scenarios_attributes: [
          { step_given: "ok" },
          { title: "solo titolo", step_given: "", step_when: "", step_then: "", step_expected: "" }
        ],
      )
      expect(ticket.scenarios.size).to eq(1)
    end
  end

  describe "condizioni DoD (has_many :conditions)" do
    it "sono sempre opzionali (0 condizioni è valido)" do
      ticket = build(:ticket)
      expect(ticket.conditions).to be_empty
      expect(ticket).to be_valid
    end

    it "accetta N condizioni" do
      ticket = create(:ticket, :with_conditions, conditions_count: 3)
      expect(ticket.conditions.count).to eq(3)
    end

    it "cascade destroy: elimina le condizioni col ticket" do
      ticket = create(:ticket, :with_conditions, conditions_count: 2)
      expect { ticket.destroy }.to change(Ticketing::Condition, :count).by(-2)
    end

    it "via conditions_attributes scarta le righe senza testo (reject_if)" do
      ticket = build(:ticket, conditions_attributes: [ { text: "l'utente riceve la mail" }, { text: "   " } ])
      expect(ticket.conditions.size).to eq(1)
    end
  end

  describe "technical_analysis" do
    it "è opzionale" do
      expect(build(:ticket, technical_analysis: nil)).to be_valid
    end

    it "normalizza (strip)" do
      ticket = create(:ticket, technical_analysis: "  N+1 su Ticket#index  ")
      expect(ticket.technical_analysis).to eq("N+1 su Ticket#index")
    end
  end

  describe "limite di lunghezza" do
    let(:description_max) { Ticketing::Constants::DESCRIPTION_MAX_CHARS }
    let(:analysis_max) { Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS }

    # Ticket già oltre soglia come quelli scritti prima della regola: creato aggirando le validazioni.
    def legacy_long_ticket
      ticket = build(:ticket, description: "x" * (description_max + 2_000))
      ticket.save!(validate: false)
      ticket
    end

    it "accetta descrizione e analisi tecnica esattamente al limite" do
      ticket = build(:ticket, description: "x" * description_max, technical_analysis: "y" * analysis_max)
      expect(ticket).to be_valid
    end

    it "rifiuta la descrizione oltre il limite e dice di quanto ha sforato" do
      ticket = build(:ticket, description: "x" * (description_max + 1))

      expect(ticket).to be_invalid
      expect(ticket.errors.details[:description])
        .to include(hash_including(error: :length_budget_exceeded, count: description_max,
                                   actual: description_max + 1))
    end

    it "rifiuta l'analisi tecnica oltre il limite" do
      ticket = build(:ticket, technical_analysis: "y" * (analysis_max + 1))

      expect(ticket).to be_invalid
      expect(ticket.errors.details[:technical_analysis])
        .to include(hash_including(error: :length_budget_exceeded))
    end

    it "rifiuta un titolo oltre i 255 caratteri, ma non intrappola quelli legacy" do
      expect(build(:ticket, title: "t" * 255)).to be_valid
      expect(build(:ticket, title: "t" * 256)).to be_invalid

      legacy = build(:ticket, title: "t" * 300)
      legacy.save!(validate: false)

      legacy.description = "Descrizione nuova" # titolo intoccato → il ticket resta salvabile
      expect(legacy).to be_valid

      legacy.title = "t" * 301
      expect(legacy).to be_invalid
    end

    it "conta i fine-riga come li conta il browser (CRLF normalizzato a LF)" do
      ticket = build(:ticket, description: "x#{"\r\n" * 100}".ljust(description_max + 100, "y"))

      expect(ticket).to be_valid
      expect(ticket.description.length).to eq(description_max)
      expect(ticket.description).not_to include("\r")
    end

    it "lascia salvare un ticket già troppo lungo se la descrizione si accorcia o non cambia" do
      ticket = legacy_long_ticket

      ticket.description = "x" * (ticket.description.length - 500)
      expect(ticket).to be_valid

      ticket.reload.title = "Titolo nuovo"
      expect(ticket).to be_valid
    end

    it "blocca un ticket già troppo lungo se la descrizione cresce ancora" do
      ticket = legacy_long_ticket
      ticket.description = "#{ticket.description}ancora testo"

      expect(ticket).to be_invalid
      expect(ticket.errors.details[:description]).to include(hash_including(error: :length_budget_exceeded))
    end
  end

  describe "weight (punti opzionali)" do
    it "accetta nil e interi positivi; rifiuta 0/negativi" do
      expect(build(:ticket, weight: nil)).to be_valid
      expect(build(:ticket, weight: 5)).to be_valid
      expect(build(:ticket, weight: 0)).not_to be_valid
      expect(build(:ticket, weight: -1)).not_to be_valid
    end
  end

  describe "numerazione per progetto (codice KEY-number)" do
    let(:org) { create(:organization) }
    let(:status) { create(:ticket_status, organization: org) }
    let(:priority) { create(:ticket_priority, organization: org) }
    let(:project) { create(:project, organization: org, key: "STR") }

    # il factory crea un reporter membro di `org` (passata come organization)
    def new_ticket(proj)
      create(:ticket, organization: org, project: proj, status: status, priority: priority)
    end

    it "assegna number progressivo a partire da 1" do
      expect(new_ticket(project).number).to eq(1)
      expect(new_ticket(project).number).to eq(2)
      expect(new_ticket(project).number).to eq(3)
    end

    it "numera in modo indipendente per progetto" do
      api = create(:project, organization: org, key: "API")
      expect(new_ticket(project).number).to eq(1)
      expect(new_ticket(api).number).to eq(1)
    end

    it "compone il code come KEY-number" do
      expect(new_ticket(project).code).to eq("STR-1")
    end
  end

  describe "integrità tenant (status/priority dell'org del progetto)" do
    it "rifiuta uno status di un'altra organizzazione" do
      org_a = create(:organization)
      project = create(:project, organization: org_a)
      foreign_status = create(:ticket_status, organization: create(:organization))
      ticket = build(:ticket, organization: org_a, project: project, status: foreign_status)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:status]).to be_present
    end

    it "rifiuta una priority di un'altra organizzazione" do
      org_a = create(:organization)
      project = create(:project, organization: org_a)
      foreign_priority = create(:ticket_priority, organization: create(:organization))
      ticket = build(:ticket, organization: org_a, project: project, priority: foreign_priority)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:priority]).to be_present
    end
  end

  describe "isolamento tenant (reporter/assignee/reviewer membri dell'org del progetto)" do
    it "rifiuta un reporter non membro dell'organizzazione del progetto" do
      org = create(:organization)
      outsider = create(:account)
      ticket = build(:ticket, organization: org, reporter: outsider)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:reporter]).to be_present
    end

    it "rifiuta un reviewer non membro dell'organizzazione del progetto" do
      org = create(:organization)
      outsider = create(:account)
      # reviewer default = reporter (membro), qui lo forziamo a un estraneo
      ticket = build(:ticket, organization: org, reviewer: outsider)
      expect(ticket).not_to be_valid
      expect(ticket.errors.details[:reviewer]).to include(error: :not_member)
    end

    it "rifiuta un assignee non membro dell'organizzazione del progetto" do
      org = create(:organization)
      outsider = create(:account)
      ticket = build(:ticket, organization: org, assignee: outsider)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:assignee]).to be_present
    end

    it "accetta un assignee membro dell'organizzazione" do
      org = create(:organization)
      member = create(:account)
      create(:membership, account: member, organization: org)
      ticket = build(:ticket, organization: org, assignee: member)
      expect(ticket).to be_valid
    end
  end

  describe "associazioni" do
    it "lascia al vincolo DB la cascade delle lease senza eseguire callback lease→ticket" do
      ticket = create(:ticket)
      organization = ticket.project.organization
      lease = create(:agent_lease, organization:, ticket:, host: create(:agent_host, organization:))
      allow(lease).to receive(:destroy).and_raise("callback lease non attesa")
      allow(ticket).to receive(:agent_lease).and_return(lease)

      expect { ticket.destroy! }.to change(Agents::Lease, :count).by(-1)
    end


    it "espone tombstone a 0/1/N e le elimina tramite cascade DB col ticket" do
      ticket = create(:ticket)
      organization = ticket.project.organization
      host = create(:agent_host, organization:)
      expect(ticket.agent_lease_tombstones).to be_empty

      lease = create(:agent_lease, organization:, ticket:, host:, run_id: "run-one")
      Agents::Leases::Tombstone.record!(lease:, released_at: Time.current)
      lease.update!(run_id: "run-two")
      Agents::Leases::Tombstone.record!(lease:, released_at: Time.current)

      expect(ticket.agent_lease_tombstones.reload.size).to eq(2)
      expect { ticket.destroy! }.to change(Agents::Leases::Tombstone, :count).by(-2)
    end

    it "project.tickets a 0/1/N con cascade destroy" do
      project = create(:project)
      expect(project.tickets).to be_empty
      ticket = create(:ticket, organization: project.organization, project: project)
      expect(project.tickets).to contain_exactly(ticket)
      expect { project.destroy }.to change(described_class, :count).by(-1)
    end

    it "organization.tickets attraverso i progetti" do
      org = create(:organization)
      project = create(:project, organization: org)
      ticket = create(:ticket, organization: org, project: project)
      expect(org.tickets).to contain_exactly(ticket)
    end

    it "blocca l'eliminazione del reporter che ha aperto ticket" do
      org = create(:organization)
      reporter = create(:account)
      create(:membership, account: reporter, organization: org)
      create(:ticket, organization: org, reporter: reporter)
      expect(reporter.reported_tickets.count).to eq(1)
      expect { reporter.destroy }.not_to change(Accounts::Account, :count)
    end

    it "azzera l'assignee quando l'account assegnatario viene eliminato" do
      org = create(:organization)
      assignee = create(:account)
      create(:membership, account: assignee, organization: org)
      # Reporter esplicito e diverso: chi ha aperto il ticket non si cancella (prova qui sopra), e
      # senza dirlo la factory riuserebbe come autore lo stesso account che qui va eliminato.
      reporter = create(:membership, organization: org).account
      ticket = create(:ticket, organization: org, reporter: reporter, assignee: assignee)
      expect(assignee.assigned_tickets).to contain_exactly(ticket)
      expect { assignee.destroy }.to change { ticket.reload.assignee_id }.to(nil)
    end

    describe "#error_group (backlink CYRA-163, reverse di Errors::Group#ticket_id)" do
      it "nil quando il ticket non nasce da una promozione" do
        expect(create(:ticket).error_group).to be_nil
      end

      it "l'errore promosso a questo ticket, quando esiste" do
        ticket = create(:ticket)
        group = create(:error_group, project: ticket.project, ticket: ticket)
        expect(ticket.reload.error_group).to eq(group)
      end
    end
  end

  describe "robustezza e numero esplicito" do
    it "rispetta un number fornito esplicitamente (non lo rigenera)" do
      org = create(:organization)
      project = create(:project, organization: org)
      ticket = create(:ticket, organization: org, project: project, number: 99)
      expect(ticket.number).to eq(99)
    end

    it "gestisce status mancante senza rompere la validazione tenant" do
      project = create(:project)
      ticket = build(:ticket, organization: project.organization, project: project, status: nil)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:status]).to be_present
    end

    it "gestisce priority mancante senza rompere la validazione tenant" do
      project = create(:project)
      ticket = build(:ticket, organization: project.organization, project: project, priority: nil)
      expect(ticket).not_to be_valid
      expect(ticket.errors[:priority]).to be_present
    end

    it "milestone di un ALTRO progetto → invalida (milestone_belongs_to_project)" do
      project = create(:project)
      other_project = create(:project, organization: project.organization)
      ticket = build(:ticket, organization: project.organization, project: project,
                              milestone: create(:milestone, project: other_project))
      expect(ticket).not_to be_valid
      expect(ticket.errors[:milestone]).to be_present
    end
  end

  describe "project immutabile (attr_readonly :project_id)" do
    it "solleva ReadonlyAttributeError se si tenta di cambiare project dopo la creazione" do
      ticket = create(:ticket)
      other = create(:project)

      expect { ticket.update(project_id: other.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(ticket.reload.project_id).not_to eq(other.id)
    end
  end

  describe "closed_at (sync con la category dello status)" do
    let(:organization) { create(:organization) }
    let(:open_status) { create(:ticket_status, organization: organization) }
    let(:done_status) { create(:ticket_status, :done, organization: organization) }
    let(:other_done_status) { create(:ticket_status, :done, organization: organization, label: "Closed") }

    it "resta nil alla creazione con status aperto" do
      ticket = create(:ticket, organization: organization, status: open_status)
      expect(ticket.closed_at).to be_nil
    end

    it "viene valorizzato alla creazione con status chiuso" do
      freeze_time do
        ticket = create(:ticket, organization: organization, status: done_status)
        expect(ticket.closed_at).to eq(Time.current)
      end
    end

    it "viene valorizzato quando lo status passa a chiuso" do
      ticket = create(:ticket, organization: organization, status: open_status)
      freeze_time do
        ticket.update!(status: done_status)
        expect(ticket.closed_at).to eq(Time.current)
      end
    end

    it "viene azzerato alla riapertura" do
      ticket = create(:ticket, organization: organization, status: done_status)
      ticket.update!(status: open_status)
      expect(ticket.closed_at).to be_nil
    end

    it "mantiene l'istante originale passando tra due status chiusi" do
      ticket = nil
      travel_to(3.days.ago) { ticket = create(:ticket, organization: organization, status: done_status) }
      original = ticket.closed_at
      ticket.update!(status: other_done_status)
      expect(ticket.reload.closed_at).to eq(original)
    end

    it "non cambia aggiornando campi diversi dallo status" do
      ticket = create(:ticket, organization: organization, status: done_status)
      original = ticket.closed_at
      ticket.update!(title: "Titolo nuovo")
      expect(ticket.reload.closed_at).to eq(original)
    end
  end

  describe ".open_or_recently_closed" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization) }
    let(:open_status) { create(:ticket_status, organization: organization) }
    let(:progress_status) { create(:ticket_status, :in_progress, organization: organization) }
    let(:done_status) { create(:ticket_status, :done, organization: organization) }

    def closed_ticket(closed_at)
      travel_to(closed_at) do
        create(:ticket, organization: organization, project: project, status: done_status)
      end
    end

    it "include gli aperti e gli in lavorazione senza limiti di tempo" do
      old_open = travel_to(2.years.ago) do
        create(:ticket, organization: organization, project: project, status: open_status)
      end
      in_progress = create(:ticket, organization: organization, project: project, status: progress_status)

      result = described_class.open_or_recently_closed
      expect(result).to include(old_open, in_progress)
    end

    it "include i chiusi dentro la finestra ed esclude quelli oltre (boundary ±1s)" do
      now = Time.current
      inside  = closed_ticket(now - Ticketing::Constants::DUPLICATE_CLOSED_WINDOW + 1.second)
      at_edge = closed_ticket(now - Ticketing::Constants::DUPLICATE_CLOSED_WINDOW)
      outside = closed_ticket(now - Ticketing::Constants::DUPLICATE_CLOSED_WINDOW - 1.second)

      travel_to(now) do
        result = described_class.open_or_recently_closed
        expect(result).to include(inside, at_edge)
        expect(result).not_to include(outside)
      end
    end
  end

  # CYRA-374 — l'unica definizione di «aspetta una mia decisione»: sono il revisore designato e il
  # ticket è in uno status che apre il gate di revisione, senza essere concluso. Ci si appoggiano sia
  # la coda delle Approvazioni sia il contatore in testa a board e lista: due numeri che non possono
  # divergere perché la query è una sola.
  describe ".awaiting_review_by / #awaiting_review_by? (CYRA-374)" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization) }
    let(:account) { create(:account) }
    let(:altro) { create(:account) }
    let(:review_status) { create(:ticket_status, :in_review, organization: organization) }
    let(:progress_status) { create(:ticket_status, :in_progress, organization: organization) }

    before do
      create(:membership, account: account, organization: organization, role: :member)
      create(:membership, account: altro, organization: organization, role: :member)
    end

    def ticket_with(status:, reviewer:)
      create(:ticket, organization: organization, project: project, status: status, reviewer: reviewer)
    end

    it "tiene i ticket in revisione di cui sono il revisore" do
      mio = ticket_with(status: review_status, reviewer: account)

      expect(described_class.awaiting_review_by(account)).to contain_exactly(mio)
    end

    it "esclude i ticket in revisione di cui è revisore qualcun altro" do
      ticket_with(status: review_status, reviewer: altro)

      expect(described_class.awaiting_review_by(account)).to be_empty
    end

    it "esclude i ticket senza revisore" do
      ticket_with(status: review_status, reviewer: nil)

      expect(described_class.awaiting_review_by(account)).to be_empty
    end

    it "esclude i ticket miei che non sono in uno status di revisione" do
      ticket_with(status: progress_status, reviewer: account)

      expect(described_class.awaiting_review_by(account)).to be_empty
    end

    # Il gate su uno status CONCLUSO è configurazione anomala ma possibile: una decisione su un
    # ticket già chiuso è lavoro morto e resta fuori, esattamente come nella coda delle Approvazioni.
    it "esclude i ticket in uno status di revisione ma in categoria conclusa" do
      gate_done = create(:ticket_status, :done, organization: organization, review_gate: true)
      ticket_with(status: gate_done, reviewer: account)

      expect(described_class.awaiting_review_by(account)).to be_empty
    end

    it "accetta anche l'id dell'account, non solo il record" do
      mio = ticket_with(status: review_status, reviewer: account)

      expect(described_class.awaiting_review_by(account.id)).to contain_exactly(mio)
    end

    # Il predicato è il gemello in memoria della scope: lo usano le righe di lista e board, che hanno
    # già lo status precaricato e non possono permettersi una query per riga. Parità verificata qui.
    it "il predicato dà lo stesso verdetto della scope su ogni caso" do
      candidati = [
        ticket_with(status: review_status, reviewer: account),
        ticket_with(status: review_status, reviewer: altro),
        ticket_with(status: review_status, reviewer: nil),
        ticket_with(status: progress_status, reviewer: account),
        ticket_with(status: create(:ticket_status, :done, organization: organization, review_gate: true),
                    reviewer: account)
      ]
      dalla_scope = described_class.awaiting_review_by(account).pluck(:id).to_set

      candidati.each do |ticket|
        expect(ticket.awaiting_review_by?(account)).to eq(dalla_scope.include?(ticket.id)),
                                                       "disaccordo su #{ticket.code}"
      end
    end

    it "il predicato è falso senza account (sessione senza persona collegata)" do
      mio = ticket_with(status: review_status, reviewer: account)

      expect(mio.awaiting_review_by?(nil)).to be(false)
    end
  end

  describe ".current_embedding (CYRA-168)" do
    it "tiene solo le righe della versione di embedding corrente, escludendo altra versione e nil" do
      current = create(:ticket)
      current.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
      stale = create(:ticket)
      stale.update_columns(embedding: basis_vector(0), embedding_version: "qwen3-emb-0.6b-1024-v0")
      never_embedded = create(:ticket) # embedding_version nil

      ids = described_class.current_embedding.pluck(:id)

      expect(ids).to include(current.id)
      expect(ids).not_to include(stale.id, never_embedded.id)
    end
  end

  describe "eleggibilità agenti (CYRA-184)" do
    describe "default fail-closed" do
      it "nasce da valutare, quindi non lavorabile dagli agenti" do
        ticket = create(:ticket)

        expect(ticket).to be_agent_eligibility_pending
        expect(ticket).not_to be_agent_workable
      end

      it "nasce con la sorgente automatica e nessun decisore" do
        ticket = create(:ticket)

        expect(ticket).to be_agent_eligibility_source_automatic
        expect(ticket.agent_eligibility_decided_by).to be_nil
        expect(ticket.agent_eligibility_checksum).to be_nil
      end

      # Il fail-closed è il DEFAULT DELLA COLONNA, non una scelta applicativa: anche una riga creata
      # bypassando i service (import, seed, insert_all) parte non lavorabile.
      it "vale anche per una riga inserita senza passare dai service" do
        template = create(:ticket)
        id = described_class.insert!(
          { project_id: template.project_id, status_id: template.status_id,
            priority_id: template.priority_id, reporter_id: template.reporter_id,
            title: "importato", description: "corpo", number: 9_999,
            created_at: Time.current, updated_at: Time.current }
        ).first["id"]

        expect(described_class.find(id)).to be_agent_eligibility_pending
      end
    end

    describe "#agent_workable?" do
      it "è vero solo per l'eleggibilità consentita" do
        expect(build(:ticket, agent_eligibility: :allowed)).to be_agent_workable
        expect(build(:ticket, agent_eligibility: :pending)).not_to be_agent_workable
        expect(build(:ticket, agent_eligibility: :blocked)).not_to be_agent_workable
      end
    end

    describe "#agent_eligibility_stale?" do
      it "è falso quando il checksum corrisponde al contenuto corrente" do
        ticket = create(:ticket, description: "corpo")
        ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket: ticket))

        expect(ticket).not_to be_agent_eligibility_stale
      end

      it "è vero quando cambia il corpo del ticket" do
        ticket = create(:ticket, description: "corpo")
        ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket: ticket))

        ticket.update!(description: "corpo cambiato")

        expect(ticket).to be_agent_eligibility_stale
      end

      it "è vero quando cambiano gli allegati, a corpo invariato" do
        ticket = create(:ticket, description: "corpo")
        ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket: ticket))

        ticket.files.attach(io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
                            filename: "screenshot.png", content_type: "image/png")

        expect(ticket.reload).to be_agent_eligibility_stale
      end

      it "è vero per un ticket mai valutato (checksum nullo)" do
        expect(create(:ticket, description: "corpo")).to be_agent_eligibility_stale
      end

      # CYRA-191: il cuore del bump. Un ticket GIÀ valutato in automatico (allowed/blocked) col
      # prompt vecchio deve tornare candidato alla rivalutazione appena la versione del prompt
      # cambia, altrimenti i verdetti sbagliati della v1 — i falsi blocchi — resterebbero attivi per
      # sempre. È esattamente ciò che il backfill di eleggibilità ripesca (non solo i checksum nulli).
      it "è vero per un ticket già valutato in automatico quando PROMPT_VERSION viene bumpata" do
        ticket = create(:ticket, description: "corpo", agent_eligibility: :blocked,
                                 agent_eligibility_source: :automatic)
        ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket: ticket))
        expect(ticket).not_to be_agent_eligibility_stale

        stub_const("Ticketing::AgentEligibilityText::PROMPT_VERSION", "prompt-version-bumped")

        expect(ticket).to be_agent_eligibility_stale
      end

      # La stickiness: una decisione umana non torna mai in coda di rivalutazione da sola, perché
      # sarebbe il modo silenzioso di sovrascriverla.
      it "è FALSO su un ticket con decisione umana, anche se il corpo cambia" do
        ticket = create(:ticket, description: "corpo", agent_eligibility: :allowed,
                                 agent_eligibility_source: :human)

        ticket.update!(description: "corpo completamente diverso")

        expect(ticket).not_to be_agent_eligibility_stale
      end
    end
  end

  # CYRA-392 — da quando il ticket è nello stato corrente: l'ultimo cambio di stato in cronologia,
  # o la creazione se non è mai cambiato. È la base del "in questo stato da …" della ticket-show.
  describe "#current_status_since" do
    it "senza cambi di stato è la creazione del ticket" do
      ticket = create(:ticket)

      expect(ticket.current_status_since).to be_within(1.second).of(ticket.created_at)
    end

    it "riflette l'istante dell'ultimo cambio di stato" do
      ticket = create(:ticket)
      create(:ticket_event, ticket: ticket, action: "status_changed", created_at: 3.days.ago)
      recent = create(:ticket_event, ticket: ticket, action: "status_changed", created_at: 2.hours.ago)

      expect(ticket.current_status_since).to be_within(1.second).of(recent.created_at)
    end

    it "ignora gli eventi che non sono cambi di stato" do
      ticket = create(:ticket)
      create(:ticket_event, ticket: ticket, action: "assigned", created_at: 2.hours.ago)

      expect(ticket.current_status_since).to be_within(1.second).of(ticket.created_at)
    end
  end
end
