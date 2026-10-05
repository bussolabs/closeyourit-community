# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Ecosystem do
  describe ".for_path" do
    it "riconosce i lockfile dal nome file, ovunque stiano nel repository" do
      expect(described_class.for_path("Gemfile.lock")).to eq("RubyGems")
      expect(described_class.for_path("apps/api/Gemfile.lock")).to eq("RubyGems")
      expect(described_class.for_path("web/pnpm-lock.yaml")).to eq("npm")
      expect(described_class.for_path("web/package-lock.json")).to eq("npm")
      expect(described_class.for_path("mobile/pubspec.lock")).to eq("Pub")
      expect(described_class.for_path("go.sum")).to eq("Go")
    end

    it "ignora ciò che non sappiamo leggere" do
      expect(described_class.for_path("Gemfile")).to be_nil
      expect(described_class.for_path("package.json")).to be_nil
      expect(described_class.for_path("uv.lock")).to be_nil
      expect(described_class.for_path("")).to be_nil
    end
  end

  describe ".ignored_path?" do
    it "scarta le copie di dipendenze e i worktree, che non dicono cosa usa il progetto" do
      expect(described_class).to be_ignored_path("node_modules/foo/package-lock.json")
      expect(described_class).to be_ignored_path("vendor/bundle/Gemfile.lock")
      expect(described_class).to be_ignored_path("worktrees/CYRA-1/Gemfile.lock")
      expect(described_class).to be_ignored_path("spec/fixtures/Gemfile.lock")
    end

    it "non scarta un lockfile legittimo, anche annidato" do
      expect(described_class).not_to be_ignored_path("Gemfile.lock")
      expect(described_class).not_to be_ignored_path("apps/backend/Gemfile.lock")
    end

    it "guarda solo le directory, non il nome del file" do
      expect(described_class).not_to be_ignored_path("tmp_service/Gemfile.lock")
    end
  end

  it ".scannable? richiede lockfile noto E posizione legittima" do
    expect(described_class).to be_scannable("apps/api/Gemfile.lock")
    expect(described_class).not_to be_scannable("node_modules/x/package-lock.json")
    expect(described_class).not_to be_scannable("README.md")
  end
end
