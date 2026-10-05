# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Categories::Save, type: :service do
  let(:group) { create(:group) }
  let(:actor) { create(:account) }

  it "crea una categoria nel prodotto" do
    result = described_class.call(group: group, actor: actor, params: { name: "Auth" })

    expect(result).to be_ok
    expect(result.value.name).to eq("Auth")
    expect(result.value.group).to eq(group)
    expect(result.value.organization).to eq(group.organization)
    expect(result.value.created_by).to eq(actor)
  end

  it "aggiorna una categoria esistente senza cambiarne l'autore" do
    category = create(:product_category, group: group, organization: group.organization, created_by: actor)

    result = described_class.call(group: group, actor: create(:account), params: { name: "Accesso" },
                                  category: category)

    expect(result.value.reload.name).to eq("Accesso")
    expect(result.value.created_by).to eq(actor)
  end

  it "rifiuta un nome vuoto" do
    result = described_class.call(group: group, actor: actor, params: { name: " " })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PRODUCT-001")
  end

  it "rifiuta un nome già usato nello stesso prodotto" do
    create(:product_category, group: group, organization: group.organization, name: "Auth")

    result = described_class.call(group: group, actor: actor, params: { name: "Auth" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PRODUCT-001")
  end
end
