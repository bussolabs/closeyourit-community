# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activity::Record, type: :service do
  let(:project) { create(:project) }
  let(:actor) { create(:account) }

  it "crea un evento con org del subject e actor_name snapshottato" do
    event = described_class.call(subject: project, action: "created", actor: actor)

    expect(event).to be_persisted
    expect(event.subject).to eq(project)
    expect(event.organization_id).to eq(project.organization_id)
    expect(event.actor).to eq(actor)
    expect(event.actor_name).to eq(actor.name)
    expect(event.action).to eq("created")
  end

  it "stringifica le chiavi di data" do
    event = described_class.call(subject: project, action: "updated", data: { fields: %w[name key] })

    expect(event.data).to eq("fields" => %w[name key])
  end

  it "registra true_actor per l'impersonation" do
    god = create(:account)
    event = described_class.call(subject: project, action: "created", actor: actor, true_actor: god)

    expect(event).to be_impersonated
  end
end
