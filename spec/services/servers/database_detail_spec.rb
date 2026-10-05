# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::DatabaseDetail do
  let(:organization) { create(:organization) }
  let(:hosts) { ::Servers::Host.where(organization:) }
  let(:projects) { ::Projects::Project.where(organization:) }

  def db_host(name, databases, role: nil, replicas: 0, top_tables: nil)
    replication = { "streaming" => true, "replicas" => Array.new(replicas) { { "client" => "10.0.0.12" } } } if replicas.positive?
    create(:server_host, :up, organization:, name:, last_seen_at: Time.current,
           database_snapshot: { "engine" => "postgresql", "version" => "17.2", "role" => role,
                                "replication" => replication, "databases" => databases,
                                "top_tables" => top_tables }.compact)
  end

  def call(host:, name:) = described_class.call(host:, name:, hosts:, projects:)

  it "ritorna nil se il database non sta su quell'host" do
    host = db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 10 } ])

    expect(call(host:, name: "mai_visto")).to be_nil
  end

  it "riporta dimensione, quota, motore e versione della macchina aperta" do
    host = db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 750 },
                                   { "name" => "altro", "size_bytes" => 250 } ])

    detail = call(host:, name: "app_production")

    expect(detail.name).to eq("app_production")
    expect(detail.size_bytes).to eq(750)
    expect(detail.share_pct).to eq(75.0)
    expect(detail.host_total_bytes).to eq(1000)
    expect(detail.engine).to eq("postgresql")
    expect(detail.version).to eq("17.2")
  end

  describe "dove si trova" do
    it "elenca il primary e la sua copia con le rispettive dimensioni" do
      primary = db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 800 } ],
                        role: "primary", replicas: 1)
      db_host("db-standby", [ { "name" => "app_production", "size_bytes" => 803 } ], role: "standby")

      presences = call(host: primary, name: "app_production").presences

      expect(presences.map(&:host_name)).to eq(%w[db-primary db-standby])
      expect(presences.map(&:size_bytes)).to eq([ 800, 803 ])
      expect(presences.map(&:host_role)).to eq(%w[primary standby])
      expect(presences.first.last_seen_at).to be_present
    end

    it "elenca il gruppo anche aprendo la pagina dalla copia" do
      db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 800 } ],
              role: "primary", replicas: 1)
      standby = db_host("db-standby", [ { "name" => "app_production", "size_bytes" => 803 } ], role: "standby")

      presences = call(host: standby, name: "app_production").presences

      expect(presences.map(&:host_name)).to eq(%w[db-primary db-standby])
    end

    it "resta una sola presenza quando la copia non è riconosciuta come tale" do
      primary = db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 800 } ], role: "primary")
      # Nessuna replica dichiarata dal primary: le due macchine restano distinte.
      db_host("db-altro", [ { "name" => "app_production", "size_bytes" => 803 } ], role: "standby")

      presences = call(host: primary, name: "app_production").presences

      expect(presences.map(&:host_name)).to eq(%w[db-primary])
    end
  end

  describe "tabelle più grandi" do
    it "tiene solo quelle del database aperto, dalla più grande" do
      host = db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 800 } ],
                     top_tables: [ { "database" => "app_production", "name" => "public.events", "size_bytes" => 200 },
                                   { "database" => "altro_db", "name" => "public.rumore", "size_bytes" => 900 },
                                   { "database" => "app_production", "name" => "public.logs", "size_bytes" => 400 } ])

      tables = call(host:, name: "app_production").tables

      expect(tables.map(&:name)).to eq(%w[public.logs public.events])
      expect(tables.map(&:size_bytes)).to eq([ 400, 200 ])
    end

    it "resta vuota se l'agent non riporta tabelle di quel database" do
      host = db_host("db-primary", [ { "name" => "app_production", "size_bytes" => 800 } ])

      expect(call(host:, name: "app_production").tables).to be_empty
    end
  end

  describe "progetto dedotto dal nome" do
    let!(:environment) { create(:environment, organization:, code: "production") }
    let!(:project) { create(:project, organization:, key: "KORU", name: "Koru") }

    it "riconosce il progetto dal prefisso del nome" do
      host = db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 10 } ])

      expect(call(host:, name: "koru_production").project).to eq(project)
    end

    it "riconosce anche il database delle code" do
      host = db_host("db-primary", [ { "name" => "koru_queue_production", "size_bytes" => 10 } ])

      expect(call(host:, name: "koru_queue_production").project).to eq(project)
    end

    it "non deduce nulla se nessun progetto combacia" do
      host = db_host("db-primary", [ { "name" => "sconosciuto_production", "size_bytes" => 10 } ])

      expect(call(host:, name: "sconosciuto_production").project).to be_nil
    end

    it "non deduce nulla se il progetto è di un'altra organizzazione" do
      altro = create(:project, name: "Estraneo", key: "EXTR")
      expect(altro.organization_id).not_to eq(organization.id)
      host = db_host("db-primary", [ { "name" => "extr_production", "size_bytes" => 10 } ])

      expect(call(host:, name: "extr_production").project).to be_nil
    end

    it "non deduce nulla quando due progetti sono compatibili" do
      # Stesso nome, chiave diversa: due candidati per "koru" → ambiguo (la key ha 4 caratteri).
      create(:project, organization:, key: "KOR2", name: "Koru")
      host = db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 10 } ])

      expect(call(host:, name: "koru_production").project).to be_nil
    end
  end
end
