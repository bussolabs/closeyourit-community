require "rails_helper"

RSpec.describe Current, type: :model do
  after { described_class.reset }

  it "espone account e organization come attributi del contesto" do
    account = build(:account)
    org = build(:organization)

    described_class.account = account
    described_class.organization = org

    expect(described_class.account).to eq(account)
    expect(described_class.organization).to eq(org)
  end
end
