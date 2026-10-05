# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::RegisterHost do
  let(:organization) { create(:organization) }

  it "crea l'host al primo push (name = hostname)" do
    result = nil
    expect do
      result = described_class.call(organization:, fingerprint: "abc123", hostname: "web-1")
    end.to change(Servers::Host, :count).by(1)

    host = result.value
    expect(host.fingerprint).to eq("abc123")
    expect(host.name).to eq("web-1")
    expect(host.status_pending?).to be(true)
  end

  it "senza hostname usa il fingerprint come name" do
    host = described_class.call(organization:, fingerprint: "abc123").value

    expect(host.name).to eq("abc123")
  end

  # CYRA-469 — il legame host→codice nasce qui, alla prima registrazione: da qui la pagina dei codici
  # sa quante macchine sono collegate a ciascuno.
  it "lega l'host al codice di enrollment passato" do
    token = create(:server_enrollment_token, organization:)

    host = described_class.call(organization:, fingerprint: "abc123", enrollment_token: token).value

    expect(host.enrollment_token).to eq(token)
  end

  it "senza codice l'host resta senza codice attribuibile (nil)" do
    host = described_class.call(organization:, fingerprint: "abc123").value

    expect(host.enrollment_token_id).to be_nil
  end

  it "riusa l'host esistente per lo stesso fingerprint (idempotente)" do
    existing = create(:server_host, organization:, fingerprint: "abc123", name: "già-rinominato")

    result = nil
    expect do
      result = described_class.call(organization:, fingerprint: "abc123", hostname: "web-1")
    end.not_to change(Servers::Host, :count)

    expect(result.value).to eq(existing)
    expect(existing.reload.name).to eq("già-rinominato")
  end

  it "converge sulla riga vinta dal race gemello (RecordNotUnique → find)" do
    # Simula il race: il primo lookup non vede la riga, la create! collide sull'unique index.
    existing = create(:server_host, organization:, fingerprint: "abc123")
    # find_by! passa da find_by: primo lookup nil (race), il retry post-collisione vede la riga.
    allow(Servers::Host).to receive(:find_by).and_return(nil, existing)
    allow(Servers::Host).to receive(:create!)
      .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))

    result = described_class.call(organization:, fingerprint: "abc123")

    expect(result.value).to eq(existing)
  end

  it "non mescola organization diverse con lo stesso fingerprint" do
    other_org_host = create(:server_host, fingerprint: "abc123")

    host = described_class.call(organization:, fingerprint: "abc123").value

    expect(host).not_to eq(other_org_host)
    expect(host.organization).to eq(organization)
  end
end
