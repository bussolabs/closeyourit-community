# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Pages::Reject do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :owner) }
  end

  def in_review_page
    create(:knowledge_page, :in_review, organization: organization, project: project)
  end

  it "scarta la pagina e registra chi ha deciso e quando" do
    page = in_review_page

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_ok
    expect(page.reload).to be_status_rejected
    expect(page.reviewed_by).to eq(owner)
    expect(page.reviewed_at).to be_present
  end

  it "non accoda alcun embedding: la pagina scartata resta fuori dalla ricerca" do
    page = in_review_page

    expect { described_class.call(page: page, actor: owner) }
      .not_to have_enqueued_job(Knowledge::EmbedPageJob)
  end

  it "tiene la pagina scartata: chi propone la ritrova e non la ripropone" do
    page = in_review_page

    expect { described_class.call(page: page, actor: owner) }.not_to change(Knowledge::Page, :count)
  end

  it "rifiuta una pagina che non è in revisione" do
    page = create(:knowledge_page, organization: organization, project: project)

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-009")
  end

  it "rifiuta chi non può gestire la pagina" do
    page = in_review_page
    estraneo = create(:account).tap do |account|
      create(:membership, account: account, organization: organization, role: :member)
    end

    result = described_class.call(page: page, actor: estraneo)

    expect(result).to be_err
    expect(result.error.code).to eq("R403-KNOWLEDGE-004")
    expect(page.reload).to be_status_in_review
  end

  # CYRA-642 — anche scartare è un gesto UMANO: una macchina che potesse bocciare le proposte
  # deciderebbe da sola cosa non entra nella conoscenza, e la coda si svuoterebbe senza che
  # nessuno l'abbia letta. Stesso guard di Approve, stesso codice.
  context "quando a decidere non è una persona" do
    it "rifiuta un account di servizio: la proposta resta in attesa" do
      page = in_review_page
      macchina = create(:account, :service).tap do |account|
        create(:membership, account: account, organization: organization, role: :owner)
      end

      result = described_class.call(page: page, actor: macchina)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-005")
      expect(result.error.status).to eq(:forbidden)
      expect(page.reload).to be_status_in_review
      expect(page.reviewed_by).to be_nil
      expect(page.reviewed_at).to be_nil
    end

    it "rifiuta anche la macchina che ha proposto la pagina" do
      macchina = create(:account, :service).tap do |account|
        create(:membership, account: account, organization: organization, role: :owner)
      end
      page = create(:knowledge_page, :in_review, organization: organization, project: project,
                                                 created_by: macchina)

      result = described_class.call(page: page, actor: macchina)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-005")
      expect(page.reload).to be_status_in_review
    end

    it "senza attore non decide nulla (fail-closed)" do
      page = in_review_page

      result = described_class.call(page: page, actor: nil)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-005")
      expect(page.reload).to be_status_in_review
    end
  end
end
