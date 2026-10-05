# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Triage, type: :service do
  let(:group) { create(:error_group, status: :unresolved) }

  it "resolve → resolved" do
    expect(described_class.call(group:, action: "resolve")).to be_ok
    expect(group.reload).to be_status_resolved
  end

  it "ignore → ignored" do
    described_class.call(group:, action: "ignore")
    expect(group.reload).to be_status_ignored
  end

  it "reopen → unresolved (da resolved o ignored)" do
    group.status_resolved!
    described_class.call(group:, action: "reopen")
    expect(group.reload).to be_status_unresolved
  end

  it "azione sconosciuta → err R422-ERROR-002, stato invariato" do
    result = described_class.call(group:, action: "bogus")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-ERROR-002")
    expect(group.reload).to be_status_unresolved
  end

  # CYRA-44: alla resolve fotografa la release "del fix" (la live) e azzera l'eventuale release di
  # regressione del ciclo precedente.
  describe "audit di regressione (resolve)" do
    let(:project) { create(:project) }
    let(:group)   { create(:error_group, project:, status: :unresolved, regressed_in_release: "v0.9") }

    it "resolve registra la release live come resolved_in_release e azzera regressed_in_release" do
      create(:release, project:, version: "v1.2", environment: "production", current: true)

      described_class.call(group:, action: "resolve")

      expect(group.reload.resolved_in_release).to eq("v1.2")
      expect(group.regressed_in_release).to be_nil
    end

    it "resolve senza release live (nessun binding) → resolved_in_release nil" do
      described_class.call(group:, action: "resolve")
      expect(group.reload.resolved_in_release).to be_nil
    end

    it "ignore non tocca l'audit di regressione" do
      group.update!(resolved_in_release: "v1.0")
      described_class.call(group:, action: "ignore")
      expect(group.reload.resolved_in_release).to eq("v1.0")
    end
  end
end
