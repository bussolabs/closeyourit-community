# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Features::Save, type: :service do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization: organization) }
  let(:category) { create(:product_category, group: group, organization: organization) }
  # Owner: vede tutte le pagine dell'org (VisibleScope unscoped).
  let(:actor) do
    create(:account).tap do |account|
      create(:membership, account: account, organization: organization, role: :owner)
    end
  end

  def save(params, feature: nil)
    described_class.call(category: category, actor: actor, organization: organization,
                         params: params, feature: feature)
  end

  it "crea una funzionalità nella categoria" do
    result = save({ name: "2FA", description: "Secondo fattore" })

    expect(result).to be_ok
    expect(result.value.name).to eq("2FA")
    expect(result.value.category).to eq(category)
    expect(result.value.organization).to eq(organization)
    expect(result.value.created_by).to eq(actor)
  end

  it "collega la pagina della base di conoscenza" do
    page = create(:knowledge_page, organization: organization)

    result = save({ name: "2FA", knowledge_page_id: page.id })

    expect(result.value.knowledge_page).to eq(page)
  end

  it "rifiuta una pagina non visibile all'autore" do
    foreign = create(:knowledge_page, organization: create(:organization))

    result = save({ name: "2FA", knowledge_page_id: foreign.id })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PRODUCT-002")
  end

  it "non azzera il rimando alla KB quando il campo non viene inviato" do
    page = create(:knowledge_page, organization: organization)
    feature = save({ name: "2FA", knowledge_page_id: page.id }).value

    save({ name: "2FA rinominata" }, feature: feature)

    expect(feature.reload.knowledge_page).to eq(page)
  end

  it "azzera il rimando quando il campo arriva vuoto" do
    page = create(:knowledge_page, organization: organization)
    feature = save({ name: "2FA", knowledge_page_id: page.id }).value

    save({ name: "2FA", knowledge_page_id: "" }, feature: feature)

    expect(feature.reload.knowledge_page).to be_nil
  end

  it "rifiuta un nome duplicato nella stessa categoria" do
    save({ name: "2FA" })

    result = save({ name: "2fa" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PRODUCT-002")
  end
end
