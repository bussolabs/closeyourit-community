# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::SharedSecrets do
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:source_env) { create(:environment, organization: source, code: "production") }
  let(:destination_env) { create(:environment, organization: destination, code: "production") }
  let(:project) { create(:project, organization: source) }
  let(:subject_) { Projects::Moves::Subject.new(project) }

  around do |example|
    previous = ENV["SECRET_ASSETS_MASTER_KEY"]
    ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
    example.run
  ensure
    ENV["SECRET_ASSETS_MASTER_KEY"] = previous
  end

  before { project.environments << source_env }

  def service = described_class.new(subject: subject_, destination:)

  describe "shared variables" do
    let(:shared) { Secrets::Shared::Variable.create!(organization: source, name: "DATABASE_URL") }
    let(:value) { shared.values.create!(environment: source_env, value: "postgres://one") }

    before { Secrets::Shared::Delegation.create!(shared_value: value, project:) }

    it "copies a shared value the destination lacks and repoints the delegation" do
      expect(service.copies).to contain_exactly(a_hash_including(kind: "variable", name: "DATABASE_URL"))

      service.apply!(environments: { source_env.id => destination_env.id }, actor: nil)
      Projects::Project.where(id: project.id).update_all(organization_id: destination.id)

      delegation = Secrets::Shared::Delegation.find_by!(project:)
      expect(delegation.shared_value.shared_variable.organization_id).to eq(destination.id)
      expect(delegation.shared_value.value).to eq("postgres://one")
      expect(value.reload.value).to eq("postgres://one")
    end

    it "records the copied value in the destination audit, without the value" do
      actor = create(:account)
      service.apply!(environments: { source_env.id => destination_env.id }, actor:)

      event = Secrets::Shared::Event.find_by!(organization: destination)
      expect(event).to have_attributes(action: "created", name: "DATABASE_URL", environment_id: destination_env.id,
                                       actor_id: actor.id)
      expect(event.metadata.to_s).not_to include("postgres://")
    end

    it "reuses a destination value with the same content" do
      existing = Secrets::Shared::Variable.create!(organization: destination, name: "DATABASE_URL")
      existing.values.create!(environment: destination_env, value: "postgres://one")

      expect(service.conflicts).to be_empty
      expect(service.copies).to be_empty
    end

    it "reports a conflict when the destination value differs" do
      existing = Secrets::Shared::Variable.create!(organization: destination, name: "DATABASE_URL")
      existing.values.create!(environment: destination_env, value: "postgres://two")

      expect(service.conflicts).to contain_exactly(
        { kind: "variable", name: "DATABASE_URL", environment_code: "production" }
      )
    end

    it "reports a conflict for short differing values without fingerprints" do
      short = Secrets::Shared::Variable.create!(organization: source, name: "LOG_LEVEL")
      short_value = short.values.create!(environment: source_env, value: "debug")
      Secrets::Shared::Delegation.create!(shared_value: short_value, project:)
      existing = Secrets::Shared::Variable.create!(organization: destination, name: "LOG_LEVEL")
      existing.values.create!(environment: destination_env, value: "info")

      expect(short_value.value_fingerprint).to be_nil
      expect(service.conflicts).to contain_exactly(a_hash_including(kind: "variable", name: "LOG_LEVEL"))
    end

    it "refuses to apply while a conflict exists" do
      existing = Secrets::Shared::Variable.create!(organization: destination, name: "DATABASE_URL")
      existing.values.create!(environment: destination_env, value: "postgres://two")

      expect { service.apply!(environments: { source_env.id => destination_env.id }, actor: nil) }
        .to raise_error(AppError) { |error| expect(error.code).to eq("R409-PROJECTMOVE-003") }
      expect(Secrets::Shared::Delegation.find_by!(project:).shared_value_id).to eq(value.id)
    end

    it "copies once when two moved projects delegate the same value" do
      group = create(:group, organization: source)
      project.update!(group:)
      other = create(:project, organization: source, group:)
      other.environments << source_env
      Secrets::Shared::Delegation.create!(shared_value: value, project: other)
      both = described_class.new(subject: Projects::Moves::Subject.new(group), destination:)

      both.apply!(environments: { source_env.id => destination_env.id }, actor: nil)

      expect(Secrets::Shared::Variable.where(organization: destination, name: "DATABASE_URL").count).to eq(1)
      expect(Secrets::Shared::Value.joins(:shared_variable)
        .where(secrets_shared_variables: { organization_id: destination.id }).count).to eq(1)
      expect(Secrets::Shared::Delegation.where(project: [ project, other ]).pluck(:shared_value_id).uniq.size).to eq(1)
    end

    it "adds the value to a destination variable that only has other environments" do
      staging = create(:environment, organization: destination, code: "staging")
      existing = Secrets::Shared::Variable.create!(organization: destination, name: "DATABASE_URL")
      existing.values.create!(environment: staging, value: "postgres://staging")

      service.apply!(environments: { source_env.id => destination_env.id }, actor: nil)

      expect(Secrets::Shared::Variable.where(organization: destination, name: "DATABASE_URL")).to contain_exactly(existing)
      expect(existing.values.pluck(:environment_id)).to contain_exactly(staging.id, destination_env.id)
    end

    it "resolves a missing environment mapping by code" do
      destination_env
      service.apply!(environments: {}, actor: nil)

      copy = Secrets::Shared::Delegation.find_by!(project:).shared_value
      expect(copy.environment_id).to eq(destination_env.id)
    end

    it "raises when the destination has no environment with that code" do
      expect { service.apply!(environments: {}, actor: nil) }
        .to raise_error(AppError) { |error| expect(error.code).to eq("R422-PROJECTMOVE-005") }
    end
  end

  describe "shared files" do
    let(:bytes) { "-----BEGIN " + "PRIVATE KEY-----x" }
    let(:asset) do
      record = Secrets::Asset.new(organization: source, name: "AuthKey", environment: source_env)
      Secrets::Assets::Upload.call(asset: record, uploaded_file: upload(bytes), actor: nil).value
      record
    end

    def upload(content)
      Rack::Test::UploadedFile.new(StringIO.new(content), "application/octet-stream", original_filename: "AuthKey.p8")
    end

    def destination_asset(content)
      record = Secrets::Asset.new(organization: destination, name: "AuthKey", environment: destination_env)
      Secrets::Assets::Upload.call(asset: record, uploaded_file: upload(content), actor: nil)
      record
    end

    before { Secrets::AssetDelegation.create!(asset:, project:) }

    it "copies a file the destination lacks and repoints the delegation" do
      expect(service.copies).to contain_exactly(a_hash_including(kind: "file", name: "AuthKey"))

      service.apply!(environments: { source_env.id => destination_env.id }, actor: nil)

      copy = Secrets::AssetDelegation.find_by!(project:).asset
      expect(copy.organization_id).to eq(destination.id)
      expect(copy.environment_id).to eq(destination_env.id)
      expect(Secrets::Assets::Download.call(version: copy.current_version, actor: nil).value).to eq(bytes)
      expect(asset.reload.versions.count).to eq(1)
    end

    it "reuses a destination file with the same content" do
      destination_asset(bytes)

      expect(service.conflicts).to be_empty
      expect(service.copies).to be_empty
    end

    it "reports a conflict when the destination asset has no version" do
      Secrets::Asset.create!(organization: destination, name: "AuthKey", environment: destination_env, asset_type: "p8")

      expect(service.conflicts).to contain_exactly(a_hash_including(kind: "file", name: "AuthKey"))
    end

    it "does not record a download event while copying" do
      expect { service.apply!(environments: { source_env.id => destination_env.id }, actor: nil) }
        .not_to(change { asset.reload.versions.count })
      expect(Secrets::AssetEvent.where(action: "downloaded").count).to eq(0)
    end

    it "reports a conflict when the destination file differs" do
      destination_asset("-----BEGIN " + "PRIVATE KEY-----y")

      expect(service.conflicts).to contain_exactly(
        { kind: "file", name: "AuthKey", environment_code: "production" }
      )
    end
  end
end
