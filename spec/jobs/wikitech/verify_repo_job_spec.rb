# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::VerifyRepoJob do
  let(:entry) { create(:wikitech_entry, repo_url: "https://github.com/godotengine/godot") }

  it "marks the card verified with the repository data and re-embeds it" do
    allow(Wikitech::GithubRepo).to receive(:call).and_return(Result.ok({ "stars" => 10 }))

    expect { described_class.perform_now(entry_id: entry.id) }.to have_enqueued_job(Wikitech::EmbedEntryJob)

    expect(entry.reload).to have_attributes(verification: "verified", repo_meta: { "stars" => 10 })
    expect(entry.repo_checked_at).to be_present
  end

  it "leaves the card unconfirmed when the repository does not exist" do
    allow(Wikitech::GithubRepo).to receive(:call)
      .and_return(Result.err(AppError.new("x", code: Wikitech::GithubRepo::NOT_FOUND, status: :not_found)))

    described_class.perform_now(entry_id: entry.id)

    expect(entry.reload).to have_attributes(verification: "unconfirmed")
    expect(entry.repo_checked_at).to be_present
  end

  it "comes back later when GitHub asks to wait" do
    allow(Wikitech::GithubRepo).to receive(:call).and_raise(Wikitech::GithubRepo::RateLimited.new(600))

    expect { described_class.perform_now(entry_id: entry.id) }.to have_enqueued_job(described_class)
  end

  it "raises a temporary failure so the job retries" do
    allow(Wikitech::GithubRepo).to receive(:call)
      .and_return(Result.err(AppError.new("x", code: Wikitech::GithubRepo::UNAVAILABLE, status: :service_unavailable)))

    expect { described_class.perform_now(entry_id: entry.id) }.to have_enqueued_job(described_class)
  end

  it "does nothing for a card without repository" do
    allow(Wikitech::GithubRepo).to receive(:call)

    described_class.perform_now(entry_id: create(:wikitech_entry).id)

    expect(Wikitech::GithubRepo).not_to have_received(:call)
  end
end
