# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member groups visibility (count + index)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def empty_groups_row(body)
    Capybara.string(body).find("[data-test='projects-empty-groups']")
  end

  describe "GET projects index — group scoping per member" do
    it "shows the member only the groups assigned to them" do
      assigned = create(:group, organization: org, name: "Assigned")
      create(:group, organization: org, name: "Hidden")
      create(:group_membership, account: member, group: assigned)
      create(:project_membership, account: member, project: create(:project, organization: org))

      sign_in(member)
      get member_projects_path

      expect(response).to have_http_status(:ok)
      expect(empty_groups_row(response.body)).to have_text("Assigned")
      expect(empty_groups_row(response.body)).to have_no_text("Hidden")
    end

    it "shows the owner every group of the organization" do
      create(:group, organization: org, name: "First")
      create(:group, organization: org, name: "Second")
      create(:project, organization: org)

      sign_in(owner)
      get member_projects_path

      expect(empty_groups_row(response.body)).to have_text("First")
      expect(empty_groups_row(response.body)).to have_text("Second")
    end
  end

  describe "GET groups index — no leak" do
    it "il member (con project_groups.view) vede solo i gruppi a cui ha accesso" do
      assigned = create(:group, organization: org, name: "Assigned")
      other = create(:group, organization: org, name: "Hidden")
      create(:group_membership, account: member, group: assigned)
      # La index gruppi è gated da project_groups.view (regime RBAC); lo scoping della lista resta
      # visible.groups → il member entra ma vede solo i gruppi assegnati.
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "project_groups.view" ], actor: owner
      )

      sign_in(member)
      get member_groups_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Assigned")
      expect(response.body).not_to include("Hidden")
      expect(response.body).not_to include(member_group_path(other))
    end
  end

  # CYRA-362 — a group without projects must stay visible; since CYRA-883 it sits in one row at the bottom.
  describe "GET projects index — groups without projects" do
    before { sign_in(owner) }

    it "lists the empty group in the bottom row, not as a section of its own" do
      full = create(:group, organization: org, name: "Full")
      empty = create(:group, organization: org, name: "Empty")
      create(:project, organization: org, group: full)

      get member_projects_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='projects-group-#{full.id}']")
      expect(html).to have_no_css("section[data-test='projects-group-#{empty.id}']")
      expect(empty_groups_row(response.body)).to have_css("[data-test='projects-empty-group-#{empty.id}']", text: "Empty")
    end

    it "shows a visible manage link on each group section" do
      group = create(:group, organization: org, name: "Full")
      create(:project, organization: org, group: group)

      get member_projects_path

      link = Capybara.string(response.body).find("[data-test='projects-manage-group-#{group.id}']")
      expect(link[:href]).to eq(member_group_path(group))
      expect(link).to have_text(I18n.t("member.groups.manage"))
      expect(link[:class]).not_to include("opacity-0")
    end

    it "links the group name to the group page" do
      group = create(:group, organization: org, name: "Full")
      create(:project, organization: org, group: group)

      get member_projects_path

      link = Capybara.string(response.body).find("[data-test='projects-group-link-#{group.id}']")
      expect(link[:href]).to eq(member_group_path(group))
      expect(link).to have_text("Full")
    end

    it "hides the empty groups row while a search is active" do
      full = create(:group, organization: org, name: "Full")
      other = create(:group, organization: org, name: "Other")
      create(:project, organization: org, group: full, name: "Findable")
      create(:project, organization: org, group: other, name: "Hidden")

      get member_projects_path, params: { q: "Findable" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='projects-group-#{full.id}']")
      expect(html).to have_no_css("[data-test='projects-group-#{other.id}']")
      expect(html).to have_no_css("[data-test='projects-empty-groups']")
    end

    it "gives ungrouped projects their own section" do
      create(:project, organization: org)

      get member_projects_path

      expect(Capybara.string(response.body)).to have_css("[data-test='projects-ungrouped']")
    end
  end
end
