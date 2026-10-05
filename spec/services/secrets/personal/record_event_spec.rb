# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::RecordEvent do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  it "crea un evento append-only" do
    expect { described_class.call(action: "read", account:, organization:, metadata: { count: 3 }) }
      .to change(Secrets::Personal::Event, :count).by(1)

    event = Secrets::Personal::Event.last
    expect(event.action).to eq("read")
    expect(event.metadata).to eq({ "count" => 3 })
  end

  it "è fire-and-forget: un'azione invalida non solleva, ritorna nil" do
    expect { expect(described_class.call(action: "invalid", account:, organization:)).to be_nil }
      .not_to change(Secrets::Personal::Event, :count)
  end
end
