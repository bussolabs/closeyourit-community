# frozen_string_literal: true

require "rails_helper"

# Query object dell'audit del Vault (CYRA-135): unifica in LETTURA gli eventi dei secret org-scoped
# (variabili di progetto, variabili shared, file) in righe normalizzate, filtrabili e paginabili.
# Scoping di sicurezza: gli eventi legati a un progetto sono limitati ai progetti visibili; gli eventi
# personali (account-scoped) NON entrano nell'audit org.
RSpec.describe Secrets::AuditQuery do
  describe "#rows" do
    it "restituisce gli eventi delle variabili dei progetti visibili, dal piu recente" do
      organization = create(:organization)
      project = create(:project, organization: organization)
      create(:secret_event, project: project, organization: organization,
                            action: "set", name: "API_KEY", created_at: 2.days.ago)
      create(:secret_event, project: project, organization: organization,
                            action: "deleted", name: "API_KEY", created_at: 1.hour.ago)

      query = described_class.new(organization: organization, visible_project_ids: [ project.id ])

      rows = query.rows

      expect(rows.map(&:action)).to eq(%w[deleted set])
      expect(rows.first.source).to eq(:variable)
      expect(rows.first.name).to eq("API_KEY")
    end

    it "esclude gli eventi dei progetti NON visibili (anti-BOLA)" do
      organization = create(:organization)
      visibile = create(:project, organization: organization)
      nascosto = create(:project, organization: organization)
      create(:secret_event, project: visibile, organization: organization, action: "set", name: "VISIBILE")
      create(:secret_event, project: nascosto, organization: organization, action: "set", name: "NASCOSTO")

      query = described_class.new(organization: organization, visible_project_ids: [ visibile.id ])

      expect(query.rows.map(&:name)).to eq(%w[VISIBILE])
    end

    it "include gli eventi delle variabili shared dell'organizzazione" do
      organization = create(:organization)
      Secrets::Shared::Event.create!(organization: organization, action: "created", name: "SHARED_KEY")

      query = described_class.new(organization: organization, visible_project_ids: [])

      rows = query.rows
      expect(rows.map(&:source)).to eq(%i[shared])
      expect(rows.first.name).to eq("SHARED_KEY")
    end

    it "include gli eventi dei file segreti dei progetti visibili" do
      organization = create(:organization)
      project = create(:project, organization: organization)
      Secrets::AssetEvent.create!(organization: organization, project: project, action: "uploaded")

      query = described_class.new(organization: organization, visible_project_ids: [ project.id ])

      expect(query.rows.map(&:source)).to eq(%i[file])
    end

    it "unisce i tre sorgenti ordinati dal piu recente" do
      organization = create(:organization)
      project = create(:project, organization: organization)
      create(:secret_event, project: project, organization: organization,
                            action: "set", name: "VAR", created_at: 3.hours.ago)
      Secrets::Shared::Event.create!(organization: organization, action: "created", name: "SHARED",
                                     created_at: 2.hours.ago)
      Secrets::AssetEvent.create!(organization: organization, project: project, action: "uploaded",
                                  created_at: 1.hour.ago)

      query = described_class.new(organization: organization, visible_project_ids: [ project.id ])

      expect(query.rows.map(&:source)).to eq(%i[file shared variable])
    end

    # CYRA-924 — registers sort on the date only, in both directions.
    it "lists the three sources oldest first when asked" do
      organization = create(:organization)
      project = create(:project, organization: organization)
      create(:secret_event, project: project, organization: organization,
                            action: "set", name: "VAR", created_at: 3.hours.ago)
      Secrets::Shared::Event.create!(organization: organization, action: "created", name: "SHARED",
                                     created_at: 2.hours.ago)
      Secrets::AssetEvent.create!(organization: organization, project: project, action: "uploaded",
                                  created_at: 1.hour.ago)

      query = described_class.new(organization: organization, visible_project_ids: [ project.id ],
                                  oldest_first: true, limit: 2)

      expect(query.rows.map(&:source)).to eq(%i[variable shared])
    end
  end

  describe "#rows con i filtri" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization) }

    def query(filters)
      described_class.new(organization: organization, visible_project_ids: [ project.id ], filters: filters)
    end

    it "filtra per azione" do
      create(:secret_event, project: project, organization: organization, action: "set", name: "A")
      create(:secret_event, project: project, organization: organization, action: "read", name: "B")

      expect(query(action: "set").rows.map(&:name)).to eq(%w[A])
    end

    it "filtra per ambiente" do
      env = create(:environment, organization: organization)
      altro = create(:environment, organization: organization)
      create(:secret_event, project: project, organization: organization, environment: env, action: "set", name: "IN")
      create(:secret_event, project: project, organization: organization, environment: altro, action: "set", name: "OUT")

      expect(query(environment_id: env.id).rows.map(&:name)).to eq(%w[IN])
    end

    it "filtra per periodo (from/to)" do
      create(:secret_event, project: project, organization: organization, action: "set", name: "VECCHIO",
                            created_at: 10.days.ago)
      create(:secret_event, project: project, organization: organization, action: "set", name: "DENTRO",
                            created_at: 2.days.ago)
      create(:secret_event, project: project, organization: organization, action: "set", name: "RECENTE",
                            created_at: 1.hour.ago)

      expect(query(from: 5.days.ago, to: 1.day.ago).rows.map(&:name)).to eq(%w[DENTRO])
    end

    it "cerca per nome (q, case-insensitive)" do
      create(:secret_event, project: project, organization: organization, action: "set", name: "DATABASE_URL")
      create(:secret_event, project: project, organization: organization, action: "set", name: "API_KEY")

      expect(query(q: "database").rows.map(&:name)).to eq(%w[DATABASE_URL])
    end

    it "filtra per attore" do
      actor = create(:account)
      create(:secret_event, project: project, organization: organization, actor: actor, action: "set", name: "MIO")
      create(:secret_event, project: project, organization: organization, action: "set", name: "ALTRUI")

      expect(query(actor_id: actor.id).rows.map(&:name)).to eq(%w[MIO])
    end
  end
end
