# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Home", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  # Un piano da approvare, la famiglia più semplice della coda.
  def piano(planned_at: 2.days.ago, project: self.project)
    ticket = create(:ticket, organization: org, project: project)
    create(:agent_workflow, ticket:, planned_at:)
  end

  # CYRA-665 — la riga in cima parlava di lavoro che non riguarda chi la legge: «dodici vanno avanti
  # da sole» compariva anche a chi non governa nessun agente, accanto al link a un elenco su cui non
  # poteva fare niente.
  describe "il conteggio di ciò che va avanti da solo" do
    it "compare a chi risponde di almeno un progetto" do
      piano
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='home-count-in-flight']")).to be_present
    end

    it "non compare a chi non è responsabile di nessun progetto" do
      create(:project_membership, account: member, project:)
      ticket = create(:ticket, organization: org, project:, reviewer: member,
                               status: create(:ticket_status, :in_review, organization: org))
      create(:agent_workflow, ticket:, triage_started_at: 1.hour.ago)
      sign_in(member)

      get root_path

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-test='home-count-in-flight']")).to be_nil
      # La decisione che lo riguarda resta: è il resto ad essere sparito.
      expect(html.at_css("[data-test='home-queue-bar']")).to be_present
    end

    # Zero e «non ti riguarda» non sono la stessa cosa, e la pagina non deve confonderle.
    it "compare a zero a chi risponde di un progetto senza lavorazioni in volo" do
      project
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='home-count-in-flight']")).to be_present
    end
  end

  # CYRA-321 aveva messo in fondo alla home un blocco «e adesso?» con tre uscite, perché finita la
  # coda la pagina non portava da nessuna parte. Tolto: la navigazione le porta già tutte, e in
  # fondo a una pagina che mostra UNA cosa da decidere quel blocco era l'unica cosa lunga.
  describe "in fondo alla home non c'è più niente da leggere" do
    it "non rende il vecchio blocco «e adesso?»" do
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='home-next-steps']")).to be_nil
    end

    # L'assenza da sola non basta: una pagina rotta la passerebbe. Con una decisione davanti, la
    # pagina deve finire con la decisione.
    it "con una decisione davanti, la pagina finisce lì" do
      piano
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='decision-columns']")).to be_present
      expect(html.at_css("[data-test='home-next-steps']")).to be_nil
    end
  end

  # CYRA-657 — la home mostra UNA decisione, non quattro elenchi.
  describe "la decisione in home" do
    # CYRA-884 — the project sits on one line above the decision instead of a left column.
    it "shows the oldest decision with the project on one line and the actions on the right" do
      oldest = piano(planned_at: 5.days.ago)
      piano(planned_at: 1.hour.ago)
      sign_in(owner)

      get root_path

      pagina = html
      expect(pagina.at_css("[data-test='decision-code']").text).to eq(oldest.ticket.code)
      expect(pagina.at_css("[data-test='decision-columns']")).to be_present
      expect(pagina.at_css("[data-test='decision-strip'] [data-test='decision-project']").text).to eq(project.name)
      expect(pagina.at_css("[data-test='decision-strip'] [data-test='decision-waited']")).to be_present
      expect(pagina.at_css("[data-test='project-aside']")).to be_nil
      expect(pagina.at_css("[data-test='approvals-decision']")).to be_present
      expect(pagina.at_css("[data-test='decision-not-now']")).to be_present
    end

    it "dice quante ne restano, e il numero è quello pieno della coda" do
      # Fixture bulk: creare tre ticket in fila fa scattare le validazioni tenant una per ticket.
      # È il setup, non il rendering della home — che gira dopo, sotto scan.
      allow_n_plus_one { 3.times { |n| piano(planned_at: (n + 1).days.ago) } }
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='home-count-total']").text).to include("3")
      expect(html.at_css("[data-test='home-see-all']")).to be_present
    end

    # B25 — the Home has the page header like every member page; it replaced the thin queue bar
    # (CYRA-657), whose numbers became its counts and whose links became its actions.
    it "opens with the page header, carrying the queue numbers and the back and see-all actions" do
      prima = piano(planned_at: 5.days.ago)
      piano(planned_at: 2.days.ago)
      sign_in(owner)
      post member_home_card_skip_path, params: { item: "agent_plan:#{prima.id}" }

      get root_path

      header = html.at_css("[data-test='home-header']")
      expect(header.at_css("h1").text.strip).to eq("Home")
      expect(header.at_css("[data-test='home-header-subtitle']")).to be_present
      expect(header.at_css("[data-test='home-queue-bar'] [data-test='home-count-total']")).to be_present
      expect(header.at_css("[data-test='home-header-actions'] [data-test='home-back']")).to be_present
      expect(header.at_css("[data-test='home-header-actions'] [data-test='home-see-all']")).to be_present
      expect(header.at_css("[data-test='home-header-collapse']")).to be_present
      expect(html.css("h1").size).to eq(1)
    end

    it "porta i passaggi della lavorazione in cima, fuori dalle colonne" do
      piano
      sign_in(owner)

      get root_path

      soggetto = html.at_css("[data-test='decision-subject']")
      expect(soggetto.at_css("[data-test='approval-phase-strip']")).to be_present
    end

    # CYRA-837 — anche in Home i sei passaggi portano le parole della guida, nella lingua scelta.
    it "chiama i passaggi con le parole della guida, in italiano" do
      piano
      owner.update!(locale: "it")
      sign_in(owner)

      get root_path

      striscia = html.at_css("[data-test='approval-phase-strip']")
      nomi = striscia.css("[data-phase]").map { |voce| voce.text.split(" — ").first.strip }
      expect(nomi).to eq([ "Da pianificare", "Piano da approvare", "In lavorazione", "Da revisionare",
                           "In chiusura", "Fatto" ])
      expect(response.body).not_to include("translation_missing")
    end

    it "dopo aver deciso da qui si torna qui, non sulla plancia" do
      workflow = piano
      sign_in(owner)

      get root_path

      azione = html.at_css("[data-test='approvals-approve']").ancestors("form").first
      expect(azione["action"]).to include("return_to=home")
      expect(workflow.reload.planned_at).to be_present
    end
  end

  describe "quando non c'è niente da decidere" do
    it "lo dice, e conta quello che va avanti da solo" do
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='home-empty-done']")).to be_present
      expect(html.at_css("[data-test='decision-subject']")).to be_nil
    end
  end

  describe "scoping per-membro (nessun leak cross-progetto)" do
    it "il member non vede la decisione di un progetto che non gli è assegnato" do
      piano
      sign_in(member)

      get root_path

      expect(html.at_css("[data-test='decision-subject']")).to be_nil
      expect(html.at_css("[data-test='home-empty-done']")).to be_present
    end
  end

  describe "senza organizzazione" do
    it "lo dice invece di mandare da qualche altra parte" do
      solitario = create(:account)
      sign_in(solitario)

      get root_path

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-test='home-no-org']")).to be_present
      # The header toggle saves to an endpoint that needs an organization: no header, no lost choice.
      expect(html.at_css("[data-test='home-header']")).to be_nil
    end
  end

  # CYRA-861 — in home a vista restano approva, altre scelte, salta e rimanda.
  describe "i gesti a vista sulla scheda" do
    it "in home respingi e chiedi stanno dentro «Altre scelte», chiuso" do
      piano
      sign_in(owner)

      get root_path

      more = html.at_css("details[data-test='approvals-more-choices']")
      expect(more).to be_present
      expect(more["open"]).to be_nil
      expect(more.at_css("[data-test='approvals-reject']")).to be_present
      expect(more.at_css("[data-test='approvals-ask']")).to be_present
      expect(html.at_css("[data-test='approvals-approve']")).to be_present
      expect(html.at_css("details[data-test='approvals-note'] [data-test='approvals-approve-note']")).to be_present
      expect(html.at_css("[data-test='decision-not-now'] p")).to be_nil
      expect(html.at_css("[data-test='decision-skip']")["title"]).to eq(I18n.t("member.home.decision.skip_hint"))
    end

    it "sulla pagina intera il pannello resta aperto com'era" do
      workflow = piano
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)

      expect(html.at_css("[data-test='approvals-more-choices']")).to be_nil
      expect(html.at_css("[data-test='approvals-reject']")).to be_present
      expect(html.at_css("details[data-test='approvals-note'][open]")).to be_present
    end
  end

  # CYRA-884 — the bar says what kind of decisions are waiting and how long the oldest has waited.
  describe "queue sentence" do
    it "breaks the total down by state with the filter labels and names the oldest wait" do
      allow_n_plus_one do
        piano(planned_at: 3.days.ago)
        piano(planned_at: 1.hour.ago)
      end
      sign_in(owner)

      get root_path

      breakdown = html.at_css("[data-test='home-count-breakdown']")
      expect(breakdown.text).to include(I18n.t("member.approvals.filters.awaiting_approval"))
      expect(breakdown.text).to include("2")
      expect(html.at_css("[data-test='home-count-oldest']")).to be_present
    end

    it "shows no breakdown when nothing is queued" do
      sign_in(owner)

      get root_path

      expect(html.at_css("[data-test='home-count-breakdown']")).to be_nil
    end
  end

  # CYRA-884 — one line under the approve button says what happens next, on the home only.
  describe "after approving" do
    it "tells what happens after approving, only on the home" do
      workflow = piano
      sign_in(owner)

      get root_path
      expect(html.at_css("[data-test='approvals-approve-hint']").text)
        .to include(I18n.t("member.approvals.approve_hint.awaiting_approval"))

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)
      expect(html.at_css("[data-test='approvals-approve-hint']")).to be_nil
    end
  end
end
