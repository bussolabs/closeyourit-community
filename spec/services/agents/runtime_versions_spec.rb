# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::RuntimeVersions do
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  let(:npm) { instance_double(Agents::Registries::Npm) }
  let(:eol) { instance_double(Vulnerabilities::Eol::Client) }

  before do
    allow(npm).to receive(:latest).and_return(nil)
    allow(npm).to receive(:latest).with("@anthropic-ai/claude-code").and_return("2.1.291")
    allow(npm).to receive(:latest).with("@openai/codex").and_return("0.156.1")
    allow(eol).to receive(:cycles).and_return(nil)
    allow(eol).to receive(:cycles).with("nodejs").and_return([
      { "cycle" => "26", "latest" => "26.10.0" }, { "cycle" => "24", "latest" => "24.21.0" }
    ])
    allow(eol).to receive(:cycles).with("python").and_return([
      { "cycle" => "3.13", "latest" => "3.13.8" }, { "cycle" => "3.12", "latest" => "3.12.11" }
    ])
  end

  def refresh! = described_class.refresh!(npm:, eol:)

  describe ".number" do
    it "reads the version out of what each program prints" do
      expect(described_class.number("v24.11.0")).to eq("24.11.0")
      expect(described_class.number("Python 3.12.3")).to eq("3.12.3")
      expect(described_class.number("codex-cli 0.156.1")).to eq("0.156.1")
      expect(described_class.number("2.1.289 (Claude Code)")).to eq("2.1.289")
      expect(described_class.number("@bussolabs/closeyourit-cli/0.30.0 linux-arm64 node-v24.11.0")).to eq("0.30.0")
    end

    it "gives nothing when there is no version to read" do
      expect(described_class.number("")).to be_nil
      expect(described_class.number(nil)).to be_nil
    end
  end

  describe ".status" do
    it "marks a program older than the latest release as outdated" do
      refresh!

      expect(described_class.status("claude", "2.1.289 (Claude Code)")).to eq(latest: "2.1.291", outdated: true)
    end

    it "does not mark a program already on the latest release" do
      refresh!

      expect(described_class.status("codex", "codex-cli 0.156.1")).to eq(latest: "0.156.1", outdated: false)
    end

    it "compares node only with the same major release, never with a newer major" do
      refresh!

      expect(described_class.status("node", "v24.11.0")).to eq(latest: "24.21.0", outdated: true)
    end

    it "compares python only with the same minor line" do
      refresh!

      expect(described_class.status("python", "Python 3.12.3")).to eq(latest: "3.12.11", outdated: true)
    end

    it "says nothing for a program it does not follow, or before the first check" do
      expect(described_class.status("claude", "2.1.289")).to be_nil

      refresh!
      expect(described_class.status("jq", "jq-1.7")).to be_nil
      expect(described_class.status("opencode", "")).to be_nil
    end
  end

  describe ".refresh!" do
    it "keeps the last known release when a source does not answer" do
      refresh!
      allow(npm).to receive(:latest).with("@anthropic-ai/claude-code")
                                    .and_raise(Agents::Registries::Client::Error.new("down", code: "R502-REGISTRY-001"))

      expect { refresh! }.not_to raise_error
      expect(described_class.status("claude", "2.1.289")[:latest]).to eq("2.1.291")
    end
  end
end
