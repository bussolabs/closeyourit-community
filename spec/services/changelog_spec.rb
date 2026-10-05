# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog do
  let(:md) do
    <<~MD
      # Changelog

      ## [Unreleased]

      ## [0.0.52] - 2026-07-01

      ### Added
      - Voce recente.

      ## [0.0.51] - 2026-06-30

      ### Changed
      - Voce vecchia.
    MD
  end

  before do
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:exist?).with(described_class::PATH).and_return(true)
    allow(File).to receive(:read).with(described_class::PATH).and_return(md)
  end

  describe ".releases" do
    it "parsa il CHANGELOG in release" do
      expect(described_class.releases.map(&:version)).to eq(%w[0.0.52 0.0.51])
    end
  end

  describe ".releases in a deployed image" do
    before do
      stub_const("ENV", ENV.to_h.merge("APP_GIT_SHA" => "abc123"))
      described_class.instance_variable_set(:@memo, nil)
    end

    after { described_class.instance_variable_set(:@memo, nil) }

    it "parses the file once per process and skips the shared cache" do
      expect(Rails.cache).not_to receive(:fetch)

      2.times { described_class.releases }

      expect(File).to have_received(:read).with(described_class::PATH).once
      expect(described_class.current.version).to eq("0.0.52")
    end

    it "parses again when the image sha changes" do
      described_class.releases
      stub_const("ENV", ENV.to_h.merge("APP_GIT_SHA" => "def456"))

      described_class.releases

      expect(File).to have_received(:read).with(described_class::PATH).twice
    end
  end

  describe ".recent" do
    it "limita al numero richiesto, dalla più recente" do
      expect(described_class.recent(1).map(&:version)).to eq(%w[0.0.52])
    end
  end

  describe ".current" do
    it "è la release più recente" do
      expect(described_class.current.version).to eq("0.0.52")
    end

    context "quando il file non esiste" do
      before { allow(File).to receive(:exist?).with(described_class::PATH).and_return(false) }

      it "è nil" do
        expect(described_class.current).to be_nil
      end
    end
  end
end
