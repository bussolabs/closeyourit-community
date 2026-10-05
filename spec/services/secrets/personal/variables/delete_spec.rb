# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Variables::Delete do
  it "distrugge la variabile e registra l'evento deleted" do
    variable = create(:personal_secret_variable, name: "API_KEY")

    result = described_class.call(variable:)

    expect(result).to be_ok
    expect(Secrets::Personal::Variable.exists?(variable.id)).to be(false)
    expect(Secrets::Personal::Event.for(account: variable.account, organization: variable.organization)
             .where(action: "deleted", name: "API_KEY")).to exist
  end
end
