# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Plan, type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }

  def create_plan(**attributes)
    described_class.create!(
      workflow:, attempt:, ticket_snapshot_digest: "snapshot",
      technical_analysis: "Piano", scenarios: [], definition_of_done: [], notes: [],
      **attributes,
    )
  end

  describe "ortografia italiana" do
    it "mette gli accenti mancanti nell'analisi tecnica" do
      plan = create_plan(technical_analysis: "la ereditarieta non e' rispettata")

      expect(plan.technical_analysis).to eq("la ereditarietà non è rispettata")
    end

    it "mette gli accenti mancanti negli scenari a stringa" do
      plan = create_plan(scenarios: [ "il job e' gia partito" ])

      expect(plan.scenarios).to eq([ "il job è già partito" ])
    end

    it "mette gli accenti mancanti negli scenari strutturati senza toccarne le chiavi" do
      plan = create_plan(scenarios: [ { "given" => "la coda e' vuota", "when" => "arriva un piu' lento" } ])

      expect(plan.scenarios).to eq([ { "given" => "la coda è vuota", "when" => "arriva un più lento" } ])
    end

    it "mette gli accenti mancanti nella definition of done e nelle note" do
      plan = create_plan(definition_of_done: [ "la coda e' vuota" ], notes: [ "serve gia il worker" ])

      expect(plan.definition_of_done).to eq([ "la coda è vuota" ])
      expect(plan.notes).to eq([ "serve già il worker" ])
    end

    it "non tocca la motivazione scritta da chi rifiuta il piano" do
      plan = create_plan(change_request: "e' da rifare")

      expect(plan.change_request).to eq("e' da rifare")
    end
  end
end
