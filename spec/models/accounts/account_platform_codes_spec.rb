# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Account, "platform_codes", type: :model do
  it "memorizza i codici piattaforma nelle preferenze (globali)" do
    account = create(:account)
    account.update!(platform_codes: [ "ios", "web" ])
    expect(account.reload.platform_codes).to eq([ "ios", "web" ])
  end
end
