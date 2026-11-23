# frozen_string_literal: true

require "rails_helper"

# CYRA-1352 — moving a ticket opened in the wrong project, from its page.
RSpec.describe "Member ticket move", type: :request do
  let(:org) { create(:organization) }
  let(:site) { create(:project, organization: org, key: "LBWB", name: "Sito") }
  let!(:office) { create(:project, organization: org, key: "LBRA", name: "Gestionale") }
  let(:ticket) { create(:ticket, organization: org, project: site) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def linked_member(*projects)
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role: :member)
      projects.each { |project| create(:project_membership, account:, project:) }
    end
  end

  it "offers the move in the ticket menu, with the other projects to choose from" do
    sign_in(owner)
    get member_ticket_path(ticket)

    page = Nokogiri::HTML(response.body)
    expect(page.at_css("[data-test='ticket-move']")).to be_present
    expect(page.at_css("[data-test='ticket-move-modal']").text).to include("Gestionale")
  end

  it "moves the ticket and lands on it with the new code" do
    sign_in(owner)
    old_code = ticket.code

    patch move_member_ticket_path(ticket), params: { project_id: office.id }

    expect(response).to redirect_to(member_ticket_path(ticket))
    expect(ticket.reload.project).to eq(office)
    expect(flash[:notice]).to include(ticket.code)
    expect(Ticketing::TicketMove.find_by!(ticket:).from_code).to eq(old_code)
  end

  it "shows the reason when the move is refused" do
    sign_in(owner)
    ticket.create_agent_workflow!(triage_requested_at: Time.current)

    patch move_member_ticket_path(ticket), params: { project_id: office.id }

    expect(flash[:alert]).to eq(I18n.t("member.tickets.move.errors.machine_working"))
    expect(ticket.reload.project).to eq(site)
  end

  it "a person who cannot edit tickets does not see the move" do
    sign_in(linked_member(site, office))
    get member_ticket_path(ticket)

    expect(Nokogiri::HTML(response.body).at_css("[data-test='ticket-move']")).to be_nil
  end

  it "a project the person cannot see is not found" do
    sign_in(owner)
    other = create(:project)

    patch move_member_ticket_path(ticket), params: { project_id: other.id }

    expect(response).to have_http_status(:not_found)
    expect(ticket.reload.project).to eq(site)
  end

  describe "a ticket closed as a duplicate" do
    let(:done) { create(:ticket_status, organization: org, category: :done) }
    let(:kept) { create(:ticket, organization: org, project: office, title: "Pagina di login: nuovi testi") }

    before { sign_in(owner) }

    it "says so at the top and links the ticket where the work goes on" do
      ticket.update!(status: done)
      create(:ticket_link, organization: org, ticket:, related: kept, kind: :duplicate)

      get member_ticket_path(ticket)

      notice = Nokogiri::HTML(response.body).at_css("[data-test='ticket-duplicate-notice']")
      expect(notice.text).to include(kept.code)
    end

    it "says nothing while the ticket is still open" do
      create(:ticket_link, organization: org, ticket:, related: kept, kind: :duplicate)

      get member_ticket_path(ticket)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='ticket-duplicate-notice']")).to be_nil
    end
  end
end
