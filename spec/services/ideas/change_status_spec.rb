# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::ChangeStatus, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  it "archivia un'idea aperta" do
    idea = create(:idea, organization:, project:)

    result = described_class.call(idea:, to: :archived)

    expect(result).to be_ok
    expect(idea.reload).to be_status_archived
  end

  it "registra un evento 'updated' con fields:['status']" do
    idea = create(:idea, organization:, project:)
    actor = idea.author

    expect do
      result = described_class.call(idea:, to: :archived, actor:)
      expect(result).to be_ok
    end.to change(Activity::Event, :count).by(1)

    event = idea.activity_events.chronological.last
    expect(event.action).to eq("updated")
    expect(event.data["fields"]).to eq([ "status" ])
    expect(event.actor).to eq(actor)
  end

  it "riapre un'idea archiviata" do
    idea = create(:idea, :archived, organization:, project:)

    result = described_class.call(idea:, to: :open)

    expect(result).to be_ok
    expect(idea.reload).to be_status_open
  end

  it "transizione non valida (open → open) → R422-IDEA-002" do
    idea = create(:idea, organization:, project:)

    result = described_class.call(idea:, to: :open)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
  end

  it "converted è terminale → R422-IDEA-003 in entrambe le direzioni" do
    idea = create(:idea, :converted, organization:, project:)

    %i[open archived].each do |to|
      result = described_class.call(idea:, to:)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-IDEA-003")
    end
    expect(idea.reload).to be_status_converted
  end

  it "non permette di raggiungere converted manualmente → R422-IDEA-002" do
    idea = create(:idea, organization:, project:)

    result = described_class.call(idea:, to: :converted)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
    expect(idea.reload).to be_status_open
  end
end
