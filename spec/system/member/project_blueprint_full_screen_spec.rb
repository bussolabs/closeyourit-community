# frozen_string_literal: true

require "rails_helper"

# CYRA-1071 — the Map tab in full screen: the graph takes the whole window and the index lists the
# whole map as a tree, in step with the graph.
RSpec.describe "Project map in full screen", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:map) do
    JSON.generate("name" => "Shop", "nodes" => [
      { "id" => "rails", "name" => "Shop app", "level" => 0, "parent" => nil, "kind" => "system", "summary" => "The shop.", "files" => [] },
      { "id" => "billing", "name" => "Billing", "level" => 1, "parent" => "rails", "kind" => "area", "summary" => "Money.", "files" => [] },
      { "id" => "catalog", "name" => "Catalog", "level" => 1, "parent" => "rails", "kind" => "area", "summary" => "Goods.", "files" => [] },
      { "id" => "checkout", "name" => "Checkout", "level" => 2, "parent" => "billing", "kind" => "flow", "summary" => "Pay.", "files" => [] }
    ], "edges" => [ { "from" => "catalog", "to" => "billing" } ])
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:github_repository, project:, full_name: "bussolabs/shop")
    allow(Github::Client).to receive(:new).and_return(instance_double(Github::Client, repository_file: map))
    sign_in_as(owner)
    visit member_project_blueprint_path(project)
  end

  def tree = find("[data-test='blueprint-tree']")

  it "opens the index next to the graph and leaves with Esc" do
    expect(page).to have_no_css("[data-test='blueprint-index']", visible: :visible)

    click_on_test "blueprint-full"

    expect(page).to have_css("[data-controller='blueprint'][data-full]")
    expect(tree).to have_button("Shop app").and have_button("Billing").and have_button("Catalog")
    expect(tree).to have_no_button("Checkout")

    find("body").send_keys(:escape)

    expect(page).to have_no_css("[data-controller='blueprint'][data-full]")
    expect(page).to have_no_css("[data-test='blueprint-index']", visible: :visible)
  end

  it "shows in the graph the bubble picked in the index" do
    click_on_test "blueprint-full"
    tree.click_button("Billing")

    expect(tree).to have_css("button[aria-current='true']", text: "Billing")
    expect(tree).to have_button("Checkout")
    expect(find("[data-test='blueprint-detail']")).to have_text("Money.")
  end

  it "filters the index by name" do
    click_on_test "blueprint-full"
    fill_test "blueprint-index-filter", with: "check"

    expect(tree).to have_button("Checkout").and have_button("Billing")
    expect(tree).to have_no_button("Catalog")
  end
end
