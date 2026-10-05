# frozen_string_literal: true

require "rails_helper"

# CYRA-63: la gestione capability/server è nella tab Environments; la panoramica è in sola lettura.
RSpec.describe "Member::Projects environment capabilities (tab) + read-only overview", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  # Progetto uptime-capable con 2 ambienti dichiarati: uno eredita (capability default), uno con
  # override uptime+servers OFF.
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let!(:link_on) { create(:project_environment, project:, environment: create(:environment, organization: org, code: "production")) }
  let!(:link_off) do
    create(:project_environment, project:, environment: create(:environment, organization: org, code: "staging"),
                                 uptime_enabled: false, servers_enabled: false)
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "tab Environments (gestione)" do
    it "mostra i controlli tri-state per ogni ambiente dichiarato" do
      get member_project_environments_path(project)
      expect(response.body).to include("env-cap-#{link_on.environment_id}-uptime-inherit")
      expect(response.body).to include("env-cap-#{link_off.environment_id}-servers-off")
    end

    it "nasconde il multiselect server dove la capability servers è OFF (mostra la nota) e lo mostra dove ON" do
      # Without a linkable host the card says "no servers yet" instead of the form (CYRA-883).
      create(:server_host, organization: org)
      get member_project_environments_path(project)
      expect(response.body).to include("project-servers-form-#{link_on.environment_id}")
      expect(response.body).to include("project-servers-disabled-#{link_off.environment_id}")
      expect(response.body).not_to include("project-servers-form-#{link_off.environment_id}")
    end

    it "offre 'aggiungi monitor' dove la capability uptime è ON, non dove è OFF" do
      get member_project_environments_path(project)
      expect(response.body).to include("project-uptime-add-#{link_on.environment_id}")
      expect(response.body).not_to include("project-uptime-add-#{link_off.environment_id}")
    end
  end

  describe "panoramica in sola lettura" do
    it "non mostra i controlli di gestione (capacità/server/dialog)" do
      get member_project_path(project)
      expect(response.body).not_to include('data-test="project-capabilities"')
      expect(response.body).not_to include('data-test="project-servers"')
      expect(response.body).not_to include("env-cap-#{link_on.environment_id}-servers-inherit")
      expect(response.body).not_to include("project-servers-form-#{link_on.environment_id}")
    end

    it "mostra l'uptime in sola lettura, senza il link 'aggiungi monitor'" do
      get member_project_path(project)
      expect(response.body).to include('data-test="project-uptime"')
      expect(response.body).not_to include("project-uptime-add-#{link_on.environment_id}")
      expect(response.body).not_to include("project-uptime-disabled-#{link_off.environment_id}")
    end
  end
end
