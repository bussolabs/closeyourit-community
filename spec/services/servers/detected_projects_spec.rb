# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::DetectedProjects, type: :service do
  let(:organization) { create(:organization) }
  let(:host) { create(:server_host, organization: organization) }

  # Progetto dell'org reso uptime-capable (unico caso in cui una macchina è collegabile).
  def uptime_project(name)
    project = create(:project, organization: organization, name: name)
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: organization))
    project
  end

  def container(name)
    create(:server_container_sample, host: host, name: name, recorded_at: 1.minute.ago)
  end

  def call(containers: [], linked_project_ids: [])
    described_class.call(host: host, projects: organization.projects,
                         containers: containers, linked_project_ids: linked_project_ids)
  end

  it "propone un progetto riconosciuto dal nome di un container" do
    project = uptime_project("CloseYourIt")

    expect(call(containers: [ container("closeyourit-web-1a2b") ])).to eq([ project ])
  end

  it "propone un progetto riconosciuto dal nome di un database" do
    project = uptime_project("Acme")
    host.update!(database_snapshot: { "databases" => [ { "name" => "acme_production" } ] })

    expect(call).to eq([ project ])
  end

  it "non propone un progetto già collegato alla macchina" do
    project = uptime_project("CloseYourIt")

    result = call(containers: [ container("closeyourit-web-1a2b") ], linked_project_ids: [ project.id ])

    expect(result).to be_empty
  end

  it "non propone un progetto senza corrispondenza nei dati della macchina" do
    uptime_project("Acme")

    expect(call(containers: [ container("closeyourit-web-1a2b") ])).to be_empty
  end

  it "non propone un progetto che non è uptime-capable" do
    create(:project, organization: organization, name: "CloseYourIt")

    expect(call(containers: [ container("closeyourit-web-1a2b") ])).to be_empty
  end

  it "ignora gli slug troppo corti per non pescare mezzo mondo" do
    uptime_project("Db")

    expect(call(containers: [ container("db") ])).to be_empty
  end

  it "richiede il segmento intero, non una sottostringa del nome rilevato" do
    uptime_project("App")

    # "myapp-web" → segmenti [myapp, web]: "app" non compare come segmento intero.
    expect(call(containers: [ container("myapp-web") ])).to be_empty
  end

  it "propone in ordine alfabetico di nome" do
    zeta = uptime_project("Zeta")
    alfa = uptime_project("Alfa")

    result = call(containers: [ container("zeta-web"), container("alfa-worker") ])

    expect(result).to eq([ alfa, zeta ])
  end
end
