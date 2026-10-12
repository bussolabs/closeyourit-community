# frozen_string_literal: true

require "rails_helper"

# CYRA-1071 — the Map tab of a project: the app map read from the repository, read only.
RSpec.describe "Member::ProjectBlueprint (CYRA-1071)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:map) do
    JSON.generate("name" => "Shop", "nodes" => [
      { "id" => "app", "name" => "Shop app", "level" => 0, "parent" => nil, "kind" => "system", "summary" => "The shop.", "files" => [] },
      { "id" => "billing", "name" => "Billing", "level" => 1, "parent" => "app", "kind" => "area", "summary" => "Money.", "files" => [ "app/billing/**" ] },
      { "id" => "checkout", "name" => "Checkout", "level" => 2, "parent" => "billing", "kind" => "flow", "summary" => "Pay.", "files" => [] }
    ], "edges" => [])
  end

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def stub_file(content)
    allow(Github::Client).to receive(:new).and_return(instance_double(Github::Client, repository_file: content))
  end

  def page = Nokogiri::HTML(response.body)

  it "shows the map with its counts and a link to the file" do
    create(:github_repository, project:, full_name: "bussolabs/shop")
    stub_file(map)
    sign_in(owner)

    get member_project_blueprint_path(project)

    expect(response).to have_http_status(:ok)
    expect(page.at_css("[data-test='project-blueprint-link']")["aria-current"]).to eq("page")
    expect(page.at_css("[data-test='blueprint-graph']")).to be_present
    expect(page.at_css("[data-test='blueprint-count-flow']").text).to include("1")
    expect(page.at_css("[data-test='blueprint-source']")["href"]).to eq("https://github.com/bussolabs/shop/blob/main/blueprint.json")
    expect(JSON.parse(page.at_css("[data-controller='blueprint']")["data-blueprint-map-value"])["nodes"].size).to eq(3)
  end

  {
    no_repository: nil,
    missing: nil,
    invalid: "{ nope"
  }.each do |state, content|
    it "explains the #{state} state instead of drawing a graph" do
      create(:github_repository, project:) unless state == :no_repository
      stub_file(content)
      sign_in(owner)

      get member_project_blueprint_path(project)

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='blueprint-#{state.to_s.dasherize}']")).to be_present
      expect(page.at_css("[data-test='blueprint-graph']")).to be_nil
    end
  end

  it "explains when GitHub does not answer" do
    create(:github_repository, project:)
    allow(Github::Client).to receive(:new)
      .and_return(instance_double(Github::Client).tap { allow(it).to receive(:repository_file).and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001")) })
    sign_in(owner)

    get member_project_blueprint_path(project)

    expect(page.at_css("[data-test='blueprint-unreachable']")).to be_present
  end

  it "does not show a project of another organization" do
    other = create(:project)
    sign_in(owner)

    get member_project_blueprint_path(other)

    expect(response).to have_http_status(:not_found)
  end
end
