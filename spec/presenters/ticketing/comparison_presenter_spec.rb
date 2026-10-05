# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ComparisonPresenter do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:existing) { create(:ticket, :plain_bug, organization: org, project: project, title: "Crash al login") }

  def draft(overrides = {})
    Ticketing::Ticket.new({ project_id: project.id, title: "Crash al login", kind: "bug",
                            description: existing.description }.merge(overrides))
  end

  it "marca changed=false sui campi identici e changed=true su quelli diversi" do
    rows = described_class.new(existing: existing, draft: draft(title: "Crash al login su iOS")).rows

    title_row = rows.find { |row| row.key == "title" }
    description_row = rows.find { |row| row.key == "description" }
    expect(title_row.changed).to be(true)
    expect(title_row.old_value).to eq("Crash al login")
    expect(title_row.new_value).to eq("Crash al login su iOS")
    expect(description_row.changed).to be(false)
  end

  it "omette i campi vuoti su entrambi i lati e mostra label umane per kind/status" do
    rows = described_class.new(existing: existing, draft: draft).rows

    # existing è :plain_bug (solo description) e il draft non ha scenari → riga scenari omessa.
    expect(rows.map(&:key)).not_to include("weight", "milestone", "scenarios", "conditions")
    status_row = rows.find { |row| row.key == "status" }
    expect(status_row.old_value).to eq(existing.status.label)
    expect(status_row.changed).to be(true) # il draft non ha status risolto
  end

  it "confronta gli scenari come testo (BodyText) e marca changed quando differiscono" do
    existing_scen = create(:ticket, :with_scenarios, scenarios_count: 1,
                                    organization: org, project: project, title: "T")
    building = draft(title: "T")
    building.scenarios.build(step_given: "contesto nuovo", step_when: "azione", step_then: "risultato")

    rows = described_class.new(existing: existing_scen, draft: building).rows
    scenarios_row = rows.find { |row| row.key == "scenarios" }
    expect(scenarios_row).to be_present
    expect(scenarios_row.changed).to be(true)
  end
end
