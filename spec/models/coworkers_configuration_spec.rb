require "rails_helper"

RSpec.describe Coworkers do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("COWORKERS_ENABLED", "false").and_return("true")
  end

  it "requires remote execution and complete configuration outside development and test" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    expect(described_class.enabled?).to be(false)
    allow(described_class).to receive(:remote?).and_return(true)
    expect(described_class.enabled?).to be(false)
    allow(described_class).to receive(:worker_token_digest).and_return("a" * 64)
    allow(described_class).to receive(:worker_organization_id).and_return(organization.id)
    allow(described_class).to receive(:worker_account_ids).and_return([ account.id ])
    expect(described_class.enabled?).to be(true)
  end

  it "limits remote access to the configured organization and accounts" do
    allow(described_class).to receive(:remote?).and_return(true)
    allow(described_class).to receive(:worker_organization_id).and_return(organization.id)
    allow(described_class).to receive(:worker_account_ids).and_return([ account.id ])
    expect(described_class.available_to?(account: account, organization: organization)).to be(true)
    expect(described_class.available_to?(account: create(:account), organization: organization)).to be(false)
    expect(described_class.available_to?(account: account, organization: create(:organization))).to be(false)
  end

  it "does not launch a local subprocess for remote work" do
    allow(described_class).to receive(:remote?).and_return(true)
    puck = Coworkers::Puck.create!(organization: organization, account: account, name: "Researcher", instructions: "Cite sources")
    expect { Coworkers::Start.call(puck: puck, kind: "chat", input: "Hello") }.not_to have_enqueued_job(Coworkers::ExecuteJob)
    run = puck.runs.last
    Coworkers::ExecuteJob.perform_now(run.id)
    expect(run.reload.status).to eq("queued")
  end

  context "with the default local configuration" do
    around do |example|
      previous = ENV.to_h.slice("COWORKERS_ENABLED", "COWORKERS_RUNTIME_ROOT")
      ENV.delete("COWORKERS_ENABLED")
      ENV.delete("COWORKERS_RUNTIME_ROOT")
      example.run
    ensure
      ENV.delete("COWORKERS_ENABLED")
      ENV.delete("COWORKERS_RUNTIME_ROOT")
      ENV.update(previous)
    end

    before { allow(ENV).to receive(:fetch).and_call_original }

    it "locates the sibling Automator checkout only in development" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
      expect(described_class.runtime_root).to eq(Rails.root.join("../closeyourit-automator/prototypes/coworkers").cleanpath)
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      expect { described_class.runtime_root }.to raise_error(KeyError)
    end

    it "shows the local entry only when the bridge exists and honors an explicit opt-out" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
      Dir.mktmpdir do |directory|
        allow(described_class).to receive(:runtime_root).and_return(Pathname.new(directory))
        expect(described_class.enabled?).to be(false)
        File.write(File.join(directory, "bridge.mjs"), "// Local runtime fixture\n")
        expect(described_class.enabled?).to be(true)
        ENV["COWORKERS_ENABLED"] = "false"
        expect(described_class.enabled?).to be(false)
      end
    end

    it "keeps test and production disabled without explicit activation" do
      %w[test production].each do |environment|
        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(environment))
        expect(described_class.enabled?).to be(false)
      end
    end

    it "preserves an explicitly configured runtime location" do
      ENV["COWORKERS_RUNTIME_ROOT"] = "/opt/coworkers"
      expect(described_class.runtime_root).to eq(Pathname.new("/opt/coworkers"))
    end
  end
end
