# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::Certify do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }
  let(:host) { create(:agent_host, :uncertified, organization:) }

  it "certifica l'host: setta certified_at e certified_by, ritornando Result.ok (B.1b)" do
    result = described_class.call(host:, actor:)

    expect(result).to be_ok
    expect(host.reload).to be_certified
    expect(host.certified_at).to be_within(2.seconds).of(Time.current)
    expect(host.certified_by).to eq(actor)
  end

  it "è idempotente: ri-certificare aggiorna l'autore" do
    described_class.call(host:, actor: create(:account))
    result = described_class.call(host:, actor:)

    expect(result).to be_ok
    expect(host.reload.certified_by).to eq(actor)
  end
end

RSpec.describe Agents::Hosts::Decertify do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:, certified_at: Time.current, certified_by: create(:account)) }

  it "revoca la certificazione: azzera certified_at e certified_by (B.1b)" do
    result = described_class.call(host:)

    expect(result).to be_ok
    expect(host.reload).not_to be_certified
    expect(host.certified_at).to be_nil
    expect(host.certified_by).to be_nil
  end
end
