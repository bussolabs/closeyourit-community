# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Links::Attach do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |e| project.environments << e } }
  let(:host) { create(:server_host, organization: project.organization) }
  let(:actor) { create(:account) }

  before do
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: project.organization))
  end

  it "crea il collegamento e registra l'autore" do
    result = described_class.call(project:, environment:, host:, actor:)
    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(result.value.created_by).to eq(actor)
  end

  it "è idempotente: ri-collegare la stessa tripla non duplica" do
    described_class.call(project:, environment:, host:, actor:)
    expect do
      result = described_class.call(project:, environment:, host:, actor:)
      expect(result).to be_ok
    end.not_to change(Connections::EnvironmentHost, :count)
  end

  it "fallisce con R422-SERVER-006 se l'host è revocato" do
    host.update!(revoked_at: Time.current)
    result = described_class.call(project:, environment:, host:, actor:)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-SERVER-006")
  end

  it "fallisce con R422-SERVER-006 se l'environment non è dichiarato dal progetto" do
    undeclared = create(:environment, organization: project.organization)
    result = described_class.call(project:, environment: undeclared, host:, actor:)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-SERVER-006")
  end

  it "fallisce con R422-SERVER-006 se il progetto non è uptime-capable" do
    project.project_platforms.uptime_capable.destroy_all
    result = described_class.call(project:, environment:, host:, actor:)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-SERVER-006")
  end
end
