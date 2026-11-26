# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the comments of a linked issue land on the ticket, signed GitHub with the writer beside it.
RSpec.describe Github::Issues::Comments do
  let(:link) { create(:github_issue) }
  let(:account) do
    Github::Issues::SystemAccount.call(installation: link.repository.installation, project: link.repository.project).value
  end

  def comment(overrides = {})
    { "id" => 555, "body" => "Confermo, succede anche a me", "user" => { "login" => "bob" },
      "html_url" => "#{link.html_url}#issuecomment-555" }.merge(overrides)
  end

  it "a GitHub comment lands on the ticket with its twin id and the writer's GitHub name" do
    record = described_class.import(link:, comment:, account:).value

    expect(record).to have_attributes(body: "Confermo, succede anche a me", github_comment_id: 555,
                                      github_author_login: "bob", github_truncated: false, author: account)
    expect(record).to be_from_github
  end

  it "a 1000-character comment enters cut, with the link to the original" do
    record = described_class.import(link:, comment: comment("body" => "a" * 1000), account:).value

    expect(record.body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
    expect(record.body).to include("#{link.html_url}#issuecomment-555")
    expect(record.github_truncated).to be(true)
  end

  it "the same comment delivered twice lands once" do
    described_class.import(link:, comment:, account:)

    expect(described_class.import(link:, comment:, account:)).to be_nil
    expect(link.ticket.comments.where(github_comment_id: 555).count).to eq(1)
  end

  it "an imported comment does not go back to GitHub" do
    expect { described_class.import(link:, comment:, account:) }.not_to have_enqueued_job(Github::Issues::PushCommentJob)
  end

  it "follows the edits of a comment born on GitHub" do
    described_class.import(link:, comment:, account:)

    described_class.edit(link:, comment: comment("body" => "Anzi no, era la cache"))

    expect(link.ticket.comments.find_by(github_comment_id: 555).body).to eq("Anzi no, era la cache")
  end

  it "an empty comment, or one without an id, lands nowhere" do
    expect(described_class.import(link:, comment: comment("body" => "  "), account:)).to be_nil
    expect(described_class.import(link:, comment: comment("id" => nil), account:)).to be_nil
    expect(link.ticket.comments.where.not(github_comment_id: nil)).not_to exist
  end

  it "an edit emptied on GitHub keeps the text, and an edit of an unknown comment changes nothing" do
    described_class.import(link:, comment:, account:)

    expect(described_class.edit(link:, comment: comment("body" => "")).body).to eq("Confermo, succede anche a me")
    expect(described_class.edit(link:, comment: comment("id" => 999))).to be_nil
    expect(described_class.edit(link:, comment: comment("id" => nil))).to be_nil
  end

  it "a comment deleted on GitHub leaves the ticket; an unknown one changes nothing" do
    described_class.import(link:, comment:, account:)

    expect(described_class.delete(link:, comment: comment("id" => 999), account:)).to be_nil
    expect(described_class.delete(link:, comment:, account:)).to be_ok
    expect(link.ticket.comments.where(github_comment_id: 555)).not_to exist
  end

  it "brings every comment already on the issue, page after page" do
    first_page = Array.new(Github::Client::ISSUES_PAGE_SIZE) { |i| comment("id" => 1_000 + i, "body" => "Commento #{i}") }
    client = instance_double(Github::Client)
    allow(client).to receive(:issue_comments).and_return(first_page, [ comment("id" => 5_000, "body" => " ") ])

    imported = described_class.import_all(link:, account:, client:)

    expect(imported).to eq(Github::Client::ISSUES_PAGE_SIZE)
    expect(client).to have_received(:issue_comments).twice
  end
end
