# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::Register do
  let(:organization) { create(:organization) }
  let(:attributes) do
    {
      organization:,
      fingerprint: "machine-abc",
      hostname: "workstation-1",
      platform: "linux",
      arch: "arm64",
      automator_version: "1.2.3"
    }
  end

  it "crea host e singola credenziale digest-only, rivelando il secret nel Result" do
    result = nil
    expect { result = described_class.call(**attributes) }
      .to change(Agents::Host, :count).by(1)
      .and change(Agents::HostToken, :count).by(1)

    host = result.value.fetch(:host)
    secret = result.value.fetch(:secret)
    expect(result.value.fetch(:created)).to be(true)
    expect(secret).to start_with(Agents::Constants::HOST_TOKEN_PREFIX)
    expect(host.host_tokens.sole.token_digest).to eq(Digest::SHA256.hexdigest(secret))
    expect(host.host_tokens.sole.attributes.values).not_to include(secret)
  end

  it "rifiuta una piattaforma non Linux prima di creare host, service account o token" do
    result = nil

    expect { result = described_class.call(**attributes.merge(platform: "darwin")) }
      .to not_change(Agents::Host, :count)
      .and not_change(Agents::HostToken, :count)
      .and not_change(Accounts::Account.service, :count)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R422-AGENT-004", status: :unprocessable_content)
    expect(result.error.details).to eq(platform: [ "deve essere linux" ])
  end

  it "sullo stesso fingerprint riusa l'host e ruota atomicamente l'unico token attivo" do
    first = described_class.call(**attributes).value

    second_result = nil
    expect { second_result = described_class.call(**attributes.merge(hostname: "workstation-renamed")) }
      .not_to change(Agents::Host, :count)

    second = second_result.value
    host = second.fetch(:host)
    expect(second.fetch(:created)).to be(false)
    expect(host).to eq(first.fetch(:host))
    expect(host.reload.hostname).to eq("workstation-renamed")
    expect(second.fetch(:secret)).not_to eq(first.fetch(:secret))
    expect(host.host_tokens.active.count).to eq(1)
    expect(host.host_tokens.count).to eq(2)
    expect(first.fetch(:token).reload).to be_revoked
  end

  it "non mescola tenant diversi con lo stesso fingerprint" do
    foreign = described_class.call(**attributes.merge(organization: create(:organization))).value.fetch(:host)
    local = described_class.call(**attributes).value.fetch(:host)

    expect(local).not_to eq(foreign)
    expect(local.organization).to eq(organization)
  end

  it "crea e collega un service account service, membro dell'org (identità operativa, B.1)" do
    host = described_class.call(**attributes).value.fetch(:host)

    expect(host.service_account).to be_present
    expect(host.service_account).to be_service
    expect(host.service_account.memberships.where(organization:).exists?).to be(true)
  end

  it "un re-register sullo stesso fingerprint non duplica il service account (idempotente)" do
    first = described_class.call(**attributes).value.fetch(:host)

    expect { described_class.call(**attributes.merge(hostname: "renamed")) }
      .not_to change(Accounts::Account.service, :count)
    expect(first.reload.service_account_id).to be_present
  end

  it "recupera via create_or_find_by! il race dopo un lookup stantio, senza passare dal validator" do
    winner = described_class.call(**attributes)
    hosts = organization.agent_hosts
    allow(organization).to receive(:agent_hosts).and_return(hosts)
    allow(hosts).to receive(:find_by).with(fingerprint: attributes[:fingerprint]).and_return(nil)

    loser = nil
    expect { loser = described_class.call(**attributes) }.not_to change(Agents::Host, :count)

    expect(winner).to be_ok
    expect(loser).to be_ok
    expect(loser.value[:host]).to eq(winner.value[:host])
    expect(loser.value[:host].host_tokens.active.sole.token_digest)
      .to eq(Digest::SHA256.hexdigest(loser.value[:secret]))
  end

  it "non inghiotte unique violation estranee alla risoluzione del fingerprint" do
    host = create(:agent_host, organization:, fingerprint: attributes[:fingerprint])
    hosts = organization.agent_hosts
    tokens = host.host_tokens
    allow(organization).to receive(:agent_hosts).and_return(hosts)
    allow(hosts).to receive(:find_by).and_return(host)
    allow(host).to receive(:host_tokens).and_return(tokens)
    allow(tokens).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique.new("duplicate token digest"))

    expect { described_class.call(**attributes) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "non riabilita un host revocato" do
    host = create(:agent_host, :revoked, organization:, fingerprint: attributes[:fingerprint])

    result = described_class.call(**attributes)

    expect(result).to be_err
    expect(result.error.code).to eq("R403-AGENT-001")
    expect(host.host_tokens).to be_empty
  end
end
