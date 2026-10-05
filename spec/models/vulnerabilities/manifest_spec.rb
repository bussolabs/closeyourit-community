# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Manifest, type: :model do
  it "factory valida" do
    expect(build(:vulnerability_manifest)).to be_valid
  end

  it "un path compare una sola volta per progetto" do
    manifest = create(:vulnerability_manifest, path: "Gemfile.lock")
    expect(build(:vulnerability_manifest, project: manifest.project, path: "Gemfile.lock")).not_to be_valid
    # …ma lo stesso path in un altro progetto è normale.
    expect(build(:vulnerability_manifest, path: "Gemfile.lock")).to be_valid
  end

  it "accetta solo ecosistemi che sappiamo leggere" do
    expect(build(:vulnerability_manifest, ecosystem: "Cargo")).not_to be_valid
    expect(build(:vulnerability_manifest, ecosystem: nil)).not_to be_valid
    expect(build(:vulnerability_manifest, ecosystem: Vulnerabilities::Ecosystem::PUB)).to be_valid
  end

  describe "#changed_content?" do
    it "riconosce il file immutato" do
      manifest = build(:vulnerability_manifest, content_digest: "abc")
      expect(manifest.changed_content?("abc")).to be(false)
      expect(manifest.changed_content?("def")).to be(true)
    end

    it "un manifest mai letto conta sempre come cambiato" do
      expect(build(:vulnerability_manifest, :unread).changed_content?("abc")).to be(true)
    end
  end

  it ".digest_for è stabile sullo stesso contenuto" do
    expect(described_class.digest_for("a\nb")).to eq(described_class.digest_for("a\nb"))
    expect(described_class.digest_for("a")).not_to eq(described_class.digest_for("b"))
  end

  it "scope parsed/failing separano i lockfile illeggibili" do
    ok = create(:vulnerability_manifest)
    broken = create(:vulnerability_manifest, :failing, path: "web/package-lock.json",
                                                       ecosystem: Vulnerabilities::Ecosystem::NPM)

    expect(described_class.parsed).to contain_exactly(ok)
    expect(described_class.failing).to contain_exactly(broken)
  end

  it "cancella i propri pacchetti quando sparisce" do
    manifest = create(:vulnerability_manifest)
    create(:vulnerability_package, manifest: manifest)

    expect { manifest.destroy }.to change(Vulnerabilities::Package, :count).by(-1)
  end
end
