# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::LookupMap do
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:project) { create(:project, organization: source) }
  let(:source_env) { create(:environment, organization: source, code: "staging", label: "Staging", color: "amber") }
  let(:map) { described_class.new(subject: Projects::Moves::Subject.new(project), destination:) }

  before { project.environments << source_env }

  it "maps an environment to the destination one with the same code" do
    target = create(:environment, organization: destination, code: "staging")

    expect(map.missing).to be_empty
    expect(map.apply!.dig("types_environments", source_env.id)).to eq(target.id)
  end

  it "lists and creates an environment the destination lacks, copying its attributes" do
    expect(map.missing).to include(a_hash_including(table: "types_environments", code: "staging"))
    created = Types::Environment.find(map.apply!.dig("types_environments", source_env.id))
    expect(created).to have_attributes(organization_id: destination.id, code: "staging", label: "Staging", color: "amber")
  end

  it "ignores lookups that only other projects of the organization use" do
    create(:environment, organization: source, code: "unused")

    expect(map.apply!.fetch("types_environments").keys).to eq([ source_env.id ])
  end

  it "lists an environment used only by a shared file delegated to the project" do
    file_env = create(:environment, organization: source, code: "sandbox")
    asset = Secrets::Asset.create!(organization: source, name: "AuthKey", environment: file_env, asset_type: "p8")
    Secrets::AssetDelegation.create!(asset:, project:)

    expect(map.missing).to include(a_hash_including(table: "types_environments", code: "sandbox"))
  end

  it "has a scope predicate for every lookup table of the registry" do
    Projects::Moves::Registry::LOOKUPS.each_key do |table|
      expect(map.scope_sql(table)).to be_present, "no scope for #{table}"
    end
  end
end
