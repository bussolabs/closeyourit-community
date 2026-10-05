# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Pages::ConfirmReview do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: organization, role: :owner) }
  end

  def scaduta(kind: :decision)
    create(:knowledge_page, kind: kind, organization: organization, project: project)
      .tap { |page| page.update_columns(review_after: 1.day.ago) }
  end

  it "fa ripartire il conto dalla finestra del tipo" do
    page = scaduta

    freeze_time do
      result = described_class.call(page: page, actor: owner)

      expect(result).to be_ok
      expect(page.reload.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :decision))
      expect(page).not_to be_needs_review
    end
  end

  it "usa la finestra della guida quando la pagina è una guida" do
    page = scaduta(kind: :guide)

    freeze_time do
      described_class.call(page: page, actor: owner)

      expect(page.reload.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :guide))
    end
  end

  # La risposta del cliente su CYRA-768: dire «è ancora vero» è un giudizio, e una macchina che si
  # autoconferma svuoterebbe di senso la scadenza.
  it "non lascia confermare a un accesso automatico" do
    page = scaduta
    service_account = create(:account, :service).tap do |account|
      create(:membership, account: account, organization: organization, role: :owner)
    end

    result = described_class.call(page: page, actor: service_account)

    expect(result).to be_err
    expect(result.error.code).to eq("R403-KNOWLEDGE-005")
    expect(page.reload).to be_needs_review
  end

  it "rifiuta chi non può gestire la pagina" do
    page = scaduta
    estraneo = create(:account).tap do |account|
      create(:membership, account: account, organization: organization, role: :member)
    end

    result = described_class.call(page: page, actor: estraneo)

    expect(result).to be_err
    expect(result.error.code).to eq("R403-KNOWLEDGE-004")
    expect(page.reload).to be_needs_review
  end

  it "rifiuta una pagina che non è ancora stata accettata" do
    page = create(:knowledge_page, :in_review, :decision, organization: organization, project: project)

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-009")
  end

  it "rifiuta una pagina che non è ancora arrivata alla data di rilettura" do
    page = create(:knowledge_page, :decision, organization: organization, project: project)
    page.update_columns(review_after: 30.days.from_now)

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-009")
  end

  # Una nota non scade: confermarla non ha niente da far ripartire, e non deve inventarle una data.
  it "rifiuta una pagina senza data di rilettura" do
    page = create(:knowledge_page, organization: organization, project: project)

    result = described_class.call(page: page, actor: owner)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-009")
    expect(page.reload.review_after).to be_nil
  end

  # Confermare non è modificare: la pagina non deve risalire in cima agli elenchi (ordinati per
  # `updated_at`) come se qualcuno ne avesse riscritto il testo.
  it "non fa risultare la pagina aggiornata" do
    page = scaduta

    expect { described_class.call(page: page, actor: owner) }.not_to change { page.reload.updated_at }
  end

  it "non tocca il testo né lo stato di accettazione" do
    page = scaduta

    expect { described_class.call(page: page, actor: owner) }
      .not_to change { page.reload.slice("title", "body", "status", "reviewed_at", "consolidated_at") }
  end
end
