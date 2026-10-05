# frozen_string_literal: true

require "rails_helper"

RSpec.describe Types::InstallDefaults, type: :service do
  let(:organization) { create(:organization) }

  it "crea i 5 status, le 3 priorità, le 3 piattaforme e i 3 environment di default" do
    described_class.call(organization: organization)
    expect(organization.ticket_statuses.count).to eq(5)
    expect(organization.ticket_priorities.count).to eq(3)
    expect(organization.platforms.count).to eq(3)
    expect(organization.platforms.pluck(:code)).to contain_exactly("ios", "android", "web")
    expect(organization.environments.count).to eq(3)
    expect(organization.environments.pluck(:code)).to contain_exactly("production", "staging", "development")
  end

  it "crea i 6 stati di default della matrice funzionalità" do
    described_class.call(organization: organization)
    expect(organization.feature_statuses.count).to eq(6)
    expect(organization.feature_statuses.pluck(:code)).to contain_exactly(
      "unplanned", "planned", "in_development", "available", "deprecated", "not_applicable"
    )
  end

  it "risolve la category degli stati funzionalità nel valore dell'enum" do
    described_class.call(organization: organization)
    statuses = organization.feature_statuses.index_by(&:code)
    expect(statuses["available"]).to be_category_available
    expect(statuses["not_applicable"]).to be_category_not_applicable
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    2.times { described_class.call(organization: organization) }
    expect(organization.ticket_statuses.count).to eq(5)
    expect(organization.ticket_priorities.count).to eq(3)
    expect(organization.platforms.count).to eq(3)
    expect(organization.environments.count).to eq(3)
    expect(organization.feature_statuses.count).to eq(6)
  end

  it "ritorna Result.ok con l'organizzazione" do
    result = described_class.call(organization: organization)
    expect(result).to be_ok
    expect(result.value).to eq(organization)
  end

  it "assegna created_by quando passato" do
    account = create(:account)
    described_class.call(organization: organization, created_by: account)
    expect(organization.ticket_statuses.find_by(code: "open").created_by).to eq(account)
  end

  it "marca animated solo per gli stati in lavorazione" do
    described_class.call(organization: organization)
    animated = organization.ticket_statuses.where(animated: true).pluck(:code)
    expect(animated).to contain_exactly("in_progress", "in_review")
  end

  it "marca review_gate solo per lo status In Review" do
    described_class.call(organization: organization)
    gates = organization.ticket_statuses.where(review_gate: true).pluck(:code)
    expect(gates).to contain_exactly("in_review")
  end

  it "marca supports_uptime solo per la piattaforma web (ios/android native)" do
    described_class.call(organization: organization)
    expect(organization.platforms.find_by(code: "web").supports_uptime).to be(true)
    expect(organization.platforms.where(code: %w[ios android]).pluck(:supports_uptime)).to all(be(false))
  end

  it "semina la matrice di capability differenziata sui 3 environment" do
    described_class.call(organization: organization)
    envs = organization.environments.index_by(&:code)
    # [servers, uptime, secrets]: uptime solo in produzione; server assenti in development; secret ovunque.
    expect([ envs["production"].servers_enabled, envs["production"].uptime_enabled, envs["production"].secrets_enabled ]).to eq([ true, true, true ])
    expect([ envs["staging"].servers_enabled, envs["staging"].uptime_enabled, envs["staging"].secrets_enabled ]).to eq([ true, false, true ])
    expect([ envs["development"].servers_enabled, envs["development"].uptime_enabled, envs["development"].secrets_enabled ]).to eq([ false, false, true ])
  end

  it "semina approval_required=true SOLO in produzione (CYRA-138, Fase 4 pezzo C1a)" do
    described_class.call(organization: organization)
    envs = organization.environments.index_by(&:code)
    expect(envs["production"].approval_required).to be(true)
    expect(envs["staging"].approval_required).to be(false)
    expect(envs["development"].approval_required).to be(false)
  end
end
