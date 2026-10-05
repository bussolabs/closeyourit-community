# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::RestoreVersion do
  include ActiveJob::TestHelper

  let(:page) { create(:knowledge_page, title: "Attuale", body: "Corpo due", kind: :note) }
  let(:actor) { create(:account) }
  let(:org) { page.project.organization }
  let!(:old_version) { create(:knowledge_version, page: page, organization: org, number: 1, title: "Vecchio", body: "Corpo uno", kind: :guide) }
  let!(:live_version) { create(:knowledge_version, page: page, organization: org, number: 2, title: "Attuale", body: "Corpo due", kind: :note) }

  def embed_jobs_count
    enqueued_jobs.count { |job| job["job_class"] == "Knowledge::EmbedPageJob" }
  end

  it "ripristina il contenuto della versione come nuova live e ri-embedda" do
    result = described_class.call(page: page, version: old_version, actor: actor)

    expect(result).to be_ok
    expect(page.reload.title).to eq("Vecchio")
    expect(page.body).to eq("Corpo uno")
    expect(page.kind).to eq("guide")
    expect(page.versions.maximum(:number)).to eq(3)
    expect(embed_jobs_count).to eq(1)
  end

  it "la nuova versione rispecchia il contenuto ripristinato e l'autore del ripristino" do
    described_class.call(page: page, version: old_version, actor: actor)

    restored = page.versions.chronological.last
    expect(restored.number).to eq(3)
    expect(restored.title).to eq("Vecchio")
    expect(restored.body).to eq("Corpo uno")
    expect(restored.created_by).to eq(actor)
  end

  it "ripristinare la versione già live è idempotente (nessuna nuova versione, nessun re-embed)" do
    result = described_class.call(page: page, version: live_version, actor: actor)

    expect(result).to be_ok
    expect(page.reload.versions.count).to eq(2)
    expect(embed_jobs_count).to eq(0)
  end

  # Uno snapshot può essere più lungo del tetto entrato in vigore dopo: il ripristino deve dare un
  # errore leggibile (la pagina live è corta, quindi il grandfathering non si applica), mai un 500.
  it "ripristinare una versione oltre il limite dà un errore pulito, non un'eccezione" do
    lungo = create(:knowledge_version, page: page, organization: org, number: 3,
                                       title: "Vecchio dossier", kind: :note,
                                       body: "x" * (Knowledge::Constants::BODY_MAX_CHARS + 1))

    result = described_class.call(page: page, version: lungo, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-002")
    expect(result.error.details[:body].first).to include(Knowledge::Constants::BODY_MAX_CHARS.to_s)
    expect(page.reload.body).to eq("Corpo due")
  end

  it "ripristina anche la sezione tecnica dello snapshot" do
    page.update!(tech_spec: "Tecnico corrente")
    snapshot = create(:knowledge_version, page: page, organization: org, number: 3,
                                          title: "Con tecnico", body: "Corpo tecnico", kind: :note,
                                          tech_spec: "Tecnico vecchio")

    result = described_class.call(page: page, version: snapshot, actor: actor)

    expect(result).to be_ok
    expect(page.reload.tech_spec).to eq("Tecnico vecchio")
    expect(page.title).to eq("Con tecnico")
    expect(page.versions.chronological.last.tech_spec).to eq("Tecnico vecchio")
  end
end
