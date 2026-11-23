# frozen_string_literal: true

require "rails_helper"

# CYRA-1352 — a ticket opened in the wrong project moves to the right one with its history.
RSpec.describe Ticketing::MoveToProject do
  let(:organization) { create(:organization) }
  let(:site) { create(:project, organization:, key: "LBWB") }
  let(:office) { create(:project, organization:, key: "LBRA") }
  let(:actor) { create(:account).tap { |account| create(:membership, account:, organization:, role: :admin) } }
  let(:ticket) { create(:ticket, organization:, project: site) }

  def move(to: office, of: ticket)
    described_class.call(ticket: of, project: to, actor:)
  end

  it "gives the ticket the next code of the new project and keeps comments and history" do
    office.update_column(:last_ticket_number, 308)
    comment = create(:ticket_comment, ticket:, organization:)
    old_code = ticket.code

    expect(move).to be_ok

    ticket.reload
    expect(ticket.project).to eq(office)
    expect(ticket.code).to eq("LBRA-309")
    expect(ticket.comments).to contain_exactly(comment)
    expect(office.reload.last_ticket_number).to eq(309)
    expect(Ticketing::TicketMove.find_by!(ticket:).from_code).to eq(old_code)
  end

  it "writes the move in the ticket history with both codes" do
    old_code = ticket.code
    move

    event = ticket.events.find_by!(action: "moved_to_project")
    expect(event.actor).to eq(actor)
    expect(event.data).to include("from" => old_code, "to" => ticket.reload.code)
  end

  it "drops the milestone and the parent epic, which belong to the old project" do
    epic = create(:ticket, organization:, project: site, kind: :epic)
    ticket.update!(milestone: create(:milestone, project: site), parent: epic)

    expect(move).to be_ok
    expect(ticket.reload).to have_attributes(milestone: nil, parent: nil)
  end

  it "keeps only the platforms the new project also has" do
    shared = create(:platform, organization:)
    site_only = create(:platform, organization:)
    site.platforms << [ shared, site_only ]
    office.platforms << shared
    ticket.update!(platforms: [ shared, site_only ])

    expect(move).to be_ok
    expect(ticket.reload.platforms).to contain_exactly(shared)
  end

  it "can move a ticket back to a project it left, and every old code still names it" do
    move
    expect(move(to: site)).to be_ok

    expect(Ticketing::TicketMove.where(ticket:).count).to eq(2)
    expect(ticket.reload.project).to eq(site)
  end

  describe "when the move is refused" do
    def refused(result, code)
      expect(result).to be_err
      expect(result.error.code).to eq(code)
      expect(ticket.reload.project).to eq(site)
    end

    it "refuses the project it is already in" do
      refused(move(to: site), "R422-TICKET-025")
    end

    it "refuses a project of another organization" do
      refused(move(to: create(:project)), "R422-TICKET-026")
    end

    it "refuses while the machine is working on it" do
      ticket.create_agent_workflow!(triage_requested_at: Time.current)

      refused(move, "R409-TICKET-027")
    end

    it "moves a ticket whose machine work is over" do
      ticket.create_agent_workflow!(triage_requested_at: Time.current, cancelled_at: Time.current)

      expect(move).to be_ok
    end

    it "refuses a ticket with a branch in the old repository" do
      create(:github_branch, ticket:)

      refused(move, "R409-TICKET-028")
    end

    it "refuses an epic that still has tickets under it" do
      epic = create(:ticket, organization:, project: site, kind: :epic)
      create(:ticket, organization:, project: site, parent: epic)

      expect(move(of: epic)).to be_err
      expect(move(of: epic).error.code).to eq("R409-TICKET-029")
    end

    it "refuses a ticket opened from an error of the old project" do
      create(:error_group, project: site, ticket:)

      refused(move, "R409-TICKET-030")
    end
  end
end
