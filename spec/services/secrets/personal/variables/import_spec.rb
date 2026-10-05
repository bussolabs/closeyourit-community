# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Variables::Import do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  it "importa tutte le voci e registra UN solo evento imported" do
    entries = [ { name: "A", value: "1" }, { name: "B", value: "2" } ]

    expect { described_class.call(account:, organization:, entries:) }
      .to change { Secrets::Personal::Variable.for(account:, organization:).count }.by(2)

    events = Secrets::Personal::Event.for(account:, organization:)
    expect(events.where(action: "imported").count).to eq(1)
    expect(events.where(action: "set").count).to eq(0)
  end

  it "è all-or-nothing: una voce invalida → zero scritture e zero eventi" do
    entries = [ { name: "GOOD", value: "1" }, { name: "1BAD", value: "2" } ]

    result = described_class.call(account:, organization:, entries:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PERSONALSECRET-001")
    expect(Secrets::Personal::Variable.for(account:, organization:).count).to eq(0)
    expect(Secrets::Personal::Event.for(account:, organization:).count).to eq(0)
  end

  it "entries vuote → ok con lista vuota, nessun evento" do
    expect { expect(described_class.call(account:, organization:, entries: []).value).to eq([]) }
      .not_to change(Secrets::Personal::Event, :count)
  end
end
