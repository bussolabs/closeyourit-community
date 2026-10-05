# frozen_string_literal: true

require "rails_helper"

# CYRA-929 — the development seeds fill the demo organization on every page and leave a second one
# empty, for the empty states. Re-seeding adds nothing twice.
RSpec.describe "db/seeds.rb in development" do
  def seed
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
    expect { load Rails.root.join("db/seeds.rb") }.to output.to_stdout
  end

  def demo_counts(org)
    project_ids = Projects::Project.where(organization: org).select(:id)
    {
      projects: Projects::Project.where(organization: org).count,
      tickets: Ticketing::Ticket.where(project_id: project_ids).count,
      errors: Errors::Group.where(project_id: project_ids).count,
      events: Errors::Event.where(project_id: project_ids).count,
      logs: Logs::Entry.where(project_id: project_ids).count,
      metrics: Metrics::Group.where(project_id: project_ids).count,
      findings: Vulnerabilities::Finding.where(project_id: project_ids).count,
      replays: Replays::Session.where(project_id: project_ids).count,
      monitors: Uptime::Monitor.where(project_id: project_ids).count,
      ideas: Ideas::Idea.where(project_id: project_ids).count,
      helpdesk: Helpdesk::Request.where(project_id: project_ids).count,
      pages: Knowledge::Page.where(organization: org).count,
      todos: Todos::Item.joins(:list).where(todos_lists: { organization_id: org.id }).count,
      notifications: Alerting::Notification.where(organization: org).count
    }
  end

  it "fills the demo organization past one page, keeps the empty one bare, and adds nothing twice" do
    seed
    demo = Organizations::Organization.find_by!(slug: "demo")
    first = demo_counts(demo)

    expect(first[:projects]).to be > 12
    expect(first[:tickets]).to be > 24
    expect(first.except(:projects, :tickets).values).to all(be_positive)
    expect(Projects::Project.where(organization: Organizations::Organization.find_by!(slug: "empty"))).to be_empty

    seed
    expect(demo_counts(demo)).to eq(first)
  end
end
