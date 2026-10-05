# frozen_string_literal: true

require "rails_helper"

# CYRA-745 — la vista unificata di LETTURA dei registri di attività. Il prodotto scrive in registri
# separati (audit immutabile per i segreti: lo storico NON si riscrive), quindi l'unificazione avviene
# qui, in lettura. Il registro dei permessi entra per la prima volta in una pagina.
RSpec.describe Activity::AuditQuery do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:actor) { create(:account) }

  def query(**overrides)
    described_class.new(
      organization: org,
      visible_project_ids: [ project.id ],
      visible_team_ids: [],
      include_secrets: true,
      **overrides
    )
  end

  describe "sorgenti unificate" do
    it "porta in una lista sola le azioni dei quattro registri" do
      create(:activity_event, subject: project, organization: org, actor: actor, action: "created")
      create(:authorization_event, organization: org, actor: actor, action: "permission_granted")
      create(:ticket_event, ticket: create(:ticket, project: project, organization: org), organization: org)
      create(:secret_event, project: project, organization: org, action: "set", name: "API_KEY")

      expect(query.rows.map(&:source)).to match_array(%i[work permissions tickets secrets])
    end

    # Il cuore del ticket: il registro dei permessi veniva scritto e nessuna pagina lo leggeva.
    it "legge il registro dei permessi, che prima nessuno leggeva" do
      create(:authorization_event, organization: org, actor: actor, action: "permission_granted",
                                   actor_name: actor.name, data: { "role" => "Maintainer", "keys" => [ "tickets.edit" ] })

      row = query.rows.first

      expect(row.source).to eq(:permissions)
      expect(row.action).to eq("permission_granted")
      expect(row.actor_name).to eq(actor.name)
      expect(row.subject_label).to eq("Maintainer")
    end

    it "ordina dal più recente al più vecchio, qualunque sia il registro d'origine" do
      create(:authorization_event, organization: org, action: "role_created", created_at: 3.hours.ago)
      create(:activity_event, subject: project, organization: org, created_at: 1.hour.ago)
      create(:secret_event, project: project, organization: org, action: "read", created_at: 2.hours.ago)

      expect(query.rows.map(&:source)).to eq(%i[work secrets permissions])
    end
  end

  describe "confini" do
    it "esclude le righe di un'altra organizzazione" do
      create(:authorization_event, organization: other_org, action: "role_created")

      expect(query.rows).to be_empty
    end

    # Stessa regola dei ticket: `organization_id` da solo lascerebbe leggere che cosa succede dentro un
    # progetto a cui l'account non è assegnato — il documento caricato, il traguardo spostato, l'idea
    # aperta. È il buco che questa pagina, che raccoglie tutto in un posto, renderebbe comodo da usare.
    it "esclude il lavoro sui progetti non visibili" do
      invisibile = create(:project, organization: org)
      create(:activity_event, subject: invisibile, organization: org, action: "created")
      create(:activity_event, subject: project, organization: org, action: "created")

      expect(query.rows.map(&:subject_label)).to eq([ project.name ])
    end

    it "esclude documenti, traguardi e idee dei progetti non visibili" do
      invisibile = create(:project, organization: org)
      create(:activity_event, subject: create(:document, project: invisibile), organization: org)
      create(:activity_event, subject: create(:milestone, project: invisibile), organization: org)

      expect(query.rows).to be_empty
    end

    # Il carico di lavoro appartiene a un TEAM, non a un progetto: la sua visibilità è un altro asse.
    it "mostra il carico di lavoro solo dei team di cui si fa parte" do
      squadra = create(:team, organization: org)
      altra = create(:team, organization: org)
      create(:activity_event, subject: create(:workload_action, team: squadra), organization: org)
      create(:activity_event, subject: create(:workload_action, team: altra), organization: org)

      rows = described_class.new(organization: org, visible_project_ids: [ project.id ],
                                 visible_team_ids: [ squadra.id ], include_secrets: true).rows

      expect(rows.size).to eq(1)
    end

    it "esclude i ticket dei progetti non visibili" do
      invisible = create(:project, organization: org)
      create(:ticket_event, ticket: create(:ticket, project: invisible, organization: org), organization: org)

      expect(query.rows).to be_empty
    end

    # Il permesso della pagina non è quello del Vault: chi non ha secrets_audit.view vede tutto
    # il resto, ma le righe dei segreti restano fuori (somma dei gate, non gate nuovo).
    it "senza il permesso dell'audit del Vault le righe dei segreti non entrano" do
      create(:secret_event, project: project, organization: org, action: "read", name: "API_KEY")
      create(:authorization_event, organization: org, action: "role_created")

      rows = query(include_secrets: false).rows

      expect(rows.map(&:source)).to eq([ :permissions ])
    end

    # CYRA-135 — gli eventi personali sono privati di chi li ha generati, non materiale d'audit
    # dell'organizzazione: restano fuori dalla vista unificata.
    it "non porta dentro i registri personali" do
      create(:activity_event, subject: project, organization: org)
      Secrets::Personal::Event.create!(account: actor, organization: org, action: "read", name: "MIA")

      expect(query.rows.map(&:source)).to eq([ :work ])
    end
  end

  # Un registro che dice «Tizio ha tolto quel permesso» quando l'ha fatto un amministratore entrato nei
  # suoi panni sta attribuendo un'azione alla persona sbagliata: è il difetto peggiore che possa avere.
  describe "moves between organizations (CYRA-879)" do
    before do
      create(:activity_event, subject: create(:project, organization: other_org), organization: org, action: "moved_out")
    end

    it "shows an owner the project that left, although it is no longer visible here" do
      expect(query(include_moves: true).rows.map(&:action)).to eq([ "moved_out" ])
    end

    it "hides it from whoever is not an owner" do
      expect(query.rows).to be_empty
    end
  end

  describe "azioni fatte entrando nei panni di qualcun altro" do
    it "porta con sé chi ha agito davvero" do
      god = create(:account)
      create(:authorization_event, organization: org, actor: actor, true_actor: god,
                                   action: "permission_revoked", data: { "role" => "Maintainer" })

      row = query.rows.first

      expect(row).to be_impersonated
      expect(row.true_actor).to eq(god)
    end

    it "un'azione normale non risulta fatta nei panni di nessuno" do
      create(:authorization_event, organization: org, actor: actor, action: "role_created")

      expect(query.rows.first).not_to be_impersonated
    end
  end

  describe "filtri" do
    it "filtra per registro d'origine" do
      create(:activity_event, subject: project, organization: org)
      create(:authorization_event, organization: org, action: "role_created")

      expect(query(filters: { source: "permissions" }).rows.map(&:source)).to eq([ :permissions ])
    end

    it "filtra per azione" do
      create(:authorization_event, organization: org, action: "role_created")
      create(:authorization_event, organization: org, action: "permission_granted")

      expect(query(filters: { action: "role_created" }).rows.map(&:action)).to eq([ "role_created" ])
    end

    it "filtra per persona" do
      other = create(:account)
      create(:authorization_event, organization: org, actor: actor, action: "role_created")
      create(:authorization_event, organization: org, actor: other, action: "role_created")

      expect(query(filters: { actor_id: actor.id }).rows.map { |r| r.actor&.id }).to eq([ actor.id ])
    end

    it "filtra per periodo" do
      create(:authorization_event, organization: org, action: "role_created", created_at: 5.days.ago)
      create(:authorization_event, organization: org, action: "role_updated", created_at: 1.hour.ago)

      expect(query(filters: { from: 2.days.ago }).rows.map(&:action)).to eq([ "role_updated" ])
    end
  end

  describe "conteggio e finestra" do
    it "conta tutte le righe anche quando ne restituisce solo una parte" do
      create_list(:authorization_event, 3, organization: org, action: "role_created")
      create(:activity_event, subject: project, organization: org)

      limited = query(limit: 2)

      expect(limited.rows.size).to eq(2)
      expect(limited.total).to eq(4)
    end

    # Il taglio per sorgente non deve poter perdere una riga più recente di quelle tenute: prendendo
    # le prime N di ogni registro ordinato, le prime N dell'unione sono comunque quelle giuste.
    it "la finestra tiene le righe più recenti anche se stanno tutte in un registro solo" do
      create(:secret_event, project: project, organization: org, action: "read", created_at: 10.days.ago)
      create_list(:authorization_event, 2, organization: org, action: "role_created", created_at: 1.hour.ago)

      expect(query(limit: 2).rows.map(&:source)).to eq(%i[permissions permissions])
    end

    # CYRA-924 — the window cut per source must keep the OLDEST rows when the order is reversed.
    it "keeps the oldest rows in the window when asked oldest first" do
      create(:secret_event, project: project, organization: org, action: "read", created_at: 10.days.ago)
      create_list(:authorization_event, 2, organization: org, action: "role_created", created_at: 1.hour.ago)

      expect(query(limit: 2, oldest_first: true).rows.map(&:source)).to eq(%i[secrets permissions])
    end

    it "pages oldest first across the registers" do
      create(:authorization_event, organization: org, action: "role_created", created_at: 3.hours.ago)
      create(:activity_event, subject: project, organization: org, created_at: 1.hour.ago)
      create(:secret_event, project: project, organization: org, action: "read", created_at: 2.hours.ago)

      result = described_class.page(page: 1, per: 2, organization: org, visible_project_ids: [ project.id ],
                                              visible_team_ids: [], include_secrets: true, oldest_first: true)

      expect(result.records.map(&:source)).to eq(%i[permissions secrets])
    end

    it "conta zero su un'organizzazione senza registri" do
      expect(query.total).to eq(0)
      expect(query.rows).to be_empty
    end
  end

  describe "azioni disponibili per il filtro" do
    it "elenca le azioni di tutti i registri unificati" do
      expect(described_class.actions_for("permissions")).to include("permission_granted")
      expect(described_class.actions_for("tickets")).to include("status_changed")
      expect(described_class.actions_for("work")).to include("created")
      expect(described_class.actions_for("secrets")).to include("read")
    end
  end
end
