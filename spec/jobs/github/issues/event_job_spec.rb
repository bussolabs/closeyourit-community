# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — each kind of issue delivery reaches its handler.
RSpec.describe Github::Issues::EventJob, type: :job do
  {
    "issues" => Github::Webhooks::Issues,
    "issue_comment" => Github::Webhooks::IssueComment,
    "projects_v2_item" => Github::Webhooks::ProjectsV2Item
  }.each do |event, handler|
    it "sends #{event} to #{handler.name}" do
      payload = { "action" => "edited" }
      allow(handler).to receive(:call)

      described_class.perform_now(event:, payload:, key: "I_1")

      expect(handler).to have_received(:call).with(payload:)
    end
  end
end
