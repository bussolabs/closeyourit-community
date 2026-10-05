# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Document, type: :model do
  describe "factory" do
    it "produce un documento valido" do
      expect(build(:document)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede title" do
      expect(build(:document, title: nil)).not_to be_valid
      expect(build(:document, title: "   ")).not_to be_valid
    end

    it "richiede il file allegato" do
      document = described_class.new(project: create(:project), title: "Senza file")
      expect(document).not_to be_valid
      expect(document.errors[:file]).to be_present
    end

    it "rifiuta file oltre DOCUMENT_MAX_SIZE" do
      stub_const("App::Constants::DOCUMENT_MAX_SIZE", 1.kilobyte)
      document = build(:document)
      document.file.attach(io: StringIO.new("x" * 2.kilobytes), filename: "big.pdf",
                           content_type: "application/pdf")
      expect(document).not_to be_valid
      expect(document.errors.details[:file]).to include(a_hash_including(error: :too_large))
    end

    it "rifiuta content-type fuori allowlist" do
      document = build(:document)
      document.file.attach(io: StringIO.new("<svg/>"), filename: "img.svg",
                           content_type: "image/svg+xml")
      expect(document).not_to be_valid
      expect(document.errors.details[:file]).to include(a_hash_including(error: :invalid_type))
    end
  end

  describe "normalizzazioni" do
    it "title e description: strip" do
      document = create(:document, title: "  Contratto 2026  ", description: "  nota  ")
      expect(document.title).to eq("Contratto 2026")
      expect(document.description).to eq("nota")
    end

    it "tags: strip + downcase + uniq + scarto blank (array vuoto valido)" do
      document = create(:document, tags: [ " Legal ", "legal", "", "  ", "Q3" ])
      expect(document.tags).to eq(%w[legal q3])
      expect(build(:document, tags: [])).to be_valid
    end
  end

  describe "#organization_id" do
    it "delega al progetto (radice di tenancy)" do
      project = create(:project)
      document = create(:document, project: project)
      expect(document.organization_id).to eq(project.organization_id)
    end
  end

  describe ".allowed_file?" do
    it "true per tipo in allowlist e dimensione nel limite, false altrimenti" do
      expect(described_class.allowed_file?(content_type: "application/pdf", byte_size: 1.kilobyte)).to be(true)
      expect(described_class.allowed_file?(content_type: "text/html", byte_size: 1.kilobyte)).to be(false)
      expect(described_class.allowed_file?(content_type: "application/pdf",
                                           byte_size: App::Constants::DOCUMENT_MAX_SIZE + 1)).to be(false)
    end
  end

  describe "scope" do
    let(:project) { create(:project) }

    it ".ordered: più recente prima" do
      old = create(:document, project: project, created_at: 2.days.ago)
      recent = create(:document, project: project, created_at: 1.hour.ago)
      expect(project.documents.ordered.to_a).to eq([ recent, old ])
    end

    it ".tagged_any: overlap (OR) sui tag, nessun match → vuoto" do
      legal = create(:document, project: project, tags: %w[legal q3])
      spec = create(:document, project: project, tags: %w[spec])
      expect(project.documents.tagged_any(%w[legal missing])).to contain_exactly(legal)
      expect(project.documents.tagged_any(%w[legal spec])).to contain_exactly(legal, spec)
      expect(project.documents.tagged_any(%w[missing])).to be_empty
    end

    it ".search: match su title O filename originale (documento rinominato ritrovabile)" do
      document = create(:document, project: project, title: "Spec pagamenti")
      document.update!(title: "Rinominato")
      expect(project.documents.search("spec")).to contain_exactly(document) # filename spec.pdf
      expect(project.documents.search("rinominat")).to contain_exactly(document)
      expect(project.documents.search("assente")).to be_empty
    end
  end

  describe ".distinct_tags" do
    it "unione ordinata dei tag dello scope" do
      project = create(:project)
      create(:document, project: project, tags: %w[legal q3])
      create(:document, project: project, tags: %w[legal spec])
      create(:document, tags: %w[altro_progetto])
      expect(described_class.distinct_tags(project.documents)).to eq(%w[legal q3 spec])
    end
  end

  describe "relazioni" do
    it "destroy del progetto cancella i documenti" do
      document = create(:document)
      expect { document.project.destroy! }.to change(described_class, :count).by(-1)
    end

    it "created_by → nullify alla cancellazione account" do
      account = create(:account)
      document = create(:document, created_by: account)
      account.destroy!
      expect(document.reload.created_by).to be_nil
    end
  end
end
