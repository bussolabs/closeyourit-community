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

  it "lets ordinary work through" do
    expect(described_class.match("Sort the list by name in app/views/items/index.html.erb and add a spec")).to eq([])
    expect(described_class.match("git push origin ticket/ABC-1")).to eq([])
    expect(described_class.match("Deploy goes through GitHub Actions on the tag")).to eq([])
  end
end
