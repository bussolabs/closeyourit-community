# frozen_string_literal: true

require "rails_helper"

# F021, F061, F088 — C1, C4, C9: the table of an area page has a search, a "with problems" filter and
# a sort on every column, like any other list.
RSpec.describe "Member — area table bar", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:quiet) { create(:project, organization:, name: "Quiet") }
  let!(:late) { create(:project, organization:, name: "Late") }
  let!(:busy) { create(:project, organization:, name: "Busy") }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    # Rows are created in bulk: the N+1 belongs to the factory, not to the request under test.
    allow_n_plus_one do
      create(:ticket, project: late, organization:, due_at: 2.days.ago)
      create_list(:ticket, 2, project: busy, organization:)
    end
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def project_rows
    Capybara.string(response.body).all("[data-test^='product-row-']").map { |row| row["data-test"].delete_prefix("product-row-") } - [ "all" ]
  end

  it "searches the projects by name" do
    get member_product_path, params: { q: "bus" }

    expect(response.body).to include('data-test="product-search"')
    expect(project_rows).to eq([ busy.id ])
  end

  it "keeps only the projects with a red cell" do
    get member_product_path, params: { health: "problems" }

    expect(response.body).to include('data-test="product-filter-health"')
    expect(project_rows).to eq([ late.id ])
  end

  it "sorts on a column, both ways" do
    get member_product_path, params: { sort: "-open" }
    expect(project_rows).to eq([ busy.id, late.id, quiet.id ])

    get member_product_path, params: { sort: "open" }
    expect(project_rows.first).to eq(quiet.id)
  end

  # F122 — J4: the Automation table opens on the project with a blocked automation.
  it "automation: the project with a blocked automation comes first" do
    allow_n_plus_one do
      create(:agent_workflow, ticket: create(:ticket, project: quiet, organization:), blocked_at: 1.hour.ago,
                              blocked_phase: "planner", blocked_kind: "attempt_limit")
    end

    get member_automation_path

    rows = Capybara.string(response.body).all("[data-test^='automation-row-']").map { |row| row["data-test"].delete_prefix("automation-row-") } - [ "all" ]
    expect(rows.first).to eq(quiet.id)
  end

  it "says no project matches, with a way to clear the filters" do
    get member_product_path, params: { q: "nothing-like-this" }

    expect(response.body).to include('data-test="product-no-match"', 'data-test="product-reset-filters"')
  end
end
