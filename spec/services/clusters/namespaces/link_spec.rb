# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Namespaces::Link do
  let(:cluster) { create(:cluster) }
  let(:namespace) { create(:cluster_namespace, cluster:) }
  let(:project) { create(:project, organization: cluster.organization) }

  it "links a namespace to a project" do
    expect(described_class.call(namespace:, project:)).to be_ok
    expect(namespace.reload.project).to eq(project)
  end

  it "links an environment the project declares" do
    environment = create(:environment, organization: cluster.organization)
    Connections::ProjectEnvironment.create!(project:, environment:)
    expect(described_class.call(namespace:, project:, environment:)).to be_ok
    expect(namespace.reload.environment).to eq(environment)
  end

  it "refuses a project of another organization" do
    result = described_class.call(namespace:, project: create(:project))
    expect(result).not_to be_ok
    expect(result.error.code).to eq("R422-CLUSTER-003")
  end

  it "refuses an environment the project does not declare" do
    environment = create(:environment, organization: cluster.organization)
    expect(described_class.call(namespace:, project:, environment:)).not_to be_ok
  end

  it "unlinks" do
    described_class.call(namespace:, project:)
    Clusters::Namespaces::Unlink.call(namespace:)
    expect(namespace.reload.project).to be_nil
  end
end
