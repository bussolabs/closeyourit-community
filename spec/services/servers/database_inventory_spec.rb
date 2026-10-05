# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::DatabaseInventory do
  let(:organization) { create(:organization) }

  def host_with(databases, name: "db-primary", **attrs)
    create(:server_host, :up, organization:, name:,
           database_snapshot: { "engine" => "postgresql", "reachable" => true,
                                "databases" => databases }.merge(attrs))
  end

  it "espande lo snapshot in una riga per database, con host e dimensione" do
    host = host_with([ { "name" => "app_production", "size_bytes" => 300 },
                       { "name" => "app_queue_production", "size_bytes" => 100 } ])

    rows = described_class.call(hosts: [ host ])

    expect(rows.map(&:name)).to eq(%w[app_production app_queue_production])
    expect(rows.map(&:size_bytes)).to eq([ 300, 100 ])
    expect(rows.map(&:host_id).uniq).to eq([ host.id ])
    expect(rows.first.host_name).to eq("db-primary")
    expect(rows.first.host_status).to eq("up")
    expect(rows.first.db_reachable).to be(true)
  end

  it "calcola la quota sul totale dei database dello STESSO host" do
    primary = host_with([ { "name" => "a", "size_bytes" => 750 }, { "name" => "b", "size_bytes" => 250 } ])
    staging = host_with([ { "name" => "c", "size_bytes" => 5 } ], name: "db-staging")

    rows = described_class.call(hosts: [ primary, staging ])

    expect(rows.find { |r| r.name == "a" }.share_pct).to eq(75.0)
    expect(rows.find { |r| r.name == "b" }.share_pct).to eq(25.0)
    # Host separato: la quota NON è sul totale della flotta, o "c" sarebbe irrilevante.
    expect(rows.find { |r| r.name == "c" }.share_pct).to eq(100.0)
  end

  it "espone il totale dei database dell'host come denominatore della quota (CYRA-466)" do
    primary = host_with([ { "name" => "a", "size_bytes" => 750 }, { "name" => "b", "size_bytes" => 250 } ])
    staging = host_with([ { "name" => "c", "size_bytes" => 5 } ], name: "db-staging")

    rows = described_class.call(hosts: [ primary, staging ])

    # Il denominatore consultabile nel tooltip è il totale dei SOLI database dell'host.
    expect(rows.find { |r| r.name == "a" }.host_total_bytes).to eq(1000)
    expect(rows.find { |r| r.name == "b" }.host_total_bytes).to eq(1000)
    expect(rows.find { |r| r.name == "c" }.host_total_bytes).to eq(5)
  end

  it "lascia la quota a nil quando il totale dell'host è zero" do
    host = host_with([ { "name" => "vuoto", "size_bytes" => 0 } ])

    expect(described_class.call(hosts: [ host ]).first.share_pct).to be_nil
  end

  it "ignora gli host senza blocco database e le voci senza nome" do
    without_snapshot = create(:server_host, :up, organization:, name: "web-1")
    unreachable = create(:server_host, :up, organization:, name: "db-down",
                         database_snapshot: { "engine" => "postgresql", "reachable" => false })
    dirty = host_with([ { "name" => "buono", "size_bytes" => 10 }, { "size_bytes" => 99 }, "spazzatura" ])

    rows = described_class.call(hosts: [ without_snapshot, unreachable, dirty ])

    expect(rows.map(&:name)).to eq(%w[buono])
  end

  it "tratta una dimensione mancante come zero senza esplodere" do
    host = host_with([ { "name" => "senza_dimensione" }, { "name" => "con_dimensione", "size_bytes" => 10 } ])

    rows = described_class.call(hosts: [ host ])

    expect(rows.map { |r| [ r.name, r.size_bytes ] })
      .to contain_exactly([ "senza_dimensione", 0 ], [ "con_dimensione", 10 ])
  end

  it "filtra per nome del database o del server, senza distinzione di maiuscole" do
    primary = host_with([ { "name" => "koru_production", "size_bytes" => 10 },
                          { "name" => "altro_staging", "size_bytes" => 20 } ])
    staging = host_with([ { "name" => "nulla_che_combacia", "size_bytes" => 30 } ], name: "db-STAGING")

    hosts = [ primary, staging ]

    expect(described_class.call(hosts:, q: "KORU").map(&:name)).to eq(%w[koru_production])
    # "staging" combacia col nome del secondo host e col nome di un database del primo.
    expect(described_class.call(hosts:, q: "staging").map(&:name))
      .to contain_exactly("altro_staging", "nulla_che_combacia")
  end

  describe "database presenti anche sulle repliche" do
    # Un primary dichiara le repliche connesse (`replication.replicas`): è il tetto di ciò che può
    # assorbire, e senza quella dichiarazione non assorbe nessuno.
    def primary_host(databases, name: "db-primary", replicas: 1, identifier: nil)
      host_with(databases, name:, "role" => "primary",
                **cluster(identifier),
                "replication" => { "streaming" => true,
                                   "replicas" => Array.new(replicas) { |i| { "client" => "10.0.1.#{i + 10}", "state" => "streaming" } } })
    end

    def standby_host(databases, name: "db-standby", identifier: nil)
      host_with(databases, name:, "role" => "standby", **cluster(identifier))
    end

    # Un agent < 0.6.0 non manda l'identificativo di cluster: assente, non vuoto.
    def cluster(identifier) = identifier ? { "system_identifier" => identifier } : {}

    it "accorpa la replica nella riga del primary, tenendo dimensione e quota del primary" do
      primary = primary_host([ { "name" => "app_production", "size_bytes" => 800 },
                               { "name" => "app_queue_production", "size_bytes" => 200 } ])
      # La replica riporta dimensioni leggermente diverse (WAL, bloat): la fonte resta il primary.
      standby_host([ { "name" => "app_production", "size_bytes" => 803 },
                     { "name" => "app_queue_production", "size_bytes" => 201 } ])

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map(&:name)).to eq(%w[app_production app_queue_production])
      row = rows.first
      expect(row.host_name).to eq("db-primary")
      expect(row.host_id).to eq(primary.id)
      expect(row.size_bytes).to eq(800)
      expect(row.share_pct).to eq(80.0)
      # Il denominatore resta il totale del primary (800+200), non raddoppiato dalla replica.
      expect(row.host_total_bytes).to eq(1000)
      expect(row.replica_host_names).to eq(%w[db-standby])
    end

    it "non accorpa se il primary non dichiara repliche connesse" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], replicas: 0)
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ])

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map(&:host_name)).to contain_exactly("db-primary", "db-standby")
      expect(rows.map(&:replica_host_names).flatten).to be_empty
    end

    it "assorbe al più le repliche che il primary dichiara" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], replicas: 1)
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-standby-a")
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-standby-b")

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      # Una sola replica dichiarata: la seconda resta una riga a sé, non si inventa un'appartenenza.
      expect(rows.map(&:host_name)).to contain_exactly("db-primary", "db-standby-b")
      expect(rows.find { |r| r.host_name == "db-primary" }.replica_host_names).to eq(%w[db-standby-a])
    end

    # CYRA-772 — l'esito non deve dipendere dall'ordine in cui il database consegna le macchine, che
    # PostgreSQL è libero di scegliere: senza un ordine esplicito questo caso passava in locale e
    # cadeva in CI, e in pagina mostrava due risultati diversi per gli stessi dati.
    it "assorbe sempre la stessa replica, comunque siano state registrate le macchine" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], replicas: 1)
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-standby-b")
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-standby-a")

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map(&:host_name)).to contain_exactly("db-primary", "db-standby-b")
      expect(rows.find { |r| r.host_name == "db-primary" }.replica_host_names).to eq(%w[db-standby-a])
    end

    it "elenca più repliche in ordine, una volta sola" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], replicas: 2)
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-standby-2")
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-standby-1")

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.size).to eq(1)
      expect(rows.first.replica_host_names).to eq(%w[db-standby-1 db-standby-2])
    end

    it "non accorpa nulla se due primary usano lo stesso nome di database (cluster distinti)" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-uno")
      primary_host([ { "name" => "app_production", "size_bytes" => 20 } ], name: "db-due")
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ])

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map(&:host_name)).to contain_exactly("db-uno", "db-due", "db-standby")
      expect(rows.map(&:replica_host_names).flatten).to be_empty
    end

    it "non accorpa una replica di un ALTRO cluster che ospita un database omonimo" do
      # Una replica in streaming è la copia dell'intero cluster: ospita esattamente gli stessi
      # database del suo primary. Un solo nome in comune non basta a dichiararla una sua copia.
      primary_host([ { "name" => "app_production", "size_bytes" => 10 },
                     { "name" => "app_queue_production", "size_bytes" => 5 } ])
      standby_host([ { "name" => "app_production", "size_bytes" => 10 },
                     { "name" => "altro_db", "size_bytes" => 7 } ], name: "db-altro-standby")

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map { |r| [ r.host_name, r.name ] }).to contain_exactly(
        [ "db-primary", "app_production" ], [ "db-primary", "app_queue_production" ],
        [ "db-altro-standby", "app_production" ], [ "db-altro-standby", "altro_db" ]
      )
      expect(rows.map(&:replica_host_names).flatten).to be_empty
    end

    it "assorbe la macchina giusta anche se due host si chiamano allo stesso modo" do
      # Il nome dell'host non è unico (l'unicità è sul fingerprint): l'assorbimento deve andare per id.
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ])
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-copia")
      gemello = standby_host([ { "name" => "altro_db", "size_bytes" => 3 } ], name: "db-copia")

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map { |r| [ r.host_id, r.name ] }).to contain_exactly(
        [ ::Servers::Host.find_by(name: "db-primary").id, "app_production" ],
        [ gemello.id, "altro_db" ]
      )
      expect(rows.find { |r| r.name == "app_production" }.replica_host_names).to eq(%w[db-copia])
    end

    it "tiene la riga della replica quando il suo primary non è visibile" do
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ])

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map(&:host_name)).to eq(%w[db-standby])
      expect(rows.first.replica_host_names).to be_empty
    end

    it "lascia stare gli host che non dichiarano un ruolo" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ])
      host_with([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-senza-ruolo")

      rows = described_class.call(hosts: ::Servers::Host.where(organization:))

      expect(rows.map(&:host_name)).to contain_exactly("db-primary", "db-senza-ruolo")
      expect(rows.map(&:replica_host_names).flatten).to be_empty
    end

    it "trova la riga accorpata cercando il nome della replica" do
      primary_host([ { "name" => "app_production", "size_bytes" => 10 } ])
      standby_host([ { "name" => "app_production", "size_bytes" => 10 } ])

      rows = described_class.call(hosts: ::Servers::Host.where(organization:), q: "standby")

      expect(rows.map(&:host_name)).to eq(%w[db-primary])
      expect(rows.first.replica_host_names).to eq(%w[db-standby])
    end

    # Dall'agent 0.6.0 il legame non si deduce più: primary e repliche riportano lo stesso
    # identificativo di cluster, quindi l'appartenenza è un fatto e non un indizio.
    describe "quando gli host dichiarano l'identificativo del cluster" do
      let(:cluster_a) { "7234567890123456789" }
      let(:cluster_b) { "1111111111111111111" }

      it "accorpa anche se il primary non dichiara repliche connesse" do
        # Una replica appena riavviata non compare ancora in pg_stat_replication: l'euristica la
        # lasciava fuori, l'identificativo dice che è dello stesso cluster comunque.
        primary_host([ { "name" => "app_production", "size_bytes" => 800 } ], replicas: 0, identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 800 } ], identifier: cluster_a)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name)).to eq(%w[db-primary])
        expect(rows.first.replica_host_names).to eq(%w[db-standby])
        expect(rows.first.size_bytes).to eq(800)
      end

      it "accorpa anche se gli elenchi dei database non coincidono" do
        # Un database creato da poco non è ancora sulla copia: prima bastava a farle due righe.
        primary_host([ { "name" => "app_production", "size_bytes" => 10 },
                       { "name" => "appena_creato", "size_bytes" => 1 } ], identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], identifier: cluster_a)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name).uniq).to eq(%w[db-primary])
        expect(rows.map(&:name)).to contain_exactly("app_production", "appena_creato")
        expect(rows.map(&:replica_host_names).uniq).to eq([ %w[db-standby] ])
      end

      it "NON accorpa due cluster diversi che ospitano database omonimi" do
        # È il falso positivo che l'euristica non poteva escludere: stessi nomi, stesse dimensioni,
        # ma sono due macchine indipendenti. L'identificativo lo dice senza ambiguità.
        primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-altro", identifier: cluster_b)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name)).to contain_exactly("db-primary", "db-altro")
        expect(rows.map(&:replica_host_names).flatten).to be_empty
      end

      it "NON accorpa se due primary dichiarano lo stesso cluster" do
        # Stato anomalo (due macchine che si credono entrambe l'originale): attribuire la copia a una
        # delle due sarebbe una scelta a caso. Righe separate: ridondanti ma vere.
        primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-uno", identifier: cluster_a)
        primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-due", identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], identifier: cluster_a)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name)).to contain_exactly("db-uno", "db-due", "db-standby")
        expect(rows.map(&:replica_host_names).flatten).to be_empty
      end

      it "un cluster diverso vince sulla somiglianza degli elenchi" do
        # Stessi nomi, stesse dimensioni, e il primary dichiara pure una replica connessa: per la
        # vecchia deduzione erano la stessa cosa. Dichiarano cluster diversi, quindi non lo sono —
        # e la deduzione non deve poter ribaltare una risposta certa.
        primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], replicas: 1, identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-altro", identifier: cluster_b)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name)).to contain_exactly("db-primary", "db-altro")
        expect(rows.map(&:replica_host_names).flatten).to be_empty
      end

      it "torna a dedurre quando una delle due macchine non lo dichiara ancora" do
        # Flotta a metà aggiornamento: il primary è alla 0.6.0, la copia no. Vale l'euristica di prima.
        primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ])

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name)).to eq(%w[db-primary])
        expect(rows.first.replica_host_names).to eq(%w[db-standby])
      end

      it "il tetto delle repliche dichiarate non taglia fuori quelle certificate" do
        # Il primary ne dichiara una sola, ma di copie certificate ce ne sono due: il tetto serviva a
        # non attribuire copie a caso, e qui non si sta attribuendo nulla.
        primary_host([ { "name" => "app_production", "size_bytes" => 10 } ], replicas: 1, identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-copia-1", identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-copia-2", identifier: cluster_a)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        expect(rows.map(&:host_name)).to eq(%w[db-primary])
        expect(rows.first.replica_host_names).to eq(%w[db-copia-1 db-copia-2])
      end

      it "tiene la riga della copia se del suo cluster non si vede l'originale" do
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], identifier: cluster_a)
        standby_host([ { "name" => "app_production", "size_bytes" => 10 } ], name: "db-copia-2", identifier: cluster_a)

        rows = described_class.call(hosts: ::Servers::Host.where(organization:))

        # Due copie senza originale monitorato restano due righe: eleggerne una a principale sarebbe
        # una bugia, nessuna delle due lo è.
        expect(rows.map(&:host_name)).to contain_exactly("db-standby", "db-copia-2")
        expect(rows.map(&:replica_host_names).flatten).to be_empty
      end
    end
  end

  describe "ordinamento" do
    let(:primary) { host_with([ { "name" => "zeta", "size_bytes" => 300 }, { "name" => "alfa", "size_bytes" => 100 } ]) }
    let(:staging) { host_with([ { "name" => "mezzo", "size_bytes" => 200 } ], name: "aa-staging") }
    let(:hosts) { [ primary, staging ] }

    it "ordina per dimensione decrescente in assenza di parametro" do
      expect(described_class.call(hosts:).map(&:name)).to eq(%w[zeta mezzo alfa])
    end

    it "accetta il contratto sort di Sortable (chiave asc, -chiave desc)" do
      expect(described_class.call(hosts:, sort: "size").map(&:name)).to eq(%w[alfa mezzo zeta])
      expect(described_class.call(hosts:, sort: "database").map(&:name)).to eq(%w[alfa mezzo zeta])
      expect(described_class.call(hosts:, sort: "-database").map(&:name)).to eq(%w[zeta mezzo alfa])
      expect(described_class.call(hosts:, sort: "server").map(&:host_name).uniq).to eq(%w[aa-staging db-primary])
    end

    it "ricade sul default se la chiave non è in whitelist" do
      expect(described_class.call(hosts:, sort: "size_bytes; DROP TABLE").map(&:name)).to eq(%w[zeta mezzo alfa])
    end
  end

  describe "variazione nella finestra (CYRA-474)" do
    def sample_at(host, at, databases)
      create(:server_sample, host:, recorded_at: at,
             payload: { "database" => { "databases" => databases } })
    end

    it "non calcola la variazione a meno che non venga chiesta (la lista base non ne ha bisogno)" do
      host = host_with([ { "name" => "app", "size_bytes" => 300 } ])
      sample_at(host, 6.days.ago, [ { "name" => "app", "size_bytes" => 100 } ])
      sample_at(host, 1.hour.ago, [ { "name" => "app", "size_bytes" => 300 } ])

      expect(described_class.call(hosts: [ host ]).first.change_bytes).to be_nil
    end

    it "popola change_bytes col delta dal primo all'ultimo campione quando richiesto" do
      host = host_with([ { "name" => "app", "size_bytes" => 300 } ])
      sample_at(host, 6.days.ago, [ { "name" => "app", "size_bytes" => 100 } ])
      sample_at(host, 1.hour.ago, [ { "name" => "app", "size_bytes" => 300 } ])

      expect(described_class.call(hosts: [ host ], changes: true).first.change_bytes).to eq(200)
    end

    it "database più giovane della finestra → change_bytes nil, non uno zero" do
      host = host_with([ { "name" => "app", "size_bytes" => 500 } ])
      sample_at(host, 1.hour.ago, [ { "name" => "app", "size_bytes" => 500 } ])

      expect(described_class.call(hosts: [ host ], changes: true).first.change_bytes).to be_nil
    end

    it "la variazione segue la riga accorpata: è quella del primary" do
      primary = host_with([ { "name" => "app", "size_bytes" => 900 } ],
                          name: "db-primary", "role" => "primary", "system_identifier" => "CL1")
      standby = host_with([ { "name" => "app", "size_bytes" => 900 } ],
                          name: "db-standby", "role" => "standby", "system_identifier" => "CL1")
      sample_at(primary, 6.days.ago, [ { "name" => "app", "size_bytes" => 400 } ])
      sample_at(primary, 1.hour.ago, [ { "name" => "app", "size_bytes" => 900 } ])

      rows = described_class.call(hosts: ::Servers::Host.where(organization:), changes: true)

      expect(rows.size).to eq(1)
      expect(rows.first.change_bytes).to eq(500)
    end

    context "ordinamento per variazione" do
      let(:cresce) { host_with([ { "name" => "cresce", "size_bytes" => 900 } ], name: "h-cresce") }
      let(:cala) { host_with([ { "name" => "cala", "size_bytes" => 100 } ], name: "h-cala") }
      let(:nuovo) { host_with([ { "name" => "nuovo", "size_bytes" => 400 } ], name: "h-nuovo") }
      let(:hosts) { [ cresce, cala, nuovo ] }

      before do
        sample_at(cresce, 6.days.ago, [ { "name" => "cresce", "size_bytes" => 100 } ])
        sample_at(cresce, 1.hour.ago, [ { "name" => "cresce", "size_bytes" => 900 } ]) # +800
        sample_at(cala, 6.days.ago, [ { "name" => "cala", "size_bytes" => 300 } ])
        sample_at(cala, 1.hour.ago, [ { "name" => "cala", "size_bytes" => 100 } ])     # -200
        sample_at(nuovo, 1.hour.ago, [ { "name" => "nuovo", "size_bytes" => 400 } ])   # nessun delta
      end

      it "decrescente: i più in crescita in cima, i database senza dato sempre in fondo" do
        names = described_class.call(hosts:, sort: "-change", changes: true).map(&:name)

        expect(names).to eq(%w[cresce cala nuovo])
      end

      it "crescente: i cali per primi, i database senza dato comunque in fondo (mai in cima)" do
        names = described_class.call(hosts:, sort: "change", changes: true).map(&:name)

        expect(names).to eq(%w[cala cresce nuovo])
      end
    end
  end
end
