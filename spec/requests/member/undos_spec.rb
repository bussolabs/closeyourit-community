# frozen_string_literal: true

require "rails_helper"

# CYRA-1150 — the Undo offered by the toast after a bulk action on errors, slowness and notifications.
RSpec.describe "Member::Undos", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:colleague) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: colleague, organization: org, role: :admin)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def bulk_errors(groups, action)
    post bulk_triage_member_monitoring_error_groups_path, params: { ids: groups.map(&:id), bulk_action: action }
    flash[:undo]
  end

  def persisted(records)
    rows = records.first.class.where(id: records.map(&:id)).to_a
    expect(rows.map(&:id)).to match_array(records.map(&:id))
    rows
  end

  context "with errors resolved by mistake" do
    let(:groups) do
      create_list(:error_group, 12, project:, status: :ignored, resolution_cause: "old cause", resolution_fix: "old fix")
    end

    before { sign_in(owner) }

    it "puts every group back as it was, notes included" do
      undo_id = bulk_errors(groups, "resolve")
      expect(persisted(groups).map(&:status)).to all(eq("resolved"))

      post member_undo_path(undo_id)

      expect(response).to redirect_to(member_monitoring_error_groups_path)
      expect(flash[:notice]).to eq(I18n.t("member.undo.restored", count: 12))
      persisted(groups).each do |group|
        expect(group).to have_attributes(status: "ignored", resolution_cause: "old cause", resolution_fix: "old fix")
      end
    end

    it "leaves the group a colleague reopened in the meantime, and says so" do
      undo_id = bulk_errors(groups, "resolve")
      Errors::Triage.call(group: groups.first.reload, action: "reopen")

      post member_undo_path(undo_id)

      expect(flash[:notice]).to include(I18n.t("member.undo.restored", count: 11), I18n.t("member.undo.kept", count: 1))
      expect(groups.first.reload).to be_status_unresolved
      expect(persisted(groups.drop(1)).map(&:status)).to all(eq("ignored"))
    end

    it "refuses once the time is over: the action stays done" do
      undo_id = bulk_errors(groups, "resolve")

      travel(Undo::Entry::TTL + 1.second) { post member_undo_path(undo_id) }

      expect(flash[:alert]).to eq(I18n.t("member.undo.expired"))
      expect(persisted(groups).map(&:status)).to all(eq("resolved"))
    end
  end

  it "answers that a colleague's undo does not exist, and changes nothing" do
    group = create(:error_group, project:, status: :unresolved)
    sign_in(owner)
    undo_id = bulk_errors([ group ], "resolve")

    sign_in(colleague)
    post member_undo_path(undo_id)

    expect(response).to have_http_status(:not_found)
    expect(group.reload).to be_status_resolved
  end

  it "offers no undo when the bulk action changed nothing" do
    group = create(:error_group, project:, status: :resolved)
    sign_in(owner)

    expect(bulk_errors([ group ], "resolve")).to be_nil
  end

  it "puts back slowness groups ignored together and refreshes the open lists" do
    groups = create_list(:metric_group, 3, project:, status: :unresolved)
    sign_in(owner)
    post bulk_triage_member_monitoring_metric_groups_path, params: { ids: groups.map(&:id), bulk_action: "ignore" }
    undo_id = flash[:undo]
    allow(Metrics::Broadcast).to receive(:refresh_list)

    post member_undo_path(undo_id)

    expect(response).to redirect_to(member_monitoring_metric_groups_path)
    expect(persisted(groups).map(&:status)).to all(eq("unresolved"))
    expect(Metrics::Broadcast).to have_received(:refresh_list).with(org, projects: [ project ])
  end

  context "with notifications" do
    def own_notification(**attrs)
      create(:alerting_notification, organization: org, account: owner, via: :in_app, **attrs)
    end

    it "marks unread again only the ones that were unread" do
      unread = Array.new(40) { own_notification(read_at: nil) }
      read_before = own_notification(read_at: 2.days.ago)
      sign_in(owner)

      patch read_all_member_alerting_notifications_path
      undo_id = flash[:undo]
      expect(persisted(unread).map(&:read_at)).to all(be_present)

      post member_undo_path(undo_id)

      expect(flash[:notice]).to eq(I18n.t("member.undo.restored", count: 40))
      expect(persisted(unread).map(&:read_at)).to all(be_nil)
      expect(read_before.reload.read_at).to be_present
    end

    it "offers undo on a row grouping several unread notifications" do
      representative = own_notification(read_at: nil)
      sibling = own_notification(read_at: nil)
      sign_in(owner)

      patch read_member_alerting_notification_path(representative, ids: [ sibling.id ])
      post member_undo_path(flash[:undo])

      expect(persisted([ representative, sibling ]).map(&:read_at)).to all(be_nil)
    end

    it "keeps a single notification read without a toast" do
      notification = own_notification(read_at: nil)
      sign_in(owner)

      patch read_member_alerting_notification_path(notification)

      expect(flash[:undo]).to be_nil
      expect(notification.reload.read_at).to be_present
    end
  end
end
