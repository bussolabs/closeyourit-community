# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::EvaluateJob do
  it "gira sulla coda :alerts" do
    expect(described_class.new.queue_name).to eq("alerts")
  end

  it "delega ad Alerting::Evaluate con gli argomenti ricevuti" do
    allow(Alerting::Evaluate).to receive(:call).and_return(Result.ok(0))

    described_class.perform_now(
      event_type: "error_new", subject_type: "Errors::Group", subject_id: "sid",
      project_id: "pid", environment: "production", level: 3
    )

    expect(Alerting::Evaluate).to have_received(:call)
      .with(hash_including(event_type: "error_new", subject_type: "Errors::Group",
                           subject_id: "sid", project_id: "pid", environment: "production", level: 3))
  end
end
