# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Review::Normalize, knowledge_review: true do
  include ActiveJob::TestHelper

  let(:page) { create(:knowledge_page, title: "Acme Flutter — la lista sparisce", body: "## Sintomo\n`boom`", tags: []) }

  it "scrive la riga del formato in testa e i due tag, con versione e re-embed" do
    expect { described_class.call(page:, format: "troubleshooting") }.to have_enqueued_job(Knowledge::EmbedPageJob)
    page.reload
    expect(page.body).to start_with("Formato: troubleshooting\n\n## Sintomo")
    expect(page.tags).to eq(%w[acme-flutter troubleshooting])
    expect(page.versions.count).to eq(1)
    expect(page.ai_reviewed_at).to eq(page.updated_at)
    expect(Knowledge::Review::Precheck.format_of(page.body)).to eq("troubleshooting")
  end

  it "usa l'etichetta italiana del formato" do
    described_class.call(page:, format: "test_access")
    expect(page.reload.body).to start_with("Formato: accessi di test\n")
    expect(page.tags).to include("test-access")
  end

  it "non tocca ciò che c'è già: riga presente e tag sufficienti" do
    page.update_columns(body: "Formato: decisione\n\nx", tags: %w[rails adr])
    expect { described_class.call(page:, format: "decision") }.not_to have_enqueued_job(Knowledge::EmbedPageJob)
    expect(page.reload.versions.count).to eq(0)
    expect(page.tags).to eq(%w[rails adr])
  end

  it "con un tag solo ne aggiunge uno, l'area dal titolo" do
    page.update_columns(tags: %w[flutter])
    described_class.call(page:, format: "troubleshooting")
    expect(page.reload.tags).to eq(%w[flutter acme-flutter])
  end

  it "senza area nel titolo mette il formato" do
    page.update_columns(title: "una pagina senza prefisso")
    described_class.call(page:, format: "reference")
    expect(page.reload.tags).to eq(%w[reference])
  end

  it "un formato sconosciuto non scrive niente" do
    expect(described_class.call(page:, format: "unknown")).to be_ok
    expect(page.reload.body).not_to include("Formato:")
  end
end
