# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Links::SetHosts do
  let(:org) { create(:organization) }
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:host_a) { create(:server_host, organization: org, name: "host-a") }
  let(:host_b) { create(:server_host, organization: org, name: "host-b") }

  def linked_host_ids
    project.server_links.where(environment:).pluck(:host_id)
  end

  it "collega gli host desiderati non ancora presenti" do
    result = described_class.call(project:, environment:, host_ids: [ host_a.id, host_b.id ])

    expect(result).to be_ok
    expect(linked_host_ids).to contain_exactly(host_a.id, host_b.id)
  end

  it "stacca gli host non più desiderati (sincronizzazione)" do
    create(:environment_host, project:, environment:, host: host_a)
    create(:environment_host, project:, environment:, host: host_b)

    described_class.call(project:, environment:, host_ids: [ host_a.id ])

    expect(linked_host_ids).to contain_exactly(host_a.id)
  end

  it "una lista vuota stacca tutti gli host" do
    create(:environment_host, project:, environment:, host: host_a)

    described_class.call(project:, environment:, host_ids: [])

    expect(linked_host_ids).to be_empty
  end

  it "scarta un host di un'altra org (anti-BOLA)" do
    foreign = create(:server_host, organization: create(:organization))

    described_class.call(project:, environment:, host_ids: [ foreign.id ])

    expect(linked_host_ids).to be_empty
  end

  it "è idempotente: ri-sincronizzare la stessa lista non cambia nulla" do
    create(:environment_host, project:, environment:, host: host_a)

    expect { described_class.call(project:, environment:, host_ids: [ host_a.id ]) }
      .not_to(change { project.server_links.where(environment:).count })
  end
end
