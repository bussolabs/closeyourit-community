# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ActivityPresenter do
  def present(action, data: {}, actor_name: "Mario")
    described_class.new(build(:ticket_event, action: action, data: data, actor_name: actor_name))
  end

  describe "#sentence (IT)" do
    around { |example| I18n.with_locale(:it) { example.run } }

    it "created" do
      expect(present("created").sentence).to eq("Mario ha creato il ticket")
    end

    it "updated (diff vuoto) → frase generica" do
      expect(present("updated").sentence).to eq("Mario ha modificato il ticket")
    end

    it "updated → elenca i campi cambiati (label i18n)" do
      sentence = present("updated", data: { "title" => [ "a", "b" ], "status" => { "from" => "X", "to" => "Y" } }).sentence
      expect(sentence).to eq("Mario ha modificato: titolo, stato")
    end

    it "updated → ordine campi CANONICO, indipendente dall'ordine nel jsonb" do
      # data con le chiavi in ordine "sbagliato" (status prima di title) → output canonico.
      sentence = present("updated", data: { "status" => { "from" => "X", "to" => "Y" }, "title" => [ "a", "b" ] }).sentence
      expect(sentence).to eq("Mario ha modificato: titolo, stato")
    end

    it "status_changed con label prima→dopo" do
      sentence = present("status_changed", data: { "status" => { "from" => "Aperto", "to" => "Chiuso" } }).sentence
      expect(sentence).to eq("Mario ha cambiato lo stato da Aperto a Chiuso")
    end

    it "assigned con il nuovo assegnatario" do
      sentence = present("assigned", data: { "assignee" => { "from" => nil, "to" => "Lia" } }).sentence
      expect(sentence).to eq("Mario ha assegnato il ticket a Lia")
    end

    it "assigned mostra SOLO il nuovo assegnatario, non il precedente" do
      sentence = present("assigned", data: { "assignee" => { "from" => "Bob", "to" => "Lia" } }).sentence
      expect(sentence).to include("Lia")
      expect(sentence).not_to include("Bob")
    end

    it "unassigned" do
      expect(present("unassigned").sentence).to eq("Mario ha rimosso l'assegnatario")
    end

    it "comment_deleted con il nome dell'autore del commento eliminato" do
      sentence = present("comment_deleted", data: { "author_name" => "Lucia" }).sentence
      expect(sentence).to eq("Mario ha eliminato un commento di Lucia")
    end

    it "attached con i filename uniti da ' · ' (non virgola: un nome può contenerla)" do
      sentence = present("attached", data: { "filenames" => [ "a.png", "b.png" ] }).sentence
      expect(sentence).to eq("Mario ha allegato a.png · b.png")
    end

    it "attachment_removed con il filename" do
      sentence = present("attachment_removed", data: { "filename" => "log.txt" }).sentence
      expect(sentence).to eq("Mario ha rimosso l'allegato log.txt")
    end

    it "attached senza filenames non solleva (lista vuota difensiva)" do
      expect { present("attached", data: {}).sentence }.not_to raise_error
    end

    it "updated con sole piattaforme → frase menziona 'piattaforme'" do
      sentence = present("updated", data: { "platforms" => { "added" => [ "iOS" ], "removed" => [] } }).sentence
      expect(sentence).to eq("Mario ha modificato: piattaforme")
    end

    it "review_rejected con label prima→dopo, SENZA la reason (vive nel commento)" do
      sentence = present("review_rejected",
                         data: { "status" => { "from" => "In Review", "to" => "In Progress" },
                                 "reason" => "Manca il test" }).sentence
      expect(sentence).to eq("Mario ha respinto la revisione e riportato lo stato da In Review a In Progress")
      expect(sentence).not_to include("Manca il test")
    end

    it "review_approved con label prima→dopo" do
      sentence = present("review_approved",
                         data: { "status" => { "from" => "In Review", "to" => "Resolved" } }).sentence
      expect(sentence).to eq("Mario ha approvato la revisione: stato da In Review a Resolved")
    end

    it "work_context_captured (frase impersonale: l'ha fotografato l'agente alla presa in carico)" do
      expect(present("work_context_captured").sentence).to eq("Contesto di lavoro fotografato alla presa in carico")
    end

    it "dependency_added mostra il code SNAPSHOTTATO del blocker (non il title)" do
      sentence = present("dependency_added", data: { "code" => "CYI-7", "title" => "Prerequisito" }).sentence
      expect(sentence).to eq("Mario ha aggiunto la dipendenza dal ticket CYI-7")
      expect(sentence).not_to include("Prerequisito")
    end

    it "dependency_removed mostra il code snapshottato del blocker" do
      sentence = present("dependency_removed", data: { "code" => "CYI-7", "title" => "Prerequisito" }).sentence
      expect(sentence).to eq("Mario ha rimosso la dipendenza dal ticket CYI-7")
    end
  end

  describe "#sentence (EN)" do
    around { |example| I18n.with_locale(:en) { example.run } }

    it "status_changed" do
      sentence = present("status_changed", data: { "status" => { "from" => "Open", "to" => "Closed" } }).sentence
      expect(sentence).to eq("Mario changed status from Open to Closed")
    end

    it "assigned (placeholder %{to})" do
      sentence = present("assigned", data: { "assignee" => { "from" => nil, "to" => "Lia" } }).sentence
      expect(sentence).to eq("Mario assigned the ticket to Lia")
    end

    it "attached (placeholder %{filenames})" do
      expect(present("attached", data: { "filenames" => [ "a.png" ] }).sentence).to eq("Mario attached a.png")
    end

    it "updated elenca i campi" do
      sentence = present("updated", data: { "priority" => { "from" => "Low", "to" => "High" } }).sentence
      expect(sentence).to eq("Mario updated: priority")
    end

    it "review_rejected (placeholder %{from}/%{to})" do
      sentence = present("review_rejected",
                         data: { "status" => { "from" => "In Review", "to" => "In Progress" },
                                 "reason" => "x" }).sentence
      expect(sentence).to eq("Mario rejected the review and moved the status from In Review to In Progress")
    end

    it "work_context_captured" do
      expect(present("work_context_captured").sentence).to eq("Work context captured on pickup")
    end
  end

  describe "#sentence — fallback attore" do
    it "usa actor.name quando actor_name è assente ma l'actor c'è" do
      actor = create(:account, name: "Giulia")
      event = build(:ticket_event, action: "created", actor: actor, actor_name: nil)
      I18n.with_locale(:it) do
        expect(described_class.new(event).sentence).to eq("Giulia ha creato il ticket")
      end
    end

    it "usa 'autore non registrato' quando actor_name e actor sono assenti (cronologia già salvata)" do
      event = build(:ticket_event, action: "created", actor: nil, actor_name: nil)
      I18n.with_locale(:it) do
        expect(described_class.new(event).sentence).to eq("Autore non registrato ha creato il ticket")
      end
    end

    it "usa 'Unrecorded author' (EN) quando attore assente" do
      event = build(:ticket_event, action: "created", actor: nil, actor_name: nil)
      I18n.with_locale(:en) do
        expect(described_class.new(event).sentence).to eq("Unrecorded author created the ticket")
      end
    end
  end

  # CYRA-385 — l'attore reale di un automatismo (agente/host) è un service account: il rendering lo
  # distingue da una persona, e i cambi di stato in automatico sono descritti come tali.
  describe "#automated? e frasi di transizione automatiche" do
    let(:org) { create(:organization) }
    let(:ticket) { create(:ticket, organization: org) }
    let(:agent) do
      create(:account, :service, name: "server-minion-1").tap do |account|
        create(:membership, account: account, organization: org, role: :member)
      end
    end

    def automated_event(action, data:)
      build(:ticket_event, ticket: ticket, action: action, data: data, actor: agent, actor_name: agent.name)
    end

    it "è automatico quando l'attore è un service account, non quando è umano o assente" do
      human = create(:account)
      expect(described_class.new(build(:ticket_event, actor: agent)).automated?).to be(true)
      expect(described_class.new(build(:ticket_event, actor: human)).automated?).to be(false)
      expect(described_class.new(build(:ticket_event, actor: nil, actor_name: nil)).automated?).to be(false)
    end

    it "descrive un cambio di stato automatico come automazione, non come persona (IT)" do
      event = automated_event("status_changed", data: { "status" => { "from" => "In Progress", "to" => "In Review" } })
      I18n.with_locale(:it) do
        expect(described_class.new(event).sentence).to eq("L'automazione ha portato il ticket in In Review")
        expect(described_class.new(event).sentence).not_to include("server-minion-1")
      end
    end

    it "descrive review approvata/respinta in automatico come automazione (IT)" do
      approved = automated_event("review_approved", data: { "status" => { "from" => "In Review", "to" => "Resolved" } })
      rejected = automated_event("review_rejected", data: { "status" => { "from" => "In Review", "to" => "In Progress" } })
      I18n.with_locale(:it) do
        expect(described_class.new(approved).sentence).to eq("L'automazione ha approvato la revisione e portato il ticket in Resolved")
        expect(described_class.new(rejected).sentence).to eq("L'automazione ha respinto la revisione e riportato il ticket in In Progress")
      end
    end

    it "descrive un cambio di stato automatico come automazione (EN)" do
      event = automated_event("status_changed", data: { "status" => { "from" => "Open", "to" => "In Review" } })
      I18n.with_locale(:en) do
        expect(described_class.new(event).sentence).to eq("The automation moved the ticket to In Review")
      end
    end

    it "espone il nome dell'attore reale (la macchina) per il badge" do
      event = automated_event("status_changed", data: { "status" => { "from" => "A", "to" => "B" } })
      expect(described_class.new(event).actor_name).to eq("server-minion-1")
    end
  end

  # CYRA-868 — la consegna passata da sola dice SU QUALI controlli è passata: «era tutto verde» senza
  # i nomi è una parola d'onore, e una decisione che nessuno ha preso va poter rimessa in discussione.
  describe "consegna passata da sola" do
    it "nomina i controlli superati" do
      event = build(:ticket_event, action: "autopilot_auto_approved", actor: nil, actor_name: "Sistema",
                                   data: { "checks" => %w[ci lint], "checks_count" => 2 })

      expect(described_class.new(event).sentence).to include("2", "ci", "lint")
    end

    # Dietro la riga c'era un programma, non una persona: il riquadro di audit non deve mostrarla con
    # le iniziali di qualcuno.
    it "è riconosciuta come fatta da una macchina, pur senza un account" do
      event = build(:ticket_event, action: "autopilot_auto_approved", actor: nil, actor_name: "Sistema")

      expect(described_class.new(event)).to be_machine
    end
  end

  describe "#icon" do
    it "mappa ogni action della allow-list a un'icona non vuota" do
      Ticketing::Event::ACTIONS.each do |action|
        icon = described_class.new(build(:ticket_event, action: action)).icon
        expect(icon).to be_present, "#{action} dovrebbe avere un'icona"
      end
    end
  end

  describe "coerenza allow-list ↔ icone ↔ i18n" do
    it "ICONS copre esattamente le ACTIONS (nessuna icona orfana o mancante)" do
      expect(described_class::ICONS.keys).to match_array(Ticketing::Event::ACTIONS)
    end

    it "ogni action ha la chiave i18n in entrambe le lingue" do
      %i[it en].each do |locale|
        Ticketing::Event::ACTIONS.each do |action|
          key = "member.tickets.activity.#{action}"
          expect(I18n.exists?(key, locale)).to be(true), "manca #{key} (#{locale})"
        end
      end
    end
  end
  # CYRA-789 — il collegamento fra ticket attraversa i progetti di proposito, quindi la riga di
  # cronologia può nominare un ticket che chi legge non ha diritto di conoscere. Il codice esce solo
  # a chi quel ticket lo vede davvero, e la prova è l'ID scritto nell'evento: il codice contiene la
  # chiave del progetto, che si rinomina e si può riassegnare — un permesso deciso su quella stringa
  # cambierebbe padrone insieme all'etichetta. Senza elenco (append realtime, dove il lettore non
  # esiste) e senza id (eventi scritti prima) la frase resta senza codice: il default è prudente.
  describe "#sentence — linked (CYRA-789)" do
    around { |example| I18n.with_locale(:it) { example.run } }

    let(:linked_id) { SecureRandom.uuid }

    def linked(visible_ticket_ids, data: { "ticket" => "SEGR-7", "ticket_id" => linked_id, "kind" => "related" })
      event = build(:ticket_event, action: "linked", data: data, actor_name: "Mario")
      described_class.new(event, visible_ticket_ids: visible_ticket_ids).sentence
    end

    it "nomina il ticket quando chi legge lo vede" do
      expect(linked(Set[linked_id])).to eq("Mario ha collegato il ticket SEGR-7 (correlato)")
    end

    it "non nomina il ticket quando chi legge non lo vede" do
      sentence = linked(Set[SecureRandom.uuid])

      expect(sentence).not_to include("SEGR-7")
      expect(sentence).to eq("Mario ha collegato un altro ticket (correlato)")
    end

    it "senza elenco dei ticket visibili non nomina il ticket" do
      expect(linked(nil)).not_to include("SEGR-7")
    end

    it "un evento scritto prima di CYRA-789 (senza id) resta senza codice" do
      sentence = linked(Set[linked_id], data: { "ticket" => "SEGR-7", "kind" => "related" })

      expect(sentence).not_to include("SEGR-7")
      expect(sentence).to eq("Mario ha collegato un altro ticket (correlato)")
    end

    it "il codice non basta: una chiave riassegnata a un progetto visibile non sblocca la riga" do
      sentence = linked(Set[SecureRandom.uuid],
                        data: { "ticket" => "SEGR-7", "ticket_id" => linked_id, "kind" => "duplicate" })

      expect(sentence).to eq("Mario ha collegato un altro ticket (duplicato)")
    end
  end

  # CYRA-406 — nel riquadro che promette di dire chi ha fatto cosa compariva «Qualcuno», con
  # l'iniziale in un cerchio come se fosse una persona: era il triage automatico.
  describe "#machine?" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:) }

    def event(action: "updated", actor: nil, actor_name: nil)
      Ticketing::Event.create!(organization:, ticket:, action:, actor:, actor_name:)
    end

    it "è vero per un sistema che si dichiara per nome senza account" do
      expect(described_class.new(event(actor_name: "GitHub")).machine?).to be(true)
    end

    it "è vero per un account di servizio" do
      service = create(:account, kind: :service, name: "closeyourit-automator")
      expect(described_class.new(event(actor: service)).machine?).to be(true)
    end

    it "è falso per una persona" do
      person = create(:account, name: "Alessio")
      expect(described_class.new(event(actor: person)).machine?).to be(false)
    end

    it "è falso quando non si sa proprio chi sia stato" do
      expect(described_class.new(event).machine?).to be(false)
    end

    it "un evento senza autore non si legge «Qualcuno»" do
      name = described_class.new(event).actor_name

      expect(name).to eq(I18n.t("member.tickets.activity.unknown_actor"))
      expect(name).not_to eq("Qualcuno")
    end
  end
end
