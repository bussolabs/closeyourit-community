# frozen_string_literal: true

require "rails_helper"

# CYRA-1158 — the project's declared events: list, add, edit, remove, and the undeclared ones.
RSpec.describe "Member::Monitoring::Analytics::EventDefinitions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "lists the declared events with their property names" do
    create(:analytics_event_definition, project:, name: "Signup", property_names: %w[plan seats])

    get member_monitoring_analytics_event_definitions_path(project_id: project.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Signup", "plan, seats")
  end

  it "answers not found for a project the member cannot see" do
    other = create(:organization)
    Types::InstallDefaults.call(organization: other)
    foreign = create(:project, organization: other, analytics_enabled: true)
      .tap { |p| p.platforms << Types::Platform.find_by!(organization: other, code: "web") }
    create(:analytics_event_definition, project: foreign, name: "Secret")

    get member_monitoring_analytics_event_definitions_path(project_id: foreign.id)
    expect(response).to have_http_status(:not_found)
    get member_monitoring_analytics_undeclared_events_path(project_id: foreign.id)
    expect(response).to have_http_status(:not_found)
  end

  it "adds a declared event and returns to the list" do
    get new_member_monitoring_analytics_event_definition_path(project_id: project.id)
    expect(response.body).to include("data-test=\"analytics-event-definition-form\"")

    post member_monitoring_analytics_event_definitions_path(project_id: project.id),
         params: { analytics_event_definition: { name: "Signup", property_names: "plan, seats" } }

    expect(response).to redirect_to(member_monitoring_analytics_event_definitions_path(project_id: project.id))
    expect(project.analytics_event_definitions.sole.property_names).to eq(%w[plan seats])
  end

  it "shows the form again with the error under the field" do
    post member_monitoring_analytics_event_definitions_path(project_id: project.id),
         params: { analytics_event_definition: { name: "" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(Nokogiri::HTML(response.body).at_css("[data-test='analytics-event-definition-name-error']")).to be_present
  end

  it "edits and removes a declared event" do
    definition = create(:analytics_event_definition, project:, name: "Signup")

    get edit_member_monitoring_analytics_event_definition_path(definition, project_id: project.id)
    expect(response).to have_http_status(:ok)
    patch member_monitoring_analytics_event_definition_path(definition, project_id: project.id),
          params: { analytics_event_definition: { name: "Signup", property_names: "coupon" } }
    expect(definition.reload.property_names).to eq(%w[coupon])

    delete member_monitoring_analytics_event_definition_path(definition, project_id: project.id)
    expect(Analytics::EventDefinition.exists?(definition.id)).to be(false)
  end

  it "shows the undeclared events of the range with a button that declares them" do
    create(:pageview, project:, name: "Download", properties: { "file" => "a.pdf" }, occurred_at: 1.hour.ago)
    create(:pageview, project:, name: "Signup", occurred_at: 1.hour.ago)
    create(:analytics_event_definition, project:, name: "Signup")

    get member_monitoring_analytics_undeclared_events_path(project_id: project.id)

    html = Nokogiri::HTML(response.body)
    rows = html.css("[data-test='analytics-undeclared-row']")
    expect(rows.map { _1.text.squish }).to contain_exactly(a_string_including("Download", "file"))
    form = rows.first.at_css("form")
    expect(form["action"]).to eq(member_monitoring_analytics_event_definitions_path(project_id: project.id))
    expect(form.at_css("input[name='analytics_event_definition[property_names]']")["value"]).to eq("file")
  end
end
