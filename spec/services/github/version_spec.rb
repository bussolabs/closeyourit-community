# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Version do
  describe ".stable?" do
    it "è vera per un semver senza suffisso" do
      expect(described_class.stable?("v1.2.3")).to be(true)
      expect(described_class.stable?("2.0.0")).to be(true)
    end

    it "è falsa per un pre-release" do
      expect(described_class.stable?("v1.2.3-beta")).to be(false)
      expect(described_class.stable?("v1.2.3-rc1")).to be(false)
      expect(described_class.stable?("1.2.3-alpha.1")).to be(false)
    end

    it "ignora il build-metadata dopo il +" do
      expect(described_class.stable?("v1.2.3+build.5")).to be(true)
    end

    it "è falsa per una stringa vuota" do
      expect(described_class.stable?("")).to be(false)
      expect(described_class.stable?(nil)).to be(false)
    end
  end
end
