# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::IngestPayload, type: :model do
  it "appartiene a un progetto e conserva il payload jsonb" do
    project = create(:project)
    staged = described_class.create!(project: project, payload: { "event_id" => "e1", "a" => 1 })

    expect(staged.reload.payload).to eq("event_id" => "e1", "a" => 1)
    expect(staged.project).to eq(project)
  end

  it "richiede un progetto" do
    expect { described_class.create!(payload: {}) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
