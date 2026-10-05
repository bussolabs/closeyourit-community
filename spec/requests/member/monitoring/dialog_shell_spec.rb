# frozen_string_literal: true

require "rails_helper"

# F24 — every monitoring dialog opens in the standard shell: the dark ground, a page header panel
# that holds the actions, the content in its own panel. The wiring stays on the <dialog>.
RSpec.describe "Monitoring dialogs in the standard modal shell", type: :request do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) }
  end
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  def expect_standard_shell(dialog_test_id, header_test_ids)
    dialog = Nokogiri::HTML(response.body).at_css("dialog[data-test='#{dialog_test_id}']")
    expect(dialog).to be_present
    expect(dialog["class"]).to include("bg-stone-100", "dark:bg-zinc-950", "rounded-xl")
    expect(dialog["data-ui--dialog-target"]).to eq("dialog")
    expect(dialog["data-action"]).to eq("click->ui--dialog#backdrop")
    header = dialog.at_css("header")
    expect(header).to be_present
    header_test_ids.each { |test_id| expect(header.at_css("[data-test='#{test_id}']")).to be_present }
    expect(header.at_css("[data-action='ui--dialog#close']")).to be_present
    # A dialog nested in this one (ungroup inside the incident modal) brings its own close.
    own_closes = dialog.css("[data-action='ui--dialog#close']").select { |node| node.ancestors("dialog").first == dialog }
    expect(own_closes.size).to eq(1)
    dialog
  end

  describe "monitor page" do
    let(:monitor) { create(:uptime_monitor, project:, environment:, public_status_enabled: true) }

    it "opens the incident dialogs in the standard shell" do
      incident = create(:uptime_incident, monitor:, phase: :monitoring, started_at: 2.hours.ago, resolved_at: 1.hour.ago)
      create(:uptime_incident_update, incident:, phase: :detected)
      create(:uptime_incident, monitor:, parent: incident, started_at: 3.hours.ago, resolved_at: 150.minutes.ago)

      get member_monitoring_monitor_path(monitor)

      expect_standard_shell("incident-manage-dialog-#{incident.id}", [ "incident-delete-#{incident.id}" ])
      ungroup = expect_standard_shell("incident-ungroup-dialog", [ "incident-ungroup-submit" ])
      expect(ungroup.at_css("form header")).to be_present
      update = expect_standard_shell("incidents-update-dialog", [ "incident-update-submit" ])
      expect(update.at_css("form[data-action='submit->ui--bulk-select#injectIds'] header")).to be_present
    end

    it "opens the embed dialog in the standard shell" do
      get member_monitoring_monitor_path(monitor, tab: "public")

      expect_standard_shell("monitor-embed-dialog", [])
    end
  end

  describe "error group page" do
    let(:group) { create(:error_group, project:, title: "RuntimeError: boom") }

    it "opens the resolve, promote and delete dialogs in the standard shell" do
      get member_monitoring_error_group_path(group)

      resolve = expect_standard_shell("resolve-dialog", [ "resolve-confirm" ])
      expect(resolve.at_css("form[data-test='resolve-form'] header")).to be_present
      expect_standard_shell("promote-preview-dialog", [ "promote-preview-confirm" ])
      expect_standard_shell("delete-dialog", [ "delete-confirm" ])
    end
  end

  describe "cluster page" do
    it "opens the namespace dialog in the standard shell" do
      cluster = create(:cluster, organization: org, name: "production-eu")
      namespace = create(:cluster_namespace, cluster:, name: "shop")

      get member_monitoring_cluster_path(cluster)

      dialog = expect_standard_shell("cluster-namespace-dialog-#{namespace.id}", [ "cluster-namespace-submit-#{namespace.id}" ])
      expect(dialog.at_css("form[data-test='cluster-namespace-form-#{namespace.id}'] header")).to be_present
    end
  end
end
