# frozen_string_literal: true

require "rails_helper"

RSpec.describe Search::Global do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization, name: "Apollo Control", key: "APOL") }
  let(:owner) { create(:account, name: "Olivia Owner") }

  before { create(:membership, account: owner, organization: organization, role: :owner) }

  def visible_for(account, permits_area: ->(_area) { true })
    Authorization::VisibleScope.new(account: account, organization: organization, permits_area: permits_area)
  end

  def search(query, viewer: owner, visible: visible_for(viewer), **options)
    described_class.call(query: query, visible: visible, viewer: viewer, organization: organization, **options)
  end

  def groups_for(query, **options) = search(query, **options).groups.index_by(&:key)

  def member_account(name)
    create(:account, name: name).tap do |account|
      create(:membership, account: account, organization: organization, role: :member)
    end
  end

  describe "the original four areas" do
    it "groups real results of projects, tickets, errors and knowledge pages" do
      ticket = create(:ticket, :plain_bug, organization: organization, project: project,
                                           title: "Apollo does not finish the deploy")
      error_group = create(:error_group, project: project, title: "Apollo::DeployError")
      page = create(:knowledge_page, project: project, organization: organization, title: "Apollo deploy runbook")

      groups = groups_for("Apollo")

      expect(groups.fetch(:projects).records).to contain_exactly(project)
      expect(groups.fetch(:tickets).records).to contain_exactly(ticket)
      expect(groups.fetch(:error_groups).records).to contain_exactly(error_group)
      expect(groups.fetch(:pages).records).to contain_exactly(page)
    end

    it "does not query anything for a query shorter than two characters" do
      found = search("a")

      expect(found.groups).to be_empty
      expect(found.kinds).to be_empty
    end

    it "treats percent and underscore as literal characters" do
      literal = create(:project, organization: organization, name: "Coverage 50%_real", key: "COVR")
      create(:project, organization: organization, name: "Coverage 500 real", key: "COV2")

      expect(groups_for("50%_").fetch(:projects).records).to contain_exactly(literal)
    end

    it "limits each group to five results and remembers how many there are" do
      create_list(:project, 7, organization: organization, name: "Apollo")

      group = groups_for("Apollo").fetch(:projects)

      expect(group.records.size).to eq(described_class::LIMIT_PER_GROUP)
      expect(group.total).to eq(7)
    end
  end

  describe "the new areas" do
    it "finds ideas, monitors, cron jobs, books, groups and teams by name" do
      idea = create(:idea, organization: organization, project: project, title: "Apollo dark mode")
      monitor = create(:uptime_monitor, project: project, name: "Apollo homepage")
      cron = create(:cron_monitor, project: project, name: "Apollo nightly digest")
      book = create(:knowledge_book, project: project, organization: organization, title: "Apollo handbook")
      group = create(:group, organization: organization, name: "Apollo customers")
      team = create(:team, organization: organization, name: "Apollo crew")
      create(:team_membership, team: team, account: owner)

      groups = groups_for("Apollo")

      expect(groups.fetch(:ideas).records).to contain_exactly(idea)
      expect(groups.fetch(:monitors).records).to contain_exactly(monitor)
      expect(groups.fetch(:cron_monitors).records).to contain_exactly(cron)
      expect(groups.fetch(:books).records).to contain_exactly(book)
      expect(groups.fetch(:groups).records).to contain_exactly(group)
      expect(groups.fetch(:teams).records).to contain_exactly(team)
    end

    it "shows servers only to whoever may see the servers area" do
      host = create(:server_host, organization: organization, name: "apollo-web-1")

      expect(groups_for("apollo").fetch(:servers).records).to contain_exactly(host)
      expect(groups_for("apollo", visible: visible_for(owner, permits_area: ->(_area) { false }))).not_to have_key(:servers)
    end

    it "finds secret names of visible projects and never their values" do
      create(:secret_variable, project: project, name: "APOLLO_DATABASE_URL", value: "postgres://hidden")

      secret = groups_for("APOLLO_DATA").fetch(:secrets).records.first

      expect(secret.name).to eq("APOLLO_DATABASE_URL")
      expect(secret.projects).to eq(1)
      expect(secret.to_h.values.map(&:to_s).join).not_to include("hidden")
    end

    it "matches the menu entries it is given" do
      entries = [ described_class::NavEntry.new(label: "Uptime · Observability", path: "/member/monitoring/monitors", icon: "signal"),
                  described_class::NavEntry.new(label: "Tickets", path: "/member/tickets", icon: "ticket") ]

      expect(groups_for("upt", nav_items: entries).fetch(:nav).records.map(&:label)).to eq([ "Uptime · Observability" ])
    end
  end

  describe "people" do
    it "shows the owner every member of the organization, never the owner themselves" do
      ada = member_account("Ada Apollo")

      people = groups_for("Apollo").fetch(:people).records

      expect(people).to contain_exactly(ada)
    end

    it "shows a member only the people they share a project with" do
      viewer = member_account("Vera Viewer")
      mate = member_account("Mia Apollo")
      stranger = member_account("Stan Apollo")
      [ viewer, mate ].each { |account| create(:project_membership, account: account, project: project) }

      people = groups_for("Apollo", viewer: viewer).fetch(:people).records

      expect(people).to contain_exactly(mate)
      expect(people).not_to include(stranger)
    end
  end

  describe "conversations" do
    it "finds the viewer's direct chats by the other person's name and project channels by project name" do
      partner = member_account("Paula Apollo")
      direct = create(:chat_conversation, :direct, organization: organization)
      [ owner, partner ].each { |account| create(:chat_participant, conversation: direct, account: account, organization: organization) }
      channel = create(:chat_conversation, organization: organization, contextable: project)

      expect(groups_for("Apollo").fetch(:conversations).records).to contain_exactly(direct, channel)
    end

    it "never finds a direct chat between two other people" do
      first = member_account("Fred Apollo")
      second = member_account("Sara Apollo")
      direct = create(:chat_conversation, :direct, organization: organization)
      [ first, second ].each { |account| create(:chat_participant, conversation: direct, account: account, organization: organization) }

      conversations = groups_for("Apollo").fetch(:conversations, nil)&.records || []

      expect(conversations).not_to include(direct)
    end
  end

  describe "exact codes" do
    it "puts an exactly matching ticket code first, in the first group" do
      ticket = create(:ticket, organization: organization, project: project, number: 42, title: "Unrelated title")
      create(:knowledge_page, project: project, organization: organization, title: "Notes on APOL-42")

      found = search("APOL-42")

      expect(found.groups.first.key).to eq(:tickets)
      expect(found.groups.first.records.first).to eq(ticket)
    end
  end

  it "keeps the exact ticket first even when five newer tickets mention its code" do
    exact = create(:ticket, organization: organization, project: project, number: 42, title: "Unrelated title",
                            updated_at: 2.days.ago)
    create_list(:ticket, 5, organization: organization, project: project, title: "Follow-up of APOL-42")

    found = search("APOL-42")
    filtered = search("APOL-42", type: "tickets")

    expect(found.groups.first.records.first).to eq(exact)
    expect(filtered.groups.first.records.first).to eq(exact)
  end

  describe "type filter" do
    it "keeps every kind with results as a filter and shows only the chosen one, with more rows" do
      create_list(:project, 7, organization: organization, name: "Apollo")
      create(:error_group, project: project, title: "Apollo::Timeout")

      found = search("Apollo", type: "projects")

      expect(found.kinds).to include(:projects, :error_groups)
      expect(found.groups.map(&:key)).to eq([ :projects ])
      expect(found.groups.first.records.size).to eq(8)
    end

    it "ignores an unknown type" do
      project
      found = search("Apollo Control", type: "passwords")

      expect(found.groups.map(&:key)).to include(:projects)
    end
  end
end
