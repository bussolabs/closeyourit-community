# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::BackfillVersionsJob do
  it "crea la versione 1 per le pagine senza cronologia" do
    page = create(:knowledge_page, title: "Titolo", body: "Corpo", kind: :guide)

    expect { described_class.perform_now }.to change { page.versions.count }.by(1)

    version = page.versions.first
    expect(version.number).to eq(1)
    expect(version.title).to eq("Titolo")
    expect(version.body).to eq("Corpo")
    expect(version.kind).to eq("guide")
    expect(version.created_by).to eq(page.created_by)
    expect(version.author_name).to eq(page.created_by.name)
    expect(version.organization).to eq(page.project.organization)
    expect(version.created_at).to be_within(1.second).of(page.updated_at)
  end

  it "è idempotente: non duplica se la pagina ha già versioni" do
    page = create(:knowledge_page)
    create(:knowledge_version, page: page, organization: page.project.organization, number: 1)

    expect { described_class.perform_now }.not_to change(Knowledge::Version, :count)
  end
end
