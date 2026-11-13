# frozen_string_literal: true

require "rails_helper"

# CYRA-1292 — a delivery proves each "done when" of its plan, or a person decides.
RSpec.describe Agents::Candidates::EvidenceCheck do
  def evidence(id, status) = { "criterion_id" => id, "status" => status, "evidence" => "seen", "source" => "reported" }
  def test_run(status) = { "name" => "rspec", "status" => status }

  # A report written inline arrives as string-keyed keywords; `check(nil)` is a delivery with no report.
  def check(report = :inline, criteria: %w[DOD-1 DOD-2], **inline)
    described_class.call(work_report: report == :inline ? inline : report, criterion_ids: criteria)
  end

  it "clears a delivery that verified every criterion and passed its tests" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "verified"), evidence("DOD-2", "verified") ],
                    "tests" => [ test_run("passed") ])

    expect(verdict).to have_attributes(review?: false, reasons: [])
  end

  it "asks for a person when a proof is partial or missing" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "partial"), evidence("DOD-2", "missing") ],
                    "tests" => [ test_run("passed") ])

    expect(verdict.reasons).to eq(%w[evidence_incomplete])
    expect(verdict.incomplete).to eq(%w[DOD-1 DOD-2])
  end

  it "asks for a person when a criterion of the plan has no proof at all" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "verified") ], "tests" => [ test_run("passed") ])

    expect(verdict.reasons).to eq(%w[evidence_absent])
    expect(verdict.absent).to eq(%w[DOD-2])
  end

  # CYAU-329 — the Tester saw the criterion pass: what the agent declared about it no longer decides.
  it "takes a criterion the Tester saw pass as complete, declared partial or not declared at all" do
    verdict = described_class.call(
      work_report: { "acceptance_evidence" => [ evidence("DOD-1", "partial") ], "tests" => [ test_run("passed") ] },
      criterion_ids: %w[DOD-1 DOD-2], attested_ids: %w[DOD-1 DOD-2]
    )

    expect(verdict).to have_attributes(review?: false, reasons: [])
  end

  it "asks for a person when the delivery carries no work report" do
    expect(check(nil).reasons).to eq(%w[evidence_absent tests_not_run])
    expect(check(nil).absent).to eq(%w[DOD-1 DOD-2])
  end

  it "asks for a person when a test failed" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "verified"), evidence("DOD-2", "verified") ],
                    "tests" => [ test_run("passed"), test_run("failed") ])

    expect(verdict.reasons).to eq(%w[tests_failed])
    expect(verdict.tests_failed).to eq(1)
  end

  it "asks for a person when a test did not run" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "verified"), evidence("DOD-2", "verified") ],
                    "tests" => [ test_run("not_run") ])

    expect(verdict.reasons).to eq(%w[tests_not_run])
  end

  it "asks for a person when no test is reported" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "verified"), evidence("DOD-2", "verified") ])

    expect(verdict.reasons).to eq(%w[tests_not_run])
  end

  it "does not look for criteria when the plan carries none with an id" do
    verdict = check("acceptance_evidence" => [ evidence("DOD-1", "verified") ], "tests" => [ test_run("passed") ],
                    criteria: [])

    expect(verdict).not_to be_review
  end

  it "serialises to a hash a ticket event can keep" do
    record = check("acceptance_evidence" => [ evidence("DOD-1", "missing") ], "tests" => [ test_run("failed") ]).to_h

    expect(record).to include(reasons: %w[evidence_incomplete evidence_absent tests_failed],
                              incomplete: %w[DOD-1], absent: %w[DOD-2], tests_failed: 1, tests_not_run: 0)
  end
end
