require "rails_helper"

RSpec.describe Agents::LiveEvents::ProjectTree do
  let(:repository) { create(:github_repository, default_branch: "main") }
  let(:project) { repository.project }
  let(:client) { instance_double(Github::Client) }
  let(:installation_id) { repository.installation.installation_id }

  def tree(*paths, truncated: false, extra: [])
    entries = paths.map { { "path" => it, "type" => "blob" } } + extra
    { entries:, truncated: }
  end

  it "returns the file paths of the default branch, sorted, without folders" do
    allow(client).to receive(:git_tree).with(installation_id, repository.full_name, "main")
      .and_return(tree("b.rb", "app/a.rb", extra: [ { "path" => "app", "type" => "tree" } ]))

    result = described_class.call(project:, client:)

    expect(result.paths).to eq(%w[app/a.rb b.rb])
    expect(result).not_to be_partial
  end

  it "is partial when GitHub truncated the tree" do
    allow(client).to receive(:git_tree).and_return(tree("a.rb", truncated: true))

    expect(described_class.call(project:, client:)).to be_partial
  end

  it "keeps at most the cap and says it is partial" do
    stub_const("#{described_class}::MAX_PATHS", 2)
    allow(client).to receive(:git_tree).and_return(tree("a.rb", "b.rb", "c.rb"))

    result = described_class.call(project:, client:)

    expect(result.paths).to eq(%w[a.rb b.rb])
    expect(result).to be_partial
  end

  it "is nil for a project without a GitHub repository" do
    expect(described_class.call(project: create(:project), client:)).to be_nil
  end

  it "is nil when GitHub fails or the branch is empty" do
    allow(client).to receive(:git_tree).and_raise(Github::Client::Error.new("down", code: "X"))
    expect(described_class.call(project:, client:)).to be_nil

    allow(client).to receive(:git_tree).and_return(nil)
    expect(described_class.call(project:, client:)).to be_nil
  end

  it "asks GitHub once while the tree is cached" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(client).to receive(:git_tree).and_return(tree("a.rb"))

    2.times { described_class.call(project:, client:) }

    expect(client).to have_received(:git_tree).once
  end

  it "does not cache a failure" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(client).to receive(:git_tree).and_return(nil, tree("a.rb"))

    expect(described_class.call(project:, client:)).to be_nil
    expect(described_class.call(project:, client:).paths).to eq(%w[a.rb])
  end

  describe described_class::Index do
    subject(:index) { described_class.new(%w[README.md app/models/a.rb app/models/b.rb app/views/x.erb]) }

    it "lists the folders and files of one level" do
      expect(index.folders("")).to eq(%w[app])
      expect(index.files("")).to eq(%w[README.md])
      expect(index.folders("app")).to eq(%w[app/models app/views])
      expect(index.files("app/models")).to eq(%w[app/models/a.rb app/models/b.rb])
    end

    it "keeps folders that start with a dot" do
      index = described_class.new(%w[.github/workflows/ci.yml])

      expect(index.folders("")).to eq(%w[.github])
      expect(index.files(".github/workflows")).to eq(%w[.github/workflows/ci.yml])
    end

    it "is empty for an unknown folder" do
      expect(index.folders("nope")).to eq([])
      expect(index.files("nope")).to eq([])
    end
  end
end
