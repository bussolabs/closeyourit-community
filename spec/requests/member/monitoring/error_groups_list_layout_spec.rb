# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the Errors list reorganised in the style of the Projects pages: the range is a filter
# chip, the ticket sits next to the status, a Sort menu, the project named in the header, shorter
# times, "not tracked" said once, a trend per row and an empty list that says when the last error came.
RSpec.describe "Member::Monitoring error list layout", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Payments API") }
  let(:other_project) { create(:project, organization: org, name: "Dashboard") }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  def header_labels = html.css("[data-test='error-groups-table'] thead th").map { |th| th.text.squish }

  describe "time range as a filter chip" do
    before { create(:error_group, project:, last_seen_at: 1.hour.ago) }

    it "drops the always-visible range buttons" do
      get member_monitoring_error_groups_path

      expect(html.at_css("[data-test='time-range']")).to be_nil
      expect(html.at_css("[data-test='filter-menu-range']")).to be_present
    end

    it "keeps the chip hidden on the default range" do
      get member_monitoring_error_groups_path(range: "24h")

      expect(html.at_css("[data-test='filter-chip-range']")["hidden"]).not_to be_nil
    end

    it "shows the chip with the chosen range" do
      get member_monitoring_error_groups_path(range: "7d")

      chip = html.at_css("[data-test='filter-chip-range']")
      expect(chip["hidden"]).to be_nil
      expect(chip.at_css("input[name='range']")["value"]).to eq("7d")
      expect(chip.at_css("button[data-value='7d']")["aria-pressed"]).to eq("true")
      expect(chip.css("button[data-value]").map { |option| option["data-value"] }).to eq([ "", "30m", "7d", "30d" ])
    end

    it "offers the two dates inside the chip for a custom range" do
      get member_monitoring_error_groups_path(range: "custom", from: "2026-07-09T14:00")

      chip = html.at_css("[data-test='filter-chip-range']")
      expect(chip.at_css("input[name='from']")["value"]).to eq("2026-07-09T14:00")
      expect(chip.at_css("input[name='to']")).to be_present
    end

    it "treats a toolbar submit without a range as the default instead of restoring the remembered one" do
      get member_monitoring_error_groups_path(range: "7d")

      get member_monitoring_error_groups_path(ft: "1")

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-test='filter-chip-range']")["hidden"]).not_to be_nil
    end
  end

  describe "status counts" do
    it "names the set-aside errors the way the table does" do
      create(:error_group, project:, status: :ignored)

      get member_monitoring_error_groups_path

      expect(html.at_css("[data-test='stat-ignored']").text).to include("ignored")
    end
  end

  describe "ticket next to the status" do
    it "has no Ticket column and shows the ticket inside the status cell" do
      ticket = create(:ticket, project:)
      group = create(:error_group, project:, ticket:)

      get member_monitoring_error_groups_path

      expect(header_labels).not_to include("Ticket")
      status_cell = html.at_css("[data-test='error-group-status-#{group.id}']")
      expect(status_cell.at_css("[data-test='error-group-ticket-#{group.id}']").text).to include(ticket.code)
    end
  end

  # CYRA-924 — the column headers sort and the counts line counts: the bar repeats neither.
  describe "toolbar" do
    it "has no sort menu and no count" do
      create(:error_group, project:)

      get member_monitoring_error_groups_path(sort: "-events")

      expect(html.at_css("[data-test='errors-sort']")).to be_nil
      expect(html.at_css("[data-test='errors-count']")).to be_nil
      expect(html.at_css("[data-test='errors-toolbar'] select[name='sort']")).to be_nil
    end

    it "keeps the column sort when the bar is submitted" do
      create(:error_group, project:)

      get member_monitoring_error_groups_path(sort: "-events")

      expect(html.at_css("[data-test='errors-toolbar'] input[type='hidden'][name='sort']")["value"]).to eq("-events")
    end
  end

  describe "a single project in view" do
    before do
      create(:error_group, project:)
      create(:error_group, project: other_project)
    end

    it "names the project in the breadcrumb with a way back to it" do
      get member_monitoring_error_groups_path(project_id: [ project.id ])

      expect(html.at_css("nav[aria-label] a[href='#{member_project_path(project)}']")&.text).to include("Payments API")
      expect(html.at_css("[data-test='errors-project-back']")["href"]).to eq(member_project_path(project))
    end

    it "hides the Project column, which would repeat the same name" do
      get member_monitoring_error_groups_path(project_id: [ project.id ])

      wrapper = html.at_css("[data-test='errors-results-layout']")
      expect(wrapper["data-single-project"]).not_to be_nil
      expect(html.at_css("[data-test='errors-col-project']")["class"]).to include("group-data-[single-project]:hidden")
    end

    it "keeps the Project column and the plain header with more projects" do
      get member_monitoring_error_groups_path(project_id: [ project.id, other_project.id ])

      expect(html.at_css("[data-test='errors-results-layout']")["data-single-project"]).to be_nil
      expect(html.at_css("[data-test='errors-project-back']")).to be_nil
    end
  end

  describe "last seen" do
    it "reads short, with the exact time in the tooltip" do
      seen = 3.days.ago.change(usec: 0)
      group = create(:error_group, project:, last_seen_at: seen)

      get member_monitoring_error_groups_path(range: "7d")

      cell = html.at_css("[data-test='error-group-last-seen-#{group.id}']")
      expect(cell.text.strip).to eq("3d ago")
      expect(cell["title"]).to eq(I18n.l(seen, format: :long))
    end
  end

  describe "users not tracked" do
    it "says it once in the column header when no row tracks users" do
      create(:error_group, project:, users_count: 0)

      get member_monitoring_error_groups_path

      expect(html.at_css("[data-test='errors-results-layout']")["data-users-untracked"]).not_to be_nil
      expect(html.at_css("[data-test='errors-users-untracked-note']")["href"]).to eq(member_guides_errors_path)
    end

    it "keeps the per-row wording when some row tracks users" do
      create(:error_group, project:, users_count: 0)
      create(:error_group, project:, users_count: 4)

      get member_monitoring_error_groups_path

      expect(html.at_css("[data-test='errors-results-layout']")["data-users-untracked"]).to be_nil
      expect(html.at_css("[data-test='errors-users-untracked-note']")).to be_nil
    end
  end

  describe "empty list for the range" do
    it "says when the last error came and widens the range to include it" do
      create(:error_group, project:, last_seen_at: 40.days.ago)

      get member_monitoring_error_groups_path

      expect(html.at_css("[data-test='errors-last-error']").text).to include("40d ago")
      href = html.at_css("[data-test='errors-widen-range']")["href"]
      expect(href).to include("range=custom")
      expect(href).to include("from=#{40.days.ago.to_date.iso8601}")
    end

    it "keeps the 30-day widening when that is enough" do
      create(:error_group, project:, last_seen_at: 10.days.ago)

      get member_monitoring_error_groups_path

      expect(html.at_css("[data-test='errors-widen-range']")["href"]).to include("range=30d")
    end

    it "says that nothing ever arrived for these filters" do
      create(:error_group, project:, last_seen_at: 1.hour.ago)
      create(:error_group, project: other_project, last_seen_at: 1.hour.ago, level: :warning)

      get member_monitoring_error_groups_path(level: [ "fatal" ])

      expect(html.at_css("[data-test='errors-never']")).to be_present
      expect(html.at_css("[data-test='errors-last-error']")).to be_nil
    end
  end

  describe "second line of a row" do
    it "puts the code location before the badges" do
      group = create(:error_group, project:, culprit: "App::Widget#render", has_unhandled: true)

      get member_monitoring_error_groups_path

      line = html.at_css("[data-test='error-group-title-#{group.id}']").parent.to_html
      expect(line.index("error-group-culprit-#{group.id}")).to be < line.index("error-group-unhandled-#{group.id}")
    end
  end

  describe "in Italian" do
    let(:owner) { create(:account, locale: "it") }

    it "renders the short times, the tooltip dates and the widening day" do
      create(:error_group, project:, last_seen_at: 3.days.ago, status: :ignored)
      create(:error_group, project: other_project, last_seen_at: 40.days.ago)

      get member_monitoring_error_groups_path(range: "7d", status: [ "ignored" ])

      expect(response).to have_http_status(:ok)
      expect(html.text).to include("3 g fa")
      expect(html.at_css("[data-test='stat-ignored']").text).to include("ignorati")

      get member_monitoring_error_groups_path(project_id: [ other_project.id ], range: "24h")

      expect(html.at_css("[data-test='errors-widen-range']").text).to include("Guarda fino al")
    end
  end

  describe "trend per row" do
    it "draws the events of the range as bars" do
      group = create(:error_group, project:, last_seen_at: 1.hour.ago)
      create(:error_event, group:, occurred_at: 2.hours.ago)
      create(:error_event, group:, occurred_at: 1.hour.ago)

      get member_monitoring_error_groups_path

      trend = html.at_css("[data-test='error-group-trend-#{group.id}']")
      bars = trend.css("[data-trend-bar]")
      expect(bars.size).to eq(24)
      expect(bars.map { |bar| bar["data-count"].to_i }.sum).to eq(2)
    end
  end
end
