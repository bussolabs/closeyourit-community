# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Shared::RowImpact do
  let(:organization) { create(:organization) }
  let(:env_prod) { create(:environment, organization:, code: "production") }
  let(:env_stg) { create(:environment, organization:, code: "staging") }
  let(:project) { create(:project, organization:) }

  # Crea un valore condiviso su un ambiente, delegato al progetto.
  def delegated_value(environment)
    create(:project_environment, project:, environment:)
    value = Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value: "secret").value
    Secrets::Shared::Delegate.call(shared_value: value, project:)
    value
  end

  it "produce un digest deterministico e indipendente dall'ordine delle celle" do
    first = delegated_value(env_prod)
    second = delegated_value(env_stg)

    digest_ab = described_class.call(shared_values: [ first, second ]).value["digest"]
    digest_ba = described_class.call(shared_values: [ second, first ]).value["digest"]

    expect(digest_ab).to be_present
    expect(digest_ab).to eq(digest_ba)
  end

  it "aggrega le entry con i progetti impattati per ogni ambiente" do
    value = delegated_value(env_prod)

    payload = described_class.call(shared_values: [ value ]).value

    expect(payload["effect"]).to eq("rotate")
    entry = payload["entries"].first
    expect(entry["name"]).to eq("API_KEY")
    expect(entry["environment"]).to eq("production")
    expect(entry["projects"].map { |item| item["name"] }).to include(project.name)
  end
end
