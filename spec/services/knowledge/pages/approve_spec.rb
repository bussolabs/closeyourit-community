# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Pages::Approve do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :owner) }
  end

  def in_review_page
    create(:knowledge_page, :in_review, organization: organization, project: project)
  end

  # CYRA-764 — una pagina bocciata dal revisore automatico non si ripubblica così com'è.
  it "rifiuta di accettare una pagina bocciata dal revisore automatico finché non viene corretta" do
    page = in_review_page
    page.update_columns(ai_review_verdict: Knowledge::Page.ai_review_verdicts[:rejected], ai_reviewed_at: Time.current)

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-009")
    expect(page.reload).to be_status_in_review
  end

  # CYRA-768 — accettare è il momento in cui la pagina diventa vera: da lì parte il conto.
  it "mette la data di rilettura coerente col tipo della pagina" do
    page = create(:knowledge_page, :in_review, :decision, organization: organization, project: project)

    freeze_time do
      described_class.call(page: page, actor: owner)

      expect(page.reload.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :decision))
    end
  end

  it "non mette nessuna scadenza a una nota" do
    page = in_review_page

    described_class.call(page: page, actor: owner)

    expect(page.reload.review_after).to be_nil
  end

  it "pubblica la pagina e registra chi ha deciso e quando" do
    page = in_review_page

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_ok
    expect(page.reload).to be_status_published
    expect(page.reviewed_by).to eq(owner)
    expect(page.reviewed_at).to be_present
  end

  it "accoda l'embedding solo ora: le proposte non consumano il servizio" do
    page = in_review_page

    expect { described_class.call(page: page, actor: owner) }
      .to have_enqueued_job(Knowledge::EmbedPageJob).with(page_id: page.id)
  end

  it "lascia la pagina fuori dal consolidamento fatto: va ancora scritta su file" do
    page = in_review_page

    described_class.call(page: page, actor: owner)

    expect(page.reload.consolidated_at).to be_nil
    expect(Knowledge::Page.awaiting_consolidation.pluck(:id)).to include(page.id)
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

  # CYRA-642 — accettare è un gesto UMANO. Il guard non è nel controller ma qui perché i canali che
  # decidono sono due (pagina di revisione nel web, `cyi kb approve` dal terminale) e il canale CLI è
  # l'unico da cui un account di servizio può presentarsi davvero: non fa login web, ma il suo token
  # si autentica come quello di una persona.
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

    it "non accoda l'embedding della proposta che una macchina ha provato ad accettare" do
      page = in_review_page
      macchina = create(:account, :service).tap do |account|
        create(:membership, account: account, organization: organization, role: :owner)
      end

      expect { described_class.call(page: page, actor: macchina) }
        .not_to have_enqueued_job(Knowledge::EmbedPageJob)
    end

    it "rifiuta anche la macchina che ha proposto la pagina: l'autore non si autoapprova" do
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
