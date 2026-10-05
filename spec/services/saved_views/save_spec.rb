# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedViews::Save do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  it "crea una vista coi soli filtri ammessi dalla risorsa" do
    result = described_class.call(account: account, organization: organization, resource_type: "tickets",
                                  name: "Open mine", params: { "status_id" => [ "s1" ], "q" => "bug", "evil" => "x" })
    expect(result).to be_ok
    expect(result.value.resource_type).to eq("tickets")
    expect(result.value.filters.keys).to contain_exactly("status_id", "q")
  end

  it "aggiorna la vista esistente con lo stesso nome nella stessa risorsa (upsert)" do
    described_class.call(account: account, organization: organization, resource_type: "tickets",
                         name: "V", params: { "q" => "a" })
    expect do
      described_class.call(account: account, organization: organization, resource_type: "tickets",
                           name: "V", params: { "q" => "b" })
    end.not_to change(SavedView, :count)
    view = SavedView.for(account: account, organization: organization).for_resource("tickets").first
    expect(view.filters["q"]).to eq("b")
  end

  it "lo stesso nome su risorse diverse crea due viste distinte" do
    described_class.call(account: account, organization: organization, resource_type: "tickets",
                         name: "V", params: { "q" => "a" })
    expect do
      described_class.call(account: account, organization: organization, resource_type: "error_groups",
                           name: "V", params: { "q" => "b" })
    end.to change(SavedView, :count).by(1)
  end

  it "errore R422-SAVEDVIEW-001 su nome vuoto" do
    result = described_class.call(account: account, organization: organization, resource_type: "tickets",
                                  name: "  ", params: {})
    expect(result).to be_err
    expect(result.error.code).to eq("R422-SAVEDVIEW-001")
  end
end
