# frozen_string_literal: true

FactoryBot.define do
  factory :environment_host, class: "Connections::EnvironmentHost" do
    # Progetto persistito + environment DICHIARATO dal progetto + host della stessa org.
    project { create(:project) }
    environment { create(:environment, organization: project.organization).tap { |e| project.environments << e } }
    host { association(:server_host, organization: project.organization) }

    # Il link esiste solo su progetti uptime-capable (stesso hook della factory :uptime_monitor).
    after(:build) do |link|
      project = link.project
      if project && !project.platforms.uptime_capable.exists?
        project.project_platforms.create!(
          platform: create(:platform, :uptime_capable, organization: project.organization)
        )
      end
    end
  end
end
