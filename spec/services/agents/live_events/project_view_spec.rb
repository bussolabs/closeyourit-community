# frozen_string_literal: true

require "rails_helper"

# CYRA-1139 — every agent at work on one project, each with its colour, and the files two of them change.
RSpec.describe Agents::LiveEvents::ProjectView do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:project) { create(:project, organization:) }
  let(:at) { Time.utc(2026, 11, 2, 15) }

  def attempt_on(code_suffix, started_at:)
    ticket = create(:ticket, organization:, project:, title: "Ticket #{code_suffix}")
    workflow = ticket.agent_workflow || create(:agent_workflow, organization:, ticket:)
    create(:agent_attempt, workflow:, organization:, host:, phase: "autopilot", status: :running, started_at:)
  end

  def changed(attempt, seq, path, hunks: nil)
    Agents::AttemptLiveEvent.create!(organization:, attempt:, seq:, kind: "file_change", recorded_at: at + seq.seconds,
                                     created_at: Time.current,
                                     payload: { "path" => path, "created" => false, "added" => 1, "removed" => 1, "hunks" => hunks })
  end

  def hunk(old_start, old_lines) = { "old_start" => old_start, "old_lines" => old_lines, "new_start" => old_start, "new_lines" => old_lines, "lines" => [] }

  let(:first) { attempt_on("A", started_at: at) }
  let(:second) { attempt_on("B", started_at: at + 1.minute) }

  def view = described_class.new(attempts: [ first, second ])

  it "gives each agent a colour in the order it started, with its ticket as name" do
    agents = view.agents

    expect(agents.map(&:color)).to eq(%i[violet amber])
    expect(agents.map(&:name)).to eq([ first.workflow.ticket.code, second.workflow.ticket.code ])
  end

  it "marks a file red when two agents change the same lines" do
    changed(first, 1, "app/models/ticket.rb", hunks: [ hunk(10, 3) ])
    changed(second, 1, "app/models/ticket.rb", hunks: [ hunk(12, 2) ])

    conflict = view.conflicts.sole

    expect(conflict.path).to eq("app/models/ticket.rb")
    expect(conflict.level).to eq(:lines)
    expect(conflict.agents.map(&:attempt)).to eq([ first, second ])
  end

  it "marks a file red from the line numbers alone, when the project keeps the code on the machine (CYAU-299)" do
    changed(first, 1, "app/models/ticket.rb", hunks: [ hunk(10, 3) ])
    changed(second, 1, "app/models/ticket.rb", hunks: [ hunk(12, 2) ])

    expect(view.conflicts.sole.level).to eq(:lines)
    expect(view.agents.map { it.session.code? }).to eq([ false, false ])
  end

  it "marks a file yellow when two agents change it in different places" do
    changed(first, 1, "config/locales/it.yml", hunks: [ hunk(5, 2) ])
    changed(second, 1, "config/locales/it.yml", hunks: [ hunk(80, 4) ])

    expect(view.conflicts.sole.level).to eq(:file)
  end

  it "keeps the file yellow but says the lines are unknown when one side sent no line numbers" do
    changed(first, 1, "app/models/ticket.rb", hunks: [ hunk(10, 3) ])
    changed(second, 1, "app/models/ticket.rb")

    expect(view.conflicts.sole.level).to eq(:unknown)
  end

  it "lists red conflicts first and ignores files only one agent changed" do
    changed(first, 1, "config/locales/it.yml", hunks: [ hunk(5, 2) ])
    changed(second, 1, "config/locales/it.yml", hunks: [ hunk(80, 4) ])
    changed(first, 2, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])
    changed(second, 2, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])
    changed(first, 3, "app/models/user.rb", hunks: [ hunk(1, 1) ])

    expect(view.conflicts.map { [ it.path, it.level ] }).to eq([ [ "app/models/ticket.rb", :lines ], [ "config/locales/it.yml", :file ] ])
    expect(view.files.map(&:path)).to eq(%w[app/models/ticket.rb app/models/user.rb config/locales/it.yml])
    expect(view.file("app/models/user.rb").agents.map(&:attempt)).to eq([ first ])
  end

  it "gives the same colour to an attempt on every page, counted inside its own project" do
    other_project = create(:project, organization:)
    other_ticket = create(:ticket, organization:, project: other_project)
    workflow = other_ticket.agent_workflow || create(:agent_workflow, organization:, ticket: other_ticket)
    elsewhere = create(:agent_attempt, workflow:, organization:, host:, phase: "autopilot", status: :running, started_at: at - 1.hour)

    colors = described_class.colors([ second, elsewhere, first ])

    expect(colors).to eq(first.id => :violet, second.id => :amber, elsewhere.id => :violet)
  end

  it "keeps for one agent only the conflicts it is part of" do
    third = attempt_on("C", started_at: at + 2.minutes)
    changed(first, 1, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])
    changed(second, 1, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])
    changed(second, 2, "config/routes.rb", hunks: [ hunk(3, 1) ])
    changed(third, 1, "config/routes.rb", hunks: [ hunk(40, 1) ])
    view = described_class.new(attempts: [ first, second, third ])

    expect(view.conflicts_with(first).map(&:path)).to eq(%w[app/models/ticket.rb])
    expect(view.conflicts_with(second).map(&:path)).to eq(%w[app/models/ticket.rb config/routes.rb])
  end

  it "dates a conflict from the moment the second agent touched the file" do
    changed(first, 1, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])
    changed(second, 7, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])
    changed(first, 9, "app/models/ticket.rb", hunks: [ hunk(10, 1) ])

    expect(view.conflicts.sole.since).to eq(at + 7.seconds)
  end
end
