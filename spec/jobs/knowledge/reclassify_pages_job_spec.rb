# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ReclassifyPagesJob, type: :job do
  include ActiveJob::TestHelper

  it "accoda un giro per ogni pagina pubblicata o in revisione mai giudicata" do
    published = create(:knowledge_page, status: :published)
    waiting = create(:knowledge_page, status: :in_review)
    create(:knowledge_page, status: :rejected)
    create(:knowledge_page, status: :published, ai_reviewed_at: Time.current)

    described_class.perform_now(dry_run: true)

    jobs = enqueued_jobs.select { |job| job["job_class"] == "Knowledge::ReviewPageJob" }
    expect(jobs.map { |job| job["arguments"].first["page_id"] }).to contain_exactly(published.id, waiting.id)
    expect(jobs.first["arguments"].first).to include("dry_run" => true, "force" => false)
    expect(jobs.first["queue_name"]).to eq("knowledge_review")
  end

  it "senza force riprende anche le bocciate dal dry_run ancora pubblicate, non le accettate" do
    demote_me = create(:knowledge_page, status: :published, ai_reviewed_at: Time.current, ai_review_verdict: :rejected)
    create(:knowledge_page, status: :published, ai_reviewed_at: Time.current, ai_review_verdict: :accepted)

    described_class.perform_now
    jobs = enqueued_jobs.select { |job| job["job_class"] == "Knowledge::ReviewPageJob" }
    expect(jobs.map { |job| job["arguments"].first["page_id"] }).to eq([ demote_me.id ])
  end

  it "legacy rigiudica tutto, anche le accettate, e passa il flag" do
    create(:knowledge_page, status: :published, ai_reviewed_at: Time.current, ai_review_verdict: :accepted)

    described_class.perform_now(legacy: true, dry_run: true)
    jobs = enqueued_jobs.select { |job| job["job_class"] == "Knowledge::ReviewPageJob" }
    expect(jobs.size).to eq(1)
    expect(jobs.first["arguments"].first).to include("legacy" => true, "force" => true, "dry_run" => true)
  end

  it "con force riprende anche le già giudicate" do
    create(:knowledge_page, status: :published, ai_reviewed_at: Time.current)

    described_class.perform_now(force: true)
    expect(enqueued_jobs.count { |job| job["job_class"] == "Knowledge::ReviewPageJob" }).to eq(1)
  end
end
