# frozen_string_literal: true

require "rails_helper"

# CYRA-1003 — the Automation tab shows one tab per step: each attempt lands in the tab of its step, and the
# tab that opens first is where the work is.
RSpec.describe Member::AutomationStepsHelper, type: :helper do
  def attempt(phase) = build_stubbed(:agent_attempt, phase:)

  describe "#automation_attempts_by_step" do
    it "puts each attempt in the step of its execution phase" do
      triage = attempt("triage")
      planner = attempt("planner")
      autopilot = attempt("autopilot")
      staging = attempt("closer_staging")

      by_step = helper.automation_attempts_by_step([ triage, planner, autopilot, staging ])

      expect(by_step).to eq("to_plan" => [ triage, planner ], "in_progress" => [ autopilot ], "closing" => [ staging ])
    end

    it "keeps an attempt of an unknown phase visible under In progress" do
      unknown = attempt("something_new")

      expect(helper.automation_attempts_by_step([ unknown ])).to eq("in_progress" => [ unknown ])
    end
  end

  describe "#automation_open_step" do
    def pipeline(states) = Agents::Workflows::PhaseResolver::STEPS.zip(states).map { |phase, state| { phase:, state: } }

    it "opens the current step" do
      states = %w[done done current pending pending pending]

      expect(helper.automation_open_step(pipeline(states), {})).to eq("in_progress")
    end

    it "opens the step where the work stopped" do
      states = %w[done done failed pending pending pending]

      expect(helper.automation_open_step(pipeline(states), {})).to eq("in_progress")
    end

    it "opens the last step with attempts when no step is current" do
      states = %w[pending pending pending pending pending pending]

      expect(helper.automation_open_step(pipeline(states), { "to_plan" => [ attempt("triage") ], "closing" => [ attempt("closer_staging") ] }))
        .to eq("closing")
    end

    it "opens the first step on a workflow that has done nothing yet" do
      states = %w[pending pending pending pending pending pending]

      expect(helper.automation_open_step(pipeline(states), {})).to eq("to_plan")
    end
  end

  describe "#work_report_status_icon" do
    it "draws a passed check and a proven criterion as a green check" do
      expect(helper.work_report_status_icon("passed").first).to eq("circle-check")
      expect(helper.work_report_status_icon("verified").first).to eq("circle-check")
      expect(helper.work_report_status_icon("passed").last).to include("text-emerald-600")
    end

    it "draws a failure as a red cross and a partial proof as an amber mark" do
      expect(helper.work_report_status_icon("failed")).to eq([ "circle-x", "text-red-600 dark:text-red-400" ])
      expect(helper.work_report_status_icon("missing").first).to eq("circle-x")
      expect(helper.work_report_status_icon("partial").first).to eq("circle-alert")
    end

    it "draws anything not run or unknown as a grey dashed circle" do
      expect(helper.work_report_status_icon("not_run").first).to eq("circle-dashed")
      expect(helper.work_report_status_icon("whatever").first).to eq("circle-dashed")
    end
  end
end
