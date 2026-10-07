# frozen_string_literal: true

require "rails_helper"

# The read tools that cover the rest of a project: errors, slow operations, logs, monitors,
# releases and ideas. The point of every example is the boundary first, the shape second.
RSpec.describe "Assistant::Tools project reads" do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:project) { create(:project, organization: organization, key: "CYRA", name: "closeyourit-rails") }
  let(:hidden) { create(:project, organization: organization, key: "SEGR", name: "reserved") }
  let(:context) do
    Assistant::Tools::Context.new(account: account, organization: organization,
                                  project_ids: [ project.id ], group_ids: [], full_access: false)
  end

  def run(name, args = {})
    Assistant::Tools::Registry.run(name: name, args: args, context: context)
  end

  %w[list_errors list_performance search_logs list_monitors list_releases list_ideas].each do |tool|
    it "#{tool} refuses a project outside the scope" do
      hidden

      expect(run(tool, "project" => "SEGR")[:error]).to include("No visible project matches SEGR").and include("ask which one")
    end
  end

  describe "list_errors" do
    it "lists the unresolved errors of the project, newest first" do
      create(:error_group, project: project, title: "Old", last_seen_at: 2.days.ago, events_count: 3)
      create(:error_group, project: project, title: "Fresh", last_seen_at: 1.hour.ago, events_count: 7)
      create(:error_group, :resolved, project: project, title: "Fixed")
      create(:error_group, project: hidden, title: "Not mine")

      result = run("list_errors", "project" => "CYRA")

      expect(result[:total]).to eq(2)
      expect(result[:errors].pluck(:title)).to eq(%w[Fresh Old])
      expect(result[:errors].first).to include(events: 7, level: "error")
    end

    it "lists the resolved ones when asked" do
      create(:error_group, project: project, title: "Open")
      create(:error_group, :resolved, project: project, title: "Fixed")

      expect(run("list_errors", "project" => "CYRA", "status" => "resolved")[:errors].pluck(:title)).to eq(%w[Fixed])
    end

    it "names the ticket an error was promoted to" do
      ticket = create(:ticket, project: project, organization: organization)
      create(:error_group, project: project, ticket: ticket)

      expect(run("list_errors", "project" => "CYRA")[:errors].first[:ticket]).to eq(ticket.code)
    end
  end

  describe "list_performance" do
    it "lists the unresolved slow operations, the costliest first, with their average" do
      create(:metric_group, :slow_method, project: project, title: "Cheap#call",
                                          samples_count: 2, duration_total_ms: 200.0)
      create(:metric_group, :slow_method, project: project, title: "Costly#call",
                                          samples_count: 10, duration_total_ms: 9000.0)
      create(:metric_group, :slow_method, project: project, title: "Done#call", status: :resolved)

      result = run("list_performance", "project" => "CYRA")

      expect(result[:total]).to eq(2)
      expect(result[:operations].pluck(:title)).to eq(%w[Costly#call Cheap#call])
      expect(result[:operations].first).to include(average_ms: 900, samples: 10)
    end
  end

  describe "search_logs" do
    it "returns the recent lines of the project with a count per level" do
      create(:log_entry, project: project, level: :info, message: "started")
      create(:log_entry, project: project, level: :error, message: "payment failed")
      create(:log_entry, project: project, level: :error, message: "too old", occurred_at: 3.days.ago)
      create(:log_entry, project: hidden, level: :error, message: "not mine")

      result = run("search_logs", "project" => "CYRA")

      expect(result[:total]).to eq(2)
      expect(result[:by_level]).to eq("info" => 1, "error" => 1)
      expect(result[:logs].pluck(:message)).to contain_exactly("started", "payment failed")
    end

    it "keeps only the lines from a level up" do
      create(:log_entry, project: project, level: :info, message: "started")
      create(:log_entry, project: project, level: :warning, message: "slow")
      create(:log_entry, project: project, level: :fatal, message: "crashed")

      result = run("search_logs", "project" => "CYRA", "level" => "warning")

      expect(result[:logs].pluck(:message)).to contain_exactly("slow", "crashed")
    end

    it "keeps only the lines that contain the text" do
      create(:log_entry, project: project, message: "payment failed for order 12")
      create(:log_entry, project: project, message: "user signed in")

      expect(run("search_logs", "project" => "CYRA", "query" => "PAYMENT")[:logs].pluck(:message))
        .to eq([ "payment failed for order 12" ])
    end

    it "widens the window when asked, up to the cap" do
      create(:log_entry, project: project, message: "three days ago", occurred_at: 3.days.ago)

      expect(run("search_logs", "project" => "CYRA", "hours" => 96)[:total]).to eq(1)
      expect(run("search_logs", "project" => "CYRA", "hours" => 99_999)[:hours]).to eq(336)
    end

    it "cuts a long line" do
      create(:log_entry, project: project, message: "x" * 2_000)

      expect(run("search_logs", "project" => "CYRA")[:logs].first[:message].size).to be <= 300
    end
  end

  describe "list_monitors" do
    it "says which monitors are up or down, their uptime and since when one is down" do
      up = create(:uptime_monitor, project: project, name: "API", current_status: :up)
      down = create(:uptime_monitor, project: project, name: "Web", current_status: :down)
      create(:uptime_check, monitor: up, checked_at: 1.hour.ago)
      create(:uptime_incident, monitor: down, started_at: 30.minutes.ago)

      result = run("list_monitors", "project" => "CYRA")

      expect(result[:total]).to eq(2)
      api, web = result[:monitors]
      expect(api).to include(name: "API", status: "up", uptime_24h: 100.0)
      expect(web).to include(name: "Web", status: "down")
      expect(web[:down_since]).to be_present
      expect(api[:down_since]).to be_nil
    end
  end

  describe "list_releases" do
    it "lists the releases newest first and marks the live one" do
      create(:release, project: project, version: "v1.0.0", created_at: 2.days.ago)
      create(:release, project: project, version: "v1.1.0", current: true, created_at: 1.hour.ago)
      create(:release, project: hidden, version: "v9.9.9")

      result = run("list_releases", "project" => "CYRA")

      expect(result[:releases].pluck(:version)).to eq(%w[v1.1.0 v1.0.0])
      expect(result[:releases].first).to include(environment: "production", live: true)
    end
  end

  describe "list_ideas" do
    it "lists the open ideas of the project with their votes" do
      create(:idea, organization: organization, project: project, title: "Dark mode", votes_count: 4)
      create(:idea, :archived, organization: organization, project: project, title: "Dropped")
      create(:idea, organization: organization, project: hidden, title: "Not mine")

      result = run("list_ideas", "project" => "CYRA")

      expect(result[:total]).to eq(1)
      expect(result[:ideas].first).to include(title: "Dark mode", votes: 4, status: "open")
    end

    it "lists the archived ones when asked" do
      create(:idea, :archived, organization: organization, project: project, title: "Dropped")

      expect(run("list_ideas", "project" => "CYRA", "status" => "archived")[:ideas].pluck(:title)).to eq(%w[Dropped])
    end
  end
end
