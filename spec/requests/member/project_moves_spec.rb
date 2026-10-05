# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectMoves", type: :request do
  let(:source) { create(:organization, name: "Source Org") }
  let(:destination) { create(:organization, name: "Destination Org") }
  let(:owner) { create(:account) }
  let(:admin) { create(:account) }
  let(:project) { create(:project, organization: source) }
  let(:group) { create(:group, organization: source, name: "Storefront") }

  before do
    create(:membership, account: owner, organization: source, role: :owner)
    create(:membership, account: owner, organization: destination, role: :owner)
    create(:membership, account: admin, organization: source, role: :admin)
    create(:membership, account: admin, organization: destination, role: :admin)
  end

  # Two memberships make the active organization arbitrary: the source is chosen explicitly.
  def sign_in(account)
    post(login_path, params: { email: account.email, password: "Secret123!" })
    post(member_organization_switches_path, params: { organization_id: source.id })
  end

  describe "a project" do
    it "offers only the other organizations the actor owns" do
      create(:membership, account: owner, organization: create(:organization, name: "Merely Member Org"), role: :member)
      sign_in(owner)
      get new_member_project_move_path(project)
      expect(response).to have_http_status(:ok)
      select = Nokogiri::HTML(response.body).at_css("select[name='destination_id']")
      expect(select.css("option").map(&:text)).to eq([ "Destination Org" ])
    end

    it "shows the preview to an owner of both organizations" do
      sign_in(owner)
      get preview_member_project_move_path(project), params: { destination_id: destination.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Destination Org")
    end

    it "lists blockers and disables the confirmation" do
      create(:project, organization: destination, key: project.key)
      sign_in(owner)
      get preview_member_project_move_path(project), params: { destination_id: destination.id }
      blockers = Nokogiri::HTML(response.body).at_css("[data-test='move-blockers']")
      expect(blockers.text).to include(project.key)
      expect(Nokogiri::HTML(response.body).at_css("[data-test='move-submit']")["disabled"]).to be_present
    end

    it "lists what the move creates and the links it detaches" do
      project.update!(group:)
      project.environments << create(:environment, organization: source, code: "qa", label: "Quality")
      sign_in(owner)
      get preview_member_project_move_path(project), params: { destination_id: destination.id }
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-test='move-creations']").text).to include("Quality (qa)")
      expect(page.at_css("[data-test='move-detachment-projects_groups']")).to be_present
      expect(response.body).not_to include("translation missing")
    end

    it "lists the Knowledge pages and book that move along and the pages that stay" do
      book = create(:knowledge_book, organization: source, project:, title: "Runbooks")
      create(:knowledge_page, project:, book:)
      create(:knowledge_page, project:).projects << create(:project, organization: source)
      sign_in(owner)
      get preview_member_project_move_path(project), params: { destination_id: destination.id }
      page = Nokogiri::HTML(response.body)
      expect(page.css("[data-test='move-creation']").size).to eq(2)
      expect(page.at_css("[data-test='move-creations']").text).to include("Runbooks")
      expect(page.at_css("[data-test='move-detachment-connections_page_projects']")).to be_present
      expect(response.body).not_to include("translation missing")
    end

    it "refuses an admin, even with a direct request" do
      sign_in(admin)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
      expect(response).to redirect_to(root_path)
      expect(Projects::Move.count).to eq(0)
    end

    it "refuses a plain member, even with a direct request" do
      member = create(:account)
      create(:membership, account: member, organization: source, role: :member)
      create(:membership, account: member, organization: destination, role: :member)
      sign_in(member)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
      expect(response).to redirect_to(root_path)
      expect(Projects::Move.count).to eq(0)
    end

    it "refuses a destination the actor does not own" do
      other = create(:organization)
      create(:membership, account: owner, organization: other, role: :member)
      sign_in(owner)
      post member_project_move_path(project), params: { destination_id: other.id, confirm: project.key }
      expect(response).to have_http_status(:not_found)
      expect(Projects::Move.count).to eq(0)
    end

    it "requires the project key typed as confirmation" do
      sign_in(owner)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: "nope" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Projects::Move.count).to eq(0)
    end

    it "enqueues the move and redirects to its status" do
      sign_in(owner)
      expect do
        post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
      end.to have_enqueued_job(Projects::Moves::ExecuteJob)
      move = Projects::Move.last
      expect(move).to have_attributes(subject_id: project.id, source_organization_id: source.id,
                                      destination_organization_id: destination.id, requested_by_id: owner.id)
      expect(response).to redirect_to(member_project_move_status_path(project, move))
    end

    it "does not enqueue a blocked move" do
      create(:project, organization: destination, key: project.key)
      sign_in(owner)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Projects::Move.count).to eq(0)
    end

    it "accepts the typed key with surrounding spaces, still case-sensitive" do
      sign_in(owner)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: " #{project.key.downcase} " }
      expect(response).to have_http_status(:unprocessable_content)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: " #{project.key} " }
      expect(response).to redirect_to(member_project_move_status_path(project, Projects::Move.sole))
    end

    context "when a concurrent submit wins the race after planning" do
      def race_with(requested_by)
        allow(Projects::Moves::Plan).to receive(:call).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap do
            @winner = Projects::Move.create!(subject: project, source_organization: source,
                                             destination_organization: destination, requested_by:)
          end
        end
      end

      it "follows the move the same account already started" do
        race_with(owner)
        sign_in(owner)
        post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
        expect(response).to redirect_to(member_project_move_status_path(project, @winner))
        expect(Projects::Move.count).to eq(1)
      end

      it "shows the move in progress as a blocker when another account started it" do
        race_with(admin)
        sign_in(owner)
        post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
        expect(response).to have_http_status(:unprocessable_content)
        expect(Nokogiri::HTML(response.body).at_css("[data-test='move-blocker-move_in_progress']")).to be_present
      end
    end

    it "fails a stale running move before planning, so it no longer blocks" do
      stale = Projects::Move.create!(subject: project, source_organization: source, destination_organization: destination,
                                     requested_by: owner, status: :running)
      stale.update_columns(updated_at: 1.hour.ago)
      sign_in(owner)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
      expect(stale.reload).to be_failed
      expect(response).to redirect_to(member_project_move_status_path(project, Projects::Move.where.not(id: stale.id).sole))
    end
  end

  describe "while impersonating" do
    let(:god) { create(:account, god: true) }

    before do
      enable_two_factor!(god)
      post(login_path, params: { email: god.email, password: "Secret123!" })
      complete_two_factor(god)
      start_impersonation_as(god, account_id: owner.id)
      post(member_organization_switches_path, params: { organization_id: source.id })
    end

    it "refuses a god acting as an owner of both organizations" do
      get new_member_project_move_path(project)
      expect(response).to redirect_to(root_path)
      get preview_member_project_move_path(project), params: { destination_id: destination.id }
      expect(response).to redirect_to(root_path)
      post member_project_move_path(project), params: { destination_id: destination.id, confirm: project.key }
      expect(response).to redirect_to(root_path)
      expect(Projects::Move.count).to eq(0)
    end
  end

  describe "a group" do
    it "shows the preview to an owner of both organizations" do
      sign_in(owner)
      get preview_member_group_move_path(group), params: { destination_id: destination.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Destination Org")
    end

    it "refuses an admin, even with a direct request" do
      sign_in(admin)
      post member_group_move_path(group), params: { destination_id: destination.id, confirm: group.name }
      expect(response).to redirect_to(root_path)
      expect(Projects::Move.count).to eq(0)
    end

    it "requires the group name typed as confirmation" do
      sign_in(owner)
      post member_group_move_path(group), params: { destination_id: destination.id, confirm: "nope" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Projects::Move.count).to eq(0)
    end

    it "enqueues the move and redirects to its status" do
      sign_in(owner)
      expect do
        post member_group_move_path(group), params: { destination_id: destination.id, confirm: group.name }
      end.to have_enqueued_job(Projects::Moves::ExecuteJob)
      expect(response).to redirect_to(member_group_move_status_path(group, Projects::Move.last))
    end
  end

  describe "the status page" do
    def move_for(requested_by, status:, **attributes)
      Projects::Move.create!(subject: project, source_organization: source, destination_organization: destination,
                             requested_by:, status:, **attributes)
    end

    it "refreshes itself while the move runs" do
      move = move_for(owner, status: :pending)
      sign_in(owner)
      get member_project_move_status_path(project, move)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('http-equiv="refresh"')
    end

    it "shows the real error of a failed move" do
      move = move_for(owner, status: :failed, error_message: "key_taken: MOVE")
      sign_in(owner)
      get member_project_move_status_path(project, move)
      expect(response.body).to include("key_taken: MOVE")
      expect(response.body).not_to include('http-equiv="refresh"')
    end

    it "is readable after success and offers the switch to the destination" do
      move = move_for(owner, status: :succeeded)
      project.update_columns(organization_id: destination.id)
      sign_in(owner)
      get member_project_move_status_path(project, move)
      expect(response).to have_http_status(:ok)
      switch = Nokogiri::HTML(response.body).at_css("[data-test='move-open-destination']")
      expect(switch.ancestors("form").first["action"]).to eq(member_organization_switches_path)
      form = switch.ancestors("form").first
      expect(form.at_css("input[name='organization_id']")["value"]).to eq(destination.id)
      expect(form.at_css("input[name='return_to']")["value"]).to eq(member_project_path(project))
    end

    it "is not readable by another account" do
      move = move_for(admin, status: :pending)
      sign_in(owner)
      get member_project_move_status_path(project, move)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the entry points" do
    it "shows the move button to the owner on the project settings and the group page" do
      sign_in(owner)
      get member_project_settings_path(project)
      expect(response.body).to include(new_member_project_move_path(project))
      get member_group_path(group)
      expect(response.body).to include(new_member_group_move_path(group))
    end

    it "hides the move button from an admin" do
      sign_in(admin)
      get member_project_settings_path(project)
      expect(response.body).not_to include(new_member_project_move_path(project))
      get member_group_path(group)
      expect(response.body).not_to include(new_member_group_move_path(group))
    end

    it "hides the move button from an owner of a single organization" do
      solo = create(:account)
      create(:membership, account: solo, organization: create(:organization), role: :owner)
      solo_project = create(:project, organization: solo.memberships.first.organization)
      post(login_path, params: { email: solo.email, password: "Secret123!" })
      get member_project_settings_path(solo_project)
      expect(response.body).not_to include(new_member_project_move_path(solo_project))
    end
  end
end
