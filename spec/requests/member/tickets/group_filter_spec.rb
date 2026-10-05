# frozen_string_literal: true

require "rails_helper"

# CYRA-866 — the Group filter takes every project of the Group at once, on list and board. It stays
# within the tickets the viewer can already see.
RSpec.describe "Filtro per Gruppo sui ticket", type: :request do
  let(:org) { create(:organization) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:group) { create(:group, organization: org, name: "DriverOne") }
  let(:rails_app) { create(:project, organization: org, group: group) }
  let(:flutter_app) { create(:project, organization: org, group: group) }
  let(:outside) { create(:project, organization: org) }
  let(:member) do
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: :member)
      [ rails_app, flutter_app, outside ].each { |p| create(:project_membership, account: account, project: p) }
    end
  end
  let!(:in_rails) { create(:ticket, :story, organization: org, project: rails_app, status: status) }
  let!(:in_flutter) { create(:ticket, :story, organization: org, project: flutter_app, status: status) }
  let!(:elsewhere) { create(:ticket, :story, organization: org, project: outside, status: status) }

  def sign_in(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  before { sign_in(member) }

  { "lista" => :list_member_tickets_path, "bacheca" => :member_tickets_path }.each do |page, path|
    it "#{page}: il Gruppo mostra i ticket di tutti i suoi progetti e nessun altro" do
      get send(path), params: { group_id: [ group.id ] }

      expect(response.body).to include(in_rails.code, in_flutter.code)
      expect(response.body).not_to include(elsewhere.code)
    end

    it "#{page}: la barra offre il Gruppo fra i filtri" do
      get send(path)

      select = Nokogiri::HTML(response.body).at_css("[data-test='filter-group']")
      expect(select).to be_present
      expect(select.to_html).to include("DriverOne")
    end
  end

  it "un Gruppo senza progetti visibili non compare fra le scelte" do
    hidden = create(:group, organization: org, name: "Nascosto")
    create(:project, organization: org, group: hidden)

    get list_member_tickets_path

    expect(Nokogiri::HTML(response.body).at_css("[data-test='filter-group']").to_html).not_to include("Nascosto")
  end

  it "il Gruppo si somma agli altri filtri" do
    get list_member_tickets_path, params: { group_id: [ group.id ], project_id: [ rails_app.id ] }

    expect(response.body).to include(in_rails.code)
    expect(response.body).not_to include(in_flutter.code)
  end

  it "il Gruppo di un progetto non assegnato non apre i suoi ticket" do
    secret = create(:project, organization: org, group: group)
    hidden_ticket = create(:ticket, :story, organization: org, project: secret, status: status)

    get list_member_tickets_path, params: { group_id: [ group.id ] }

    expect(response.body).not_to include(hidden_ticket.code)
  end
end
