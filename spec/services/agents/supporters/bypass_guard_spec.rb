# frozen_string_literal: true

require "rails_helper"

# CYRA-1197 — the actions a machine may never approve on its own, matched by the server.
RSpec.describe Agents::Supporters::BypassGuard do
  it "names the gates a text tries to skip" do
    expect(described_class.match("Then run kamal deploy from the machine")).to eq([ "manual_deploy" ])
    expect(described_class.match("git push --force origin ticket/ABC-1")).to eq([ "force_push" ])
    expect(described_class.match("git push origin main")).to eq([ "push_to_main" ])
    expect(described_class.match("commit with --no-verify")).to eq([ "skip_hooks" ])
    expect(described_class.match("DROP TABLE users")).to eq([ "destructive_sql" ])
    expect(described_class.match("RAILS_ENV=production bin/rails db:reset")).to eq([ "destructive_task" ])
    expect(described_class.match("cyi secrets get STRIPE_KEY")).to eq([ "secret_read" ])
    expect(described_class.match("Skip the failing tests to make CI green")).to eq([ "skip_tests" ])
  end

  # Guidance spells out the rules as prohibitions: forbidding a bypass is not proposing one.
  it "ignores a gate named right after a negation" do
    expect(described_class.match("Run only the specs you touched. Do not skip checks, do not push to main.")).to eq([])
    expect(described_class.match("Commit normally, with no --no-verify.")).to eq([])
    expect(described_class.match("Do not skip or delete tests.")).to eq([])
    expect(described_class.match("Never use --no-verify to get green")).to eq([])
    expect(described_class.match("Non usare mai --no-verify")).to eq([])
  end

  # CYRA-1197 — "do not use --no-verify or [skip ci]": the second gate of the list shares the first one's negation.
  it "ignores every gate of a list that follows a negation" do
    expect(described_class.match("Do not use --no-verify or [skip ci].")).to eq([])
    expect(described_class.match("Do not delete or skip tests, and do not use --no-verify or [skip ci]. Push to the ticket branch only.")).to eq([])
  end

  it "still names the gates of a list nobody forbids" do
    expect(described_class.match("Use --no-verify or [skip ci]")).to eq(%w[skip_hooks skip_ci skip_tests])
    expect(described_class.match("Don't hesitate to use --no-verify")).to eq([ "skip_hooks" ])
  end

  it "still names a gate when the negation belongs to another clause" do
    expect(described_class.match("Do not worry, commit with --no-verify")).to eq([ "skip_hooks" ])
    expect(described_class.match("No tests are red. Skip the failing tests anyway")).to eq([ "skip_tests" ])
    expect(described_class.match("Never use --no-verify, [skip ci] instead")).to eq(%w[skip_ci skip_tests])
    expect(described_class.match("If it does not pass, then git push --force")).to eq([ "force_push" ])
    expect(described_class.match("Do not stop: skip the tests")).to eq([ "skip_tests" ])
  end

  it "names a gate proposed once even when it is also forbidden elsewhere" do
    expect(described_class.match("Do not skip the tests. Then skip the tests to ship.")).to eq([ "skip_tests" ])
  end

  it "lets ordinary work through" do
    expect(described_class.match("Sort the list by name in app/views/items/index.html.erb and add a spec")).to eq([])
    expect(described_class.match("git push origin ticket/ABC-1")).to eq([])
    expect(described_class.match("Deploy goes through GitHub Actions on the tag")).to eq([])
  end
end
