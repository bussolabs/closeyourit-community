# frozen_string_literal: true

require "rails_helper"

# CYRA-1146 — opening a ticket, an error or a monitor marks as read the viewer's own notifications
# about it, before the page renders: the bell on that page already shows the new count.
RSpec.describe "Member pages mark their notifications read on open", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:owner) { create(:account) }
  let(:colleague) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: colleague, organization: org, role: :admin)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def notify(subject, account: owner, event_type: :error_new)
    create(:alerting_notification, :unread, organization: org, project: project, account: account,
                                            subject: subject, event_type: event_type)
  end

  def badge_count = Nokogiri::HTML(response.body).at_css("#alerting_notification_badge")["data-pending-count"]

  # One query for all of them: reloading each row would trip the N+1 guard.
  def read_flags(notifications) = Alerting::Notification.where(id: notifications.map(&:id)).pluck(:read_at).map(&:present?)

  describe "ticket page" do
    let(:ticket) { create(:ticket, organization: org, project: project) }

    it "marks my notifications on the ticket read and lowers the bell" do
      mine = Array.new(3) { notify(ticket, event_type: :ticket_commented) }
      theirs = notify(ticket, account: colleague, event_type: :ticket_commented)
      other_ticket = notify(create(:ticket, organization: org, project: project), event_type: :ticket_commented)

      get member_ticket_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(read_flags(mine)).to all(be(true))
      expect(read_flags([ theirs, other_ticket ])).to all(be(false))
      expect(badge_count).to eq("1")
    end
  end

  describe "error page" do
    let(:group) { create(:error_group, project: project) }

    it "marks my notifications on the error read" do
      mine = [ notify(group), notify(group, event_type: :error_spike) ]
      theirs = notify(group, account: colleague)

      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(read_flags(mine)).to all(be(true))
      expect(theirs.reload.read?).to be(false)
      expect(badge_count).to eq("0")
    end
  end

  describe "monitor page" do
    let(:monitor) { create(:uptime_monitor, project: project) }

    it "marks my notifications on the monitor and its outages read" do
      incident = create(:uptime_incident, :resolved, monitor: monitor)
      mine = [ notify(incident, event_type: :uptime_down), notify(incident, event_type: :uptime_up),
               notify(monitor, event_type: :uptime_slow) ]
      other_monitor = notify(create(:uptime_incident, monitor: create(:uptime_monitor, project: project)),
                             event_type: :uptime_down)

      get member_monitoring_monitor_path(monitor)

      expect(response).to have_http_status(:ok)
      expect(read_flags(mine)).to all(be(true))
      expect(other_monitor.reload.read?).to be(false)
    end
  end

  describe "scheduled job page" do
    let(:monitor) { create(:cron_monitor, project: project) }

    it "marks my missed-run notifications read" do
      mine = notify(monitor, event_type: :cron_missed)

      get member_monitoring_cron_monitor_path(monitor)

      expect(response).to have_http_status(:ok)
      expect(mine.reload.read?).to be(true)
    end
  end
end
