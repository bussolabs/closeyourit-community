# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Workload::Actions", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:team) { create(:team, organization: org) }
  let(:other_team) { create(:team, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  describe "autenticazione" do
    it "non autenticato → redirect login" do
      get member_workload_actions_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET index" do
    it "mostra le action del mio team e non quelle di altri team (anti-BOLA)" do
      sign_in(account)
      mine = create(:workload_action, team: team, organization: org, title: "Fiera del mio team")
      theirs = create(:workload_action, team: other_team, organization: org, title: "Riunione altrui")

      get member_workload_actions_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mine.title)
      expect(response.body).not_to include(theirs.title)
    end

    it "shows the filter bar as the toolbar of the white board panel (K9)" do
      sign_in(account)
      get member_workload_actions_path
      expect(response).to have_http_status(:ok)
      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='workload-board-panel'].bg-white [data-test='workload-board-toolbar']")
      expect(html).to have_no_css("[data-test='workload-board-toolbar'].sticky")
    end

    context "filtri (team/participant/has_ticket/q; status è l'asse colonne)" do
      it "filtra per team" do
        sign_in(account)
        create(:team_membership, team: other_team, account: account)
        here = create(:workload_action, team: team, organization: org, title: "Del mio primo team")
        elsewhere = create(:workload_action, team: other_team, organization: org, title: "Del mio secondo team")
        get member_workload_actions_path, params: { team_id: [ team.id ] }
        expect(response.body).to include(here.title)
        expect(response.body).not_to include(elsewhere.title)
      end

      it "filtra per participant" do
        sign_in(account)
        with_me = create(:workload_action, team: team, organization: org, title: "Con me partecipante")
        create(:connections_workload_participant, action: with_me, account: account)
        without_me = create(:workload_action, team: team, organization: org, title: "Senza di me")
        get member_workload_actions_path, params: { participant_id: [ account.id ] }
        expect(response.body).to include(with_me.title)
        expect(response.body).not_to include(without_me.title)
      end

      it "filtra per has_ticket=linked" do
        sign_in(account)
        linked = create(:workload_action, :with_ticket, team: team, organization: org, title: "Collegata a ticket")
        unlinked = create(:workload_action, team: team, organization: org, title: "Senza ticket")
        get member_workload_actions_path, params: { has_ticket: "linked" }
        expect(response.body).to include(linked.title)
        expect(response.body).not_to include(unlinked.title)
      end

      it "cerca per titolo (q)" do
        sign_in(account)
        match = create(:workload_action, team: team, organization: org, title: "Fiera unica di settore")
        other = create(:workload_action, team: team, organization: org, title: "Riunione generica")
        get member_workload_actions_path, params: { q: "fiera unica" }
        expect(response.body).to include(match.title)
        expect(response.body).not_to include(other.title)
      end

      it "filtro senza match → 200 (nessun crash)" do
        sign_in(account)
        create(:workload_action, team: team, organization: org, title: "Esistente")
        get member_workload_actions_path, params: { has_ticket: "linked" }
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "GET list (tabella)" do
    it "filtra per stato" do
      sign_in(account)
      planned = create(:workload_action, team: team, organization: org, title: "Pianificata mia", status: :planned)
      done = create(:workload_action, team: team, organization: org, title: "Completata mia", status: :done)

      get list_member_workload_actions_path, params: { status: [ "planned" ] }

      expect(response.body).to include(planned.title)
      expect(response.body).not_to include(done.title)
    end

    it "a elenco vuoto non mostra una paginazione «0–0 di 0» sotto l'invito a cominciare" do
      sign_in(account)

      get list_member_workload_actions_path

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='workload-actions-empty']")).to be_present
      expect(pagina.at_css("[data-test='workload-actions-pagination']")).to be_nil
    end
  end

  describe "PATCH status (drag della board)" do
    it "cambia lo status di una mia action" do
      sign_in(account)
      action = create(:workload_action, team: team, organization: org, status: :planned)

      patch status_member_workload_action_path(action), params: { status: "in_progress" }

      expect(response).to have_http_status(:redirect)
      expect(action.reload.status).to eq("in_progress")
    end

    it "status fuori enum → 422 (nessun cambio di stato)" do
      sign_in(account)
      action = create(:workload_action, team: team, organization: org, status: :planned)

      patch status_member_workload_action_path(action), params: { status: "bogus" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(action.reload.status).to eq("planned")
    end

    it "action di un altro team → 404 (anti-BOLA)" do
      sign_in(account)
      action = create(:workload_action, team: other_team, organization: org, status: :planned)

      patch status_member_workload_action_path(action), params: { status: "done" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    it "action del mio team → 200" do
      sign_in(account)
      action = create(:workload_action, team: team, organization: org)

      get member_workload_action_path(action)

      expect(response).to have_http_status(:ok)
    end

    it "action di un altro team → 404 (anti-BOLA)" do
      sign_in(account)
      action = create(:workload_action, team: other_team, organization: org)

      get member_workload_action_path(action)

      expect(response).to have_http_status(:not_found)
    end

    it "mostra il blocco Audit e la cronologia attività quando ci sono eventi" do
      sign_in(account)
      action = create(:workload_action, team: team, organization: org)
      Workload::Actions::Save.call(action: action, attributes: { title: "Rinominata" }, actor: account)

      get member_workload_action_path(action)

      expect(response.body).to include("workload-action-audit", "activity-modal")
    end
  end

  describe "GET new" do
    it "renderizza il form" do
      sign_in(account)
      get new_member_workload_action_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("workload-action-form")
    end
  end

  describe "POST create" do
    it "crea una action per il mio team e reindirizza" do
      sign_in(account)

      expect do
        post member_workload_actions_path, params: { team_id: team.id, title: "Nuova fiera", status: "planned" }
      end.to change(Workload::Action, :count).by(1)

      action = Workload::Action.last
      expect(action.team).to eq(team)
      expect(action.created_by).to eq(account)
      expect(response).to redirect_to(member_workload_action_path(action))
    end

    it "assegna solo i partecipanti membri del team" do
      sign_in(account)
      teammate = create(:account).tap { |a| create(:team_membership, team: team, account: a) }
      outsider = create(:account)

      post member_workload_actions_path,
           params: { team_id: team.id, title: "Con partecipanti", participant_ids: [ teammate.id, outsider.id ] }

      expect(Workload::Action.last.participants).to contain_exactly(teammate)
    end

    it "collega un ticket visibile" do
      sign_in(account)
      create(:team_project_access, team: team, project: (project = create(:project, organization: org)))
      ticket = create(:ticket, organization: org, project: project)

      post member_workload_actions_path, params: { team_id: team.id, title: "Con ticket", ticket_id: ticket.id }

      expect(Workload::Action.last.ticket).to eq(ticket)
    end

    it "titolo vuoto → 422" do
      sign_in(account)

      post member_workload_actions_path, params: { team_id: team.id, title: "" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "team non mio → 422, nessuna action per quel team (anti-BOLA)" do
      sign_in(account)

      post member_workload_actions_path, params: { team_id: other_team.id, title: "Provo team altrui" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Workload::Action.where(team_id: other_team.id)).to be_empty
    end
  end

  describe "PATCH update" do
    it "aggiorna la mia action" do
      sign_in(account)
      action = create(:workload_action, team: team, organization: org, title: "Vecchio")

      patch member_workload_action_path(action), params: { title: "Nuovo" }

      expect(action.reload.title).to eq("Nuovo")
      expect(response).to redirect_to(member_workload_action_path(action))
    end

    it "action di altro team → 404" do
      sign_in(account)
      action = create(:workload_action, team: other_team, organization: org)

      patch member_workload_action_path(action), params: { title: "Hack" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "elimina la mia action" do
      sign_in(account)
      action = create(:workload_action, team: team, organization: org)

      expect { delete member_workload_action_path(action) }.to change(Workload::Action, :count).by(-1)
      expect(response).to redirect_to(member_workload_actions_path)
    end

    it "action di altro team → 404" do
      sign_in(account)
      action = create(:workload_action, team: other_team, organization: org)

      delete member_workload_action_path(action)

      expect(response).to have_http_status(:not_found)
    end
  end
  # CYRA-359 — chi apriva "Workload" dal menu cercava "quanto lavoro ho addosso" e trovava quattro
  # colonne vuote: il nome prometteva una cosa che la pagina non contiene, e la frase che spiega a
  # cosa serve viveva solo nell'empty state di una vista secondaria.
  describe "il nome e la spiegazione della sezione (CYRA-359)" do
    it "il titolo dice cosa contiene davvero, non «Workload»" do
      sign_in(account)

      get member_workload_actions_path

      expect(response.body).to include(I18n.t("member.workload.actions.title"))
      expect(I18n.t("member.workload.actions.title")).not_to eq("Workload")
    end

    it "la frase che spiega la sezione sta sotto il titolo in ENTRAMBE le viste, non solo da vuota" do
      create(:workload_action, organization: org, team: team)
      sign_in(account)

      get member_workload_actions_path
      expect(response.body).to include(I18n.t("member.quick_add.action.when"))

      get list_member_workload_actions_path
      expect(response.body).to include(I18n.t("member.quick_add.action.when"))
    end

    it "le chip della vista a elenco contano davvero, invece di mostrare zero su tutto" do
      create(:workload_action, organization: org, team: team, status: :in_progress)
      sign_in(account)

      get list_member_workload_actions_path

      chips = Nokogiri::HTML(response.body).css("[data-test^='workload-actions-count-']").map { |el| el.text.strip }
      expect(chips).to include(a_string_matching(/1/))
    end

    it "le chip sono le stesse nelle due viste: stessi dati, stesso riassunto" do
      create(:workload_action, organization: org, team: team, status: :in_progress)
      sign_in(account)

      get member_workload_actions_path
      board = Nokogiri::HTML(response.body).css("[data-test^='workload-board-stat-']").map { |el| el.text.strip }

      get list_member_workload_actions_path
      list = Nokogiri::HTML(response.body).css("[data-test^='workload-actions-count-']").map { |el| el.text.strip }

      expect(board).to match_array(list)
    end

    it "le chip contano al plurale: «Completate: 2», non «Completata: 2»" do
      sign_in(account)

      get member_workload_actions_path
      board = Nokogiri::HTML(response.body).css("[data-test='workload-board-stat-done']").text.squish

      get list_member_workload_actions_path
      list = Nokogiri::HTML(response.body).css("[data-test='workload-actions-count-done']").text.squish

      expect([ board, list ]).to all(end_with(I18n.t("member.workload.actions.status_counts.done").downcase))
      expect(I18n.t("member.workload.actions.status_counts.done", locale: :it)).to eq("Completate")
    end
  end

  # Page refactor (2026-10-01): same shape as the projects and tickets pages.
  describe "page layout" do
    let(:participant) { create(:account, name: "Marta Rossi") }

    before { create(:team_membership, team: team, account: participant) }

    def page_html
      Capybara.string(response.body)
    end

    # CYRA-924 — Board or List is a View menu choice (C62); the list bar holds no count (C63).
    it "switches between board and list from the View menu, not from header buttons" do
      sign_in(account)

      get member_workload_actions_path(team_id: [ team.id ])
      expect(page_html).to have_css("[data-test='workload-board-toolbar-view-menu'] [data-test='workload-view-switch']", visible: :all)
      expect(page_html).to have_css("[data-test='workload-view-board'][aria-current='true']", visible: :all)
      expect(page_html).to have_css("[data-test='workload-view-list'][href*='team_id']", visible: :all)
      expect(page_html).to have_no_css("[data-test='workload-board-list-view']")

      get list_member_workload_actions_path
      expect(page_html).to have_css("[data-test='workload-actions-toolbar-view-menu'] [data-test='workload-view-switch']", visible: :all)
      expect(page_html).to have_css("[data-test='workload-view-list'][aria-current='true']", visible: :all)
      expect(page_html).to have_no_css("[data-test='workload-actions-board-view']")
      expect(page_html.find("[data-test='workload-actions-toolbar']")).to have_no_text(I18n.t("member.workload.actions.count", count: 0))
    end

    it "keeps the subtitle to one sentence and moves the 'not here' hint to the empty list and the new form" do
      sign_in(account)
      not_here = I18n.t("member.quick_add.action.not_here")

      get member_workload_actions_path
      expect(response.body).to include(I18n.t("member.quick_add.action.when"))
      expect(response.body).not_to include(not_here)

      get list_member_workload_actions_path
      expect(page_html).to have_css("[data-test='workload-actions-empty']", text: not_here)

      get new_member_workload_action_path
      expect(response.body).to include(not_here)
    end

    it "renders the cancelled column collapsed, with a button to open it" do
      sign_in(account)

      get member_workload_actions_path

      expect(page_html).to have_css("[data-test='workload-board-column-cancelled'][data-collapsed='true']")
      expect(page_html).to have_css("[data-test='workload-board-expand-cancelled']")
      expect(page_html).to have_css("[data-test='workload-board-column-planned'][data-collapsed='false']")
    end

    it "shows the due date, short dates and participant initials on the board card" do
      action = create(:workload_action, team: team, organization: org, title: "Stand fair",
                                        scheduled_at: Time.zone.local(2026, 3, 12, 9), due_at: 1.day.ago)
      create(:connections_workload_participant, action: action, account: participant)
      sign_in(account)

      get member_workload_actions_path

      card = page_html.find("[data-test='workload-board-card-#{action.id}']")
      expect(card).to have_css("[data-test='workload-due'][data-due-state='late']")
      expect(card).to have_text(I18n.l(Date.new(2026, 3, 12), format: :day_month))
      expect(card).to have_no_text("12/03/2026")
      expect(card).to have_css("[data-test='workload-participant-initials']", text: "MR")
    end

    it "filters the list by participant and remembers it" do
      mine = create(:workload_action, team: team, organization: org, title: "With Marta")
      create(:connections_workload_participant, action: mine, account: participant)
      create(:workload_action, team: team, organization: org, title: "Without Marta")
      sign_in(account)

      get list_member_workload_actions_path(participant_id: [ participant.id ])

      expect(page_html).to have_css("[data-test='filter-participant']")
      expect(response.body).to include("With Marta")
      expect(response.body).not_to include("Without Marta")
    end

    it "shows a sortable due date column in the list" do
      create(:workload_action, team: team, organization: org, title: "Later", due_at: 5.days.from_now)
      create(:workload_action, team: team, organization: org, title: "Sooner", due_at: 2.days.from_now)
      sign_in(account)

      get list_member_workload_actions_path(sort: "due")

      expect(response.body).to include(I18n.t("member.workload.actions.col_due"))
      expect(response.body.index("Sooner")).to be < response.body.index("Later")
    end

    describe "detail" do
      let(:action) do
        create(:workload_action, :with_ticket, team: team, organization: org, title: "Acme call",
                                               status: :in_progress, due_at: 3.days.from_now)
      end

      before { sign_in(account) }

      it "puts team, status, dates and ticket in a Details panel instead of header chips" do
        get member_workload_action_path(action)

        details = page_html.find("[data-test='workload-action-details']")
        expect(details).to have_css("[data-test='workload-detail-team']", text: team.name)
        expect(details).to have_css("[data-test='workload-detail-due']")
        expect(details).to have_css("[data-test='workload-detail-ticket']", text: action.ticket.code)
        expect(page_html).to have_no_css("[data-test='workload-action-team']")
        expect(page_html).to have_css("[data-test='workload-action-ticket-card']")
      end

      it "offers every status from the Details panel" do
        get member_workload_action_path(action)

        Workload::Action.statuses.each_key do |status|
          expect(page_html).to have_css("[data-test='workload-action-status-#{status}']", visible: :all)
        end
      end

      it "moves Delete into the more menu" do
        get member_workload_action_path(action)

        expect(page_html).to have_css("details:has([data-test='workload-action-more-menu']) [data-test='workload-action-delete']", visible: :all)
      end
    end
  end
end
