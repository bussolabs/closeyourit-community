# frozen_string_literal: true

require "rails_helper"

RSpec.describe "review demo data" do
  def load_review_data
    load Rails.root.join("db/seeds/review_data.rb")
  end

  it "does nothing outside development" do
    expect { load_review_data }.not_to change(Todos::List, :count)
  end

  it "fills the admin's empty surfaces and preserves edits when run again" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
    expect { load Rails.root.join("db/seeds.rb") }.to output.to_stdout
    organization = Organizations::Organization.find_by!(slug: "demo")
    admin = Accounts::Account.find_by!(email: "admin@demo.test")

    expect(Todos::List.for(account: admin, organization:).count).to be_positive
    expect(Chat::Conversation.visible_to(account: admin, organization:).count).to be_positive
    expect(Knowledge::Book.where(organization:).count).to be_positive
    expect(Knowledge::Page.where(organization:, status: :in_review).count).to be_positive
    expect(Ticketing::Ticket.awaiting_review_by(admin).count).to be_positive
    expect(Product::Feature.where(organization:).count).to be_positive
    expect(Datasets::Dataset.joins(:project).where(projects: { organization_id: organization.id }).count).to be_positive
    expect(Crons::Monitor.where(slug: "codex-test-ok").count).to eq(1)
    expect(Seo::Issue.joins(site: :project).where(projects: { organization_id: organization.id }).count).to eq(2)
    expect(Alerting::Channel.where(organization:, enabled: false).count).to be_positive
    expect(Uptime::Group.where(organization:, public_status_enabled: true).count).to be_positive
    metric = Metrics::Group.find_by!(fingerprint: "codex-test-checkout")
    expect(metric.samples.count).to eq(metric.samples_count)
    expect(metric.samples.sum(:duration_ms)).to eq(metric.duration_total_ms)
    replay = Replays::Session.find_by!(replay_session_id: "codex-test-checkout")
    expect(replay.chunks.count).to eq(1)
    expect(Replays::Read.call(session: replay).value.size).to eq(replay.events_count)

    list = Todos::List.find_by!(organization:, account: admin, name: "Codex test settimana")
    list.items.first.update!(done: true)
    page = Knowledge::Page.find_by!(organization:, publication_key: "codex-test-review-in_review")
    page.update!(body: "A human edited this page.", status: :published)
    counts = [ Todos::Item.count, Knowledge::Page.count, Chat::Message.count, Datasets::Row.count, Seo::Issue.count ]
    load_review_data

    expect([ Todos::Item.count, Knowledge::Page.count, Chat::Message.count, Datasets::Row.count, Seo::Issue.count ]).to eq(counts)
    expect(list.items.first.reload).to be_done
    expect(page.reload.body).to eq("A human edited this page.")
    expect(page).to be_status_published
    expect(metric.samples.count).to eq(3)
    expect(replay.chunks.count).to eq(1)
  end
end
