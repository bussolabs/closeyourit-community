# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Milestones::Save, type: :service do
  let(:project) { create(:project) }
  let(:actor) { create(:account) }

  def attrs(overrides = {})
    { code: "v1_0", label: "v1.0", color: "indigo", due_on: nil, active: true }.merge(overrides)
  end

  it "crea la milestone, imposta created_by e registra un evento 'created'" do
    milestone = project.milestones.new

    expect do
      result = described_class.call(milestone: milestone, attributes: attrs, actor: actor)
      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(result.value.created_by).to eq(actor)
    end.to change(Activity::Event, :count).by(1)

    event = milestone.activity_events.last
    expect(event.action).to eq("created")
    expect(event.organization_id).to eq(project.organization_id)
  end

  it "registra 'updated' coi campi cambiati su modifica" do
    milestone = described_class.call(milestone: project.milestones.new, attributes: attrs, actor: actor).value

    expect do
      described_class.call(milestone: milestone, attributes: attrs(label: "v1.1"), actor: actor)
    end.to change(Activity::Event, :count).by(1)

    event = milestone.activity_events.chronological.last
    expect(event.action).to eq("updated")
    expect(event.data["fields"]).to include("label")
  end

  it "NON registra eventi se non cambia nulla (niente rumore)" do
    milestone = described_class.call(milestone: project.milestones.new, attributes: attrs, actor: actor).value

    expect do
      described_class.call(milestone: milestone, attributes: attrs, actor: actor)
    end.not_to change(Activity::Event, :count)
  end

  it "validazione fallita → R422-MILESTONE-001, nessun evento orfano" do
    milestone = project.milestones.new

    expect do
      result = described_class.call(milestone: milestone, attributes: attrs(code: nil), actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-MILESTONE-001")
    end.not_to change(Activity::Event, :count)
  end
end
