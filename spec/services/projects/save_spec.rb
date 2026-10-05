# frozen_string_literal: true

require "rails_helper"

# Focus: emissione dell'activity-log generalizzato (created/updated) in modo atomico.
RSpec.describe Projects::Save, type: :service do
  let(:org) { create(:organization) }
  let(:actor) { create(:account) }

  it "gives the creator visibility only on the newly created project" do
    create(:membership, account: actor, organization: org, role: :member)
    other = create(:project, organization: org)
    project = org.projects.new
    result = described_class.call(project:, organization: org, attributes: { name: "Review project", key: "REV" }, actor:)
    expect(result).to be_ok
    visible = Authorization::VisibleScope.new(account: actor, organization: org)
    expect(visible.projects).to include(project)
    expect(visible.projects).not_to include(other)
    expect(Authorization::Resolver.new(account: actor, organization: org).can?("projects.delete", scope: project)).to be(false)
  end

  it "does not grant access when creation fails" do
    create(:membership, account: actor, organization: org, role: :member)
    expect do
      result = described_class.call(project: org.projects.new, organization: org, attributes: { name: "", key: "REV" }, actor:)
      expect(result).to be_err
    end.not_to change(Connections::ProjectMembership, :count)
  end

  it "registra un evento 'created' alla creazione" do
    project = org.projects.new

    expect do
      result = described_class.call(project:, organization: org, attributes: { name: "Storefront", key: "STOR" }, actor:)
      expect(result).to be_ok
    end.to change(Activity::Event, :count).by(1)

    event = project.activity_events.last
    expect(event.action).to eq("created")
    expect(event.actor).to eq(actor)
  end

  it "registra 'updated' coi campi cambiati su modifica" do
    project = create(:project, organization: org)

    expect do
      described_class.call(project:, organization: org, attributes: { name: "Rinominato" }, actor:)
    end.to change(Activity::Event, :count).by(1)

    event = project.activity_events.chronological.last
    expect(event.action).to eq("updated")
    expect(event.data["fields"]).to include("name")
  end

  it "NON registra eventi se non cambia nulla (niente rumore)" do
    project = create(:project, organization: org, name: "Invariato")

    expect do
      described_class.call(project:, organization: org, attributes: { name: "Invariato" }, actor:)
    end.not_to change(Activity::Event, :count)
  end

  it "è atomico: salvataggio fallito → nessun evento orfano" do
    project = create(:project, organization: org)

    expect do
      result = described_class.call(project:, organization: org, attributes: { name: "" }, actor:)
      expect(result).to be_err
    end.not_to change(Activity::Event, :count)
  end
end
