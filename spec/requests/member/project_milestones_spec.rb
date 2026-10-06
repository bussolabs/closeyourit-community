# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectMilestones", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    # Scoping Fase E: il member vede il progetto solo se assegnato.
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_project_milestones_path(project)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_project_milestones_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "member assegnato (può vedere, non gestire) → 200" do
      sign_in(member)
      get member_project_milestones_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "member non assegnato → 404 (scoping)" do
      other = create(:account)
      create(:membership, account: other, organization: org, role: :member)
      sign_in(other)
      get member_project_milestones_path(project)
      expect(response).to have_http_status(:not_found)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get member_project_milestones_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "pagina: pagina 1 piena (TABLE_PER_PAGE righe) + footer, resto in pagina 2" do
      sign_in(owner)
      create_list(:milestone, App::Constants::TABLE_PER_PAGE + 1, project: project)

      get member_project_milestones_path(project), params: { page: 1 }
      expect(response.body.scan('data-test="milestone-row-').size).to eq(App::Constants::TABLE_PER_PAGE)
      expect(response.body).to include('data-test="milestones-pagination"')

      get member_project_milestones_path(project), params: { page: 2 }
      expect(response.body.scan('data-test="milestone-row-').size).to eq(1)
    end
  end

  describe "GET show" do
    let(:milestone) { create(:milestone, project: project, label: "v2.0") }

    it "owner → 200 con i ticket della milestone" do
      create(:ticket, organization: org, project: project, milestone: milestone)
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      expect(response).to have_http_status(:ok)
    end

    it "shows «View activity history» as a link, the way the ticket page does" do
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      expect(Capybara.string(response.body)).to have_css("button[data-test='milestone-history'].text-indigo-600")
    end

    it "milestone di un progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign_project = create(:project, organization: create(:organization))
      foreign_milestone = create(:milestone, project: foreign_project)
      get member_project_milestone_path(foreign_project, foreign_milestone)
      expect(response).to have_http_status(:not_found)
    end

    it "mostra il blocco Audit e la cronologia attività quando ci sono eventi" do
      Projects::Milestones::Save.call(milestone: milestone, attributes: { label: "v2.1" }, actor: owner)
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      expect(response.body).to include("milestone-audit", "activity-modal")
    end
  end

  describe "GET new" do
    it "owner → 200" do
      sign_in(owner)
      get new_member_project_milestone_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "member (assegnato ma non gestore) → redirect root (forbidden)" do
      sign_in(member)
      get new_member_project_milestone_path(project)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "owner crea la milestone" do
      sign_in(owner)
      expect do
        post member_project_milestones_path(project),
             params: { code: "v2_0", label: "v2.0", color: "indigo", due_on: "2026-09-30", active: "1" }
      end.to change(project.milestones, :count).by(1)
      milestone = project.milestones.find_by(code: "v2_0")
      expect(milestone.label).to eq("v2.0")
      expect(milestone.created_by).to eq(owner)
      expect(response).to redirect_to(member_project_milestones_path(project))
    end

    it "label vuota → 422, nessuna creazione" do
      sign_in(owner)
      expect do
        post member_project_milestones_path(project), params: { code: "v2_0", label: "", color: "indigo" }
      end.not_to change(project.milestones, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "member → redirect root, nessuna creazione" do
      sign_in(member)
      expect do
        post member_project_milestones_path(project), params: { code: "v9_0", label: "v9.0", color: "indigo" }
      end.not_to change(project.milestones, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET edit / PATCH update" do
    let(:milestone) { create(:milestone, project: project, label: "v1.0") }

    it "owner edit → 200" do
      sign_in(owner)
      get edit_member_project_milestone_path(project, milestone)
      expect(response).to have_http_status(:ok)
    end

    it "owner update rinomina la milestone" do
      sign_in(owner)
      patch member_project_milestone_path(project, milestone), params: { code: milestone.code, label: "v1.1", color: "emerald", active: "1" }
      expect(milestone.reload.label).to eq("v1.1")
      expect(response).to redirect_to(member_project_milestone_path(project, milestone))
    end

    it "owner update con label vuota → 422 ri-render edit" do
      sign_in(owner)
      patch member_project_milestone_path(project, milestone), params: { code: milestone.code, label: "", color: "emerald", active: "1" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(milestone.reload.label).to eq("v1.0")
    end
  end

  describe "DELETE destroy" do
    it "owner elimina la milestone, i ticket sopravvivono (milestone_id nullify)" do
      milestone = create(:milestone, project: project)
      ticket = create(:ticket, organization: org, project: project, milestone: milestone)
      sign_in(owner)
      expect do
        delete member_project_milestone_path(project, milestone)
      end.to change(project.milestones, :count).by(-1)
      expect(Ticketing::Ticket).to exist(ticket.id)
      expect(ticket.reload.milestone_id).to be_nil
      expect(response).to redirect_to(member_project_milestones_path(project))
    end
  end

  # CYRA-26: the rollup note is a design-system tooltip, never hand-drawn markup. It now sits next
  # to "Completion", the number it explains, instead of next to the title.
  describe "rollup note next to Completion" do
    let(:milestone) { create(:milestone, project: project, label: "v3.0") }

    before { sign_in(owner) }

    it "explains the completion maths in an info tooltip inside the progress block" do
      get member_project_milestone_path(project, milestone)
      tip = Nokogiri::HTML(response.body).at_css("[data-test='milestone-progress'] [data-test='milestone-rollup-tip'] [role='tooltip']")
      expect(tip).to be_present
      expect(tip.text).to include(I18n.t("member.milestones.show.rollup_note"))
    end

    it "keeps no lightbulb next to the title and no hand-drawn note" do
      get member_project_milestone_path(project, milestone)
      header = Nokogiri::HTML(response.body).at_css("[data-test='milestone-header']")
      expect(header.css("svg[data-icon='lightbulb']")).to be_empty
      # The tooltip's own info icon is the only one: no hand-drawn info note elsewhere.
      info_icons = Nokogiri::HTML(response.body).css("svg[data-icon='info']")
      expect(info_icons.reject { |svg| svg.ancestors("[data-test='milestone-rollup-tip']").any? }).to be_empty
    end
  end

  describe "list layout" do
    before { sign_in(owner) }

    def doc = Nokogiri::HTML(response.body)
    def rows = doc.css("[data-test^='milestone-row-']")

    # CYRA-924 — count and New sit beside the section title (C63, T5); the bar holds neither.
    it "puts the count and New milestone beside the section title, not in the bar" do
      create(:milestone, project: project)
      get member_project_milestones_path(project)
      heading = doc.at_css("[data-test='milestones-heading']")
      expect(heading.at_css("h2").text.strip).to eq(I18n.t("member.milestones.title"))
      expect(heading.at_css("[data-test='milestones-count']").text).to eq(I18n.t("member.milestones.count", count: 1))
      expect(heading.at_css("[data-test='milestone-new']")).to be_present
      toolbar = doc.at_css("[data-test='milestones-toolbar']")
      expect(toolbar.at_css("[data-test='milestone-new']")).to be_nil
      expect(toolbar.text).not_to include(I18n.t("member.milestones.count", count: 1))
    end

    it "shows a single New milestone button when the project has none" do
      get member_project_milestones_path(project)
      expect(response.body.scan(new_member_project_milestone_path(project)).size).to eq(1)
      expect(doc.at_css("[data-test='milestones-empty-new']")).to be_present
      expect(doc.at_css("[data-test='milestones-toolbar']")).to be_nil
    end

    it "searches by label or code" do
      create(:milestone, project: project, label: "Checkout", code: "checkout")
      create(:milestone, project: project, label: "v2.0", code: "v2_0")
      get member_project_milestones_path(project), params: { q: "check" }
      expect(rows.map { |r| r.text }).to contain_exactly(a_string_including("Checkout"))
    end

    it "shows no results with a reset when the search matches nothing" do
      create(:milestone, project: project, label: "v2.0")
      get member_project_milestones_path(project), params: { q: "zzz" }
      expect(doc.at_css("[data-test='milestones-no-results']")).to be_present
    end

    it "filters by status without grouping" do
      create(:milestone, project: project, label: "Live", active: true)
      old = create(:milestone, project: project, label: "Old", active: false)
      get member_project_milestones_path(project), params: { status: [ "inactive" ] }
      expect(rows.map { |r| r["data-test"] }).to eq([ "milestone-row-#{old.id}" ])
      expect(doc.at_css("[data-test='milestones-inactive-group']")).to be_nil
    end

    it "puts inactive milestones at the bottom in a closed Inactive group" do
      old = create(:milestone, project: project, label: "Old", active: false, due_on: 1.day.from_now)
      live = create(:milestone, project: project, label: "Live", active: true, due_on: 30.days.from_now)
      get member_project_milestones_path(project)
      ids = doc.css("tbody tr").map { |r| r["data-test"] }
      expect(ids).to eq([ "milestone-row-#{live.id}", "milestones-inactive-group", "milestone-row-#{old.id}" ])
      expect(doc.at_css("[data-test='milestones-inactive-group']").text).to include(I18n.t("member.milestones.inactive_group", count: 1))
      expect(doc.at_css("[data-test='milestone-row-#{old.id}']")["hidden"]).not_to be_nil
    end

    it "shows a short due date with the time left" do
      travel_to(Time.zone.local(2026, 10, 1, 12)) do
        create(:milestone, project: project, due_on: Date.new(2026, 10, 21))
        get member_project_milestones_path(project)
        due = doc.at_css("[data-test='milestone-due']").text.squish
        expect(due).to include(I18n.l(Date.new(2026, 10, 21), format: :day_month))
        expect(due).to include(I18n.t("member.milestones.due_in", count: 20))
        expect(due).not_to include("2026")
      end
    end

    it "colours a due date that is close or past while the milestone is active" do
      travel_to(Time.zone.local(2026, 10, 1, 12)) do
        create(:milestone, project: project, label: "Soon", due_on: Date.new(2026, 10, 5))
        create(:milestone, project: project, label: "Late", due_on: Date.new(2026, 9, 20))
        create(:milestone, project: project, label: "Far", due_on: Date.new(2026, 12, 20))
        create(:milestone, project: project, label: "Done", due_on: Date.new(2026, 9, 1), active: false)
        get member_project_milestones_path(project)
        states = doc.css("[data-test='milestone-due']").map { |d| d["data-due-state"] }
        expect(states).to eq(%w[late soon on_time on_time])
      end
    end

    it "shows how many tickets are done next to the percentage" do
      milestone = create(:milestone, project: project)
      done = create(:ticket_status, organization: org, category: :done)
      create(:ticket, organization: org, project: project, milestone: milestone, status: done)
      # Bulk fixture in setup, not a production N+1.
      allow_n_plus_one { create_list(:ticket, 2, organization: org, project: project, milestone: milestone) }
      get member_project_milestones_path(project)
      expect(doc.at_css("[data-test='milestone-progress-count-#{milestone.id}']").text.squish)
        .to eq(I18n.t("member.milestones.progress_count", done: 1, total: 3))
    end
  end

  describe "empty list for someone who cannot create" do
    it "uses the viewer text and offers no button" do
      sign_in(member)
      get member_project_milestones_path(project)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("member.milestones.empty_body_viewer")))
      expect(response.body).not_to include(new_member_project_milestone_path(project))
    end
  end

  describe "detail layout" do
    let(:milestone) { create(:milestone, project: project, label: "v2.0", code: "v2_0", due_on: 20.days.from_now.to_date) }
    let(:done) { create(:ticket_status, organization: org, category: :done) }

    def doc = Nokogiri::HTML(response.body)

    it "puts code, status and due date in a Details panel, and the audit in a panel that closes the page" do
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      details = doc.at_css("[data-test='milestone-details']")
      expect(details).to be_present
      %w[milestone-detail-code milestone-detail-status milestone-detail-due].each do |id|
        expect(details.at_css("[data-test='#{id}']")).to be_present, "missing #{id}"
      end
      audit = doc.at_css("[data-test='milestone-audit']")
      expect(audit.at_css("[data-test='milestone-audit-meta']")).to be_present
      expect(audit.at_css("[data-test='milestone-history']")).to be_present
      expect(response.body.index('data-test="milestone-details"')).to be < response.body.index('data-test="milestone-audit"')
    end

    it "keeps Edit as a button and moves Delete into the more menu" do
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      expect(doc.at_css("[data-test='milestone-edit']")).to be_present
      expect(doc.at_css("details:has([data-test='milestone-more-menu']) [data-test='milestone-delete']")).to be_present
      delete_form = doc.at_css("[data-test='milestone-delete']").ancestors("form").first
      expect(delete_form["data-turbo-confirm"]).to eq(I18n.t("member.milestones.delete_confirm"))
    end

    it "keeps the way back to the list" do
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      expect(doc.at_css("[data-test='milestone-back']")).to be_present
    end

    it "lets a manager switch the milestone on and off from Details" do
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      expect(doc.at_css("[data-test='milestone-detail-status'] [data-test='milestone-active-toggle']")).to be_present
    end

    it "shows the status as a badge to someone who cannot manage" do
      sign_in(member)
      get member_project_milestone_path(project, milestone)
      expect(doc.at_css("[data-test='milestone-active-toggle']")).to be_nil
      expect(doc.at_css("[data-test='milestone-detail-status']").text).to include(I18n.t("member.milestones.status_active"))
    end

    it "writes the progress in plain words" do
      create(:ticket, organization: org, project: project, milestone: milestone, status: done, weight: 1)
      create(:ticket, organization: org, project: project, milestone: milestone, weight: 2)
      create(:ticket, organization: org, project: project, milestone: milestone, weight: 2)
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      text = doc.at_css("[data-test='milestone-progress']").text.squish
      expect(text).to include(I18n.t("member.milestones.show.tickets_closed", done: 1, total: 3))
      expect(text).to include(I18n.t("member.milestones.show.points", done: 1, total: 5))
      expect(text).not_to include(" done", "pt")
    end

    it "makes the ticket columns sortable" do
      heavy = create(:ticket, organization: org, project: project, milestone: milestone, weight: 8)
      light = create(:ticket, organization: org, project: project, milestone: milestone, weight: 1)
      sign_in(owner)
      get member_project_milestone_path(project, milestone), params: { sort: "-weight" }
      ids = doc.css("[data-test^='milestone-ticket-']").map { |r| r["data-test"] }
      expect(ids).to eq([ "milestone-ticket-#{heavy.id}", "milestone-ticket-#{light.id}" ])
      expect(doc.css("[data-test='milestone-tickets'] thead a[href*='sort=']").size).to be >= 5
    end

    it "puts closed tickets at the bottom in a closed Closed group" do
      closed = create(:ticket, organization: org, project: project, milestone: milestone, status: done)
      open = create(:ticket, organization: org, project: project, milestone: milestone)
      sign_in(owner)
      get member_project_milestone_path(project, milestone)
      ids = doc.css("[data-test='milestone-tickets'] tbody tr").map { |r| r["data-test"] }
      expect(ids).to eq([ "milestone-ticket-#{open.id}", "milestone-tickets-closed-group", "milestone-ticket-#{closed.id}" ])
      expect(doc.at_css("[data-test='milestone-tickets-closed-group']").text).to include(I18n.t("member.milestones.show.closed_group", count: 1))
      expect(doc.at_css("[data-test='milestone-ticket-#{closed.id}']")["hidden"]).not_to be_nil
    end
  end

  describe "PATCH update from the Details switch" do
    let(:milestone) { create(:milestone, project: project, active: true) }

    it "saves the active flag as JSON without a redirect" do
      sign_in(owner)
      patch member_project_milestone_path(project, milestone), params: { active: "0" }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:no_content)
      expect(milestone.reload.active).to be(false)
    end

    it "refuses someone who cannot manage" do
      sign_in(member)
      patch member_project_milestone_path(project, milestone), params: { active: "0" }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(milestone.reload.active).to be(true)
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      milestone = create(:milestone, project: project, label: "v2.0")

      get member_project_milestones_path(project)

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='milestone-delete-dialog-#{milestone.id}']")
      expect(dialog.text).to include(I18n.t("member.milestones.delete_dialog.title", label: "v2.0"))
      expect(dialog.at_css("form")["action"]).to eq(member_project_milestone_path(project, milestone))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='milestone-delete-#{milestone.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
