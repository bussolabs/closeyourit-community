# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Pages::MarkConsolidated do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :owner) }
  end

  def published_page
    create(:knowledge_page, organization: organization, project: project)
  end

  it "registra il percorso del documento e la data" do
    page = published_page

    result = described_class.call(page: page, actor: owner, source_path: "troubleshooting/rails.md")

    expect(result).to be_ok
    expect(page.reload.source_path).to eq("troubleshooting/rails.md")
    expect(page.consolidated_at).to be_present
  end

  it "toglie la pagina dall'elenco di quelle ancora da scrivere" do
    page = published_page

    described_class.call(page: page, actor: owner, source_path: "global/git.md")

    expect(Knowledge::Page.awaiting_consolidation.pluck(:id)).not_to include(page.id)
  end

  it "aggiorna il percorso di una pagina già consolidata (il documento si può spostare)" do
    page = create(:knowledge_page, organization: organization, project: project,
                                   consolidated_at: 1.day.ago, source_path: "global/vecchio.md")

    described_class.call(page: page, actor: owner, source_path: "global/nuovo.md")

    expect(page.reload.source_path).to eq("global/nuovo.md")
  end

  it "rifiuta un percorso vuoto" do
    page = published_page

    result = described_class.call(page: page, actor: owner, source_path: "  ")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-010")
  end

  it "rifiuta una pagina non ancora accettata" do
    page = create(:knowledge_page, :in_review, organization: organization, project: project)

    result = described_class.call(page: page, actor: owner, source_path: "global/git.md")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-009")
  end

  it "rifiuta chi non può gestire la pagina" do
    page = published_page
    estraneo = create(:account).tap do |account|
      create(:membership, account: account, organization: organization, role: :member)
    end

    result = described_class.call(page: page, actor: estraneo, source_path: "global/git.md")

    expect(result).to be_err
    expect(result.error.code).to eq("R403-KNOWLEDGE-004")
    expect(page.reload.consolidated_at).to be_nil
  end

  # CYRA-642 — i tre passaggi restano distinti: accettare e scartare sono decisioni umane (guard in
  # Approve/Reject), segnare come scritta su file è invece un passo MECCANICO — lo fa la stessa
  # automazione che archivia il documento nel repo. Metterci il guard umano bloccherebbe il flusso
  # che questo passaggio esiste per servire.
  it "lascia consolidare a un account di servizio: archiviare non è decidere" do
    page = published_page
    macchina = create(:account, :service).tap do |account|
      create(:membership, account: account, organization: organization, role: :owner)
    end

    result = described_class.call(page: page, actor: macchina, source_path: "global/git.md")

    expect(result).to be_ok
    expect(page.reload.source_path).to eq("global/git.md")
    expect(page.consolidated_at).to be_present
  end
end
