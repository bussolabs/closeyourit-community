# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::CheckStaleJob, type: :job do
  let(:threshold) { Servers::Constants::STALE_AFTER_SECONDS }

  it "gira sulla coda :servers" do
    expect(described_class.new.queue_name).to eq("servers")
  end

  it "marca down l'host silente e accoda server_down" do
    host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "server_down", subject_id: host.id,
                           organization_id: host.organization_id, project_id: nil))

    expect(host.reload.status_down?).to be(true)
  end

  # CYRA-649 — la regressione da non far tornare mai: la corsia di ricezione in arretrato (i backfill
  # notturni degli embedding la riempivano) lasciava indietro last_seen_at su TUTTA la flotta e questo
  # giro marcava giù 19 macchine che stavano pushando regolarmente. 76 avvisi falsi al giorno.
  it "non marca down le macchine che stanno pushando mentre la scrittura dei dati è in arretrato" do
    hosts = create_list(:server_host, 3, status: :up,
                        last_push_at: 10.seconds.ago, last_seen_at: (threshold + 300).seconds.ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)

    expect(hosts.map { |host| host.reload.status_up? }).to all(be(true))
  end

  it "non tocca host freschi, paused, revocati o già down" do
    fresh = create(:server_host, status: :up, last_push_at: 10.seconds.ago)
    paused = create(:server_host, status: :paused, last_push_at: 1.hour.ago)
    revoked = create(:server_host, :revoked, status: :up, last_push_at: 1.hour.ago)
    down = create(:server_host, status: :down, last_push_at: 1.hour.ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)

    expect(fresh.reload.status_up?).to be(true)
    expect(paused.reload.status_paused?).to be(true)
    expect(revoked.reload.status_up?).to be(true)
    expect(down.reload.status_down?).to be(true)
  end

  # CYRA-676 — l'avviso sul silenzio: macchina che risponde (push freschi) ma con dati fermi oltre
  # la soglia d'allarme. Soglia larga (15') apposta: il caso CYRA-649 (arretrato di corsia da pochi
  # minuti) non deve avvisare.
  describe "dati fermi (server_silent)" do
    let(:silent_threshold) { Servers::Constants::SILENT_ALERT_AFTER_SECONDS }

    it "push freschi + dati oltre soglia → server_silent una volta sola" do
      host = create(:server_host, status: :up, last_push_at: 10.seconds.ago,
                    last_seen_at: (silent_threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_silent", subject_id: host.id,
                             organization_id: host.organization_id, project_id: nil))
      expect(host.reload.silent_alerted_at).to be_present

      # Secondo giro: la memoria impedisce il bis.
      expect { described_class.perform_now }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_silent"))
    end

    it "dati vecchi ma sotto la soglia d'allarme → silenzio (CYRA-649)" do
      create(:server_host, status: :up, last_push_at: 10.seconds.ago,
             last_seen_at: (threshold + 300).seconds.ago)

      expect { described_class.perform_now }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_silent"))
    end

    it "push fermi (host in via di down) → niente server_silent, quel caso è server_down" do
      create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago,
             last_seen_at: (silent_threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_silent"))
    end
  end

  # CYRA-775 — la macchina è accesa e sta pushando, ma il nostro backend le risponde «troppe
  # richieste»: il push non arriva e il silenzio è NOSTRO. Il 3 settembre l'ingest è apparso caduto
  # e ripristinato sette volte in venticinque minuti, al passo esatto della finestra di staleness, e
  # ventidue macchine hanno mandato insieme quarantanove «Dati fermi». Un rifiuto che arriva da noi
  # non è un guasto della macchina.
  describe "rifiuti del backend agli agent (CYRA-775)" do
    let(:silent_threshold) { Servers::Constants::SILENT_ALERT_AFTER_SECONDS }
    let(:rejection_window) { Servers::Constants::INGEST_REJECTION_WINDOW_SECONDS }

    # In test la cache è :null_store: senza una cache vera il registro dei rifiuti scrive nel vuoto.
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    # Il rifiuto si ricorda per CREDENZIALE, e solo una credenziale vera sospende la sua
    # organizzazione: il freno scatta anche su un Bearer inventato, e un interruttore globale sarebbe
    # stato armabile da fuori per spegnere la rilevazione dei guasti di tutti.
    def reject_probe_of(host)
      issued = Servers::HostTokens::Issue.call(host: host)
      Servers::IngestRejections.record!(Digest::SHA256.hexdigest(issued.value[:secret])[0, 32])
    end

    it "push fermi per un rifiuto nostro → niente server_down e lo stato resta up" do
      host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)
      reject_probe_of(host)

      expect { described_class.perform_now }
        .not_to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "server_down"))

      expect(host.reload.status_up?).to be(true)
    end

    it "dati fermi per un rifiuto nostro → niente server_silent e nessuna memoria scritta" do
      host = create(:server_host, status: :up, last_push_at: 10.seconds.ago,
                    last_seen_at: (silent_threshold + 60).seconds.ago)
      reject_probe_of(host)

      expect { described_class.perform_now }
        .not_to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "server_silent"))

      # La memoria del silenzio NON va bruciata: quando il rifiuto passa, il silenzio vero deve
      # ancora poter avvisare.
      expect(host.reload.silent_alerted_at).to be_nil
    end

    it "il rifiuto è visibile come segnale proprio: un avviso all'organizzazione, non un guasto" do
      host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)
      reject_probe_of(host)

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_ingest_rejected",
                             subject_type: "Organizations::Organization",
                             subject_id: host.organization_id,
                             organization_id: host.organization_id, project_id: nil))
    end

    it "più macchine della stessa organizzazione sotto giudizio → un avviso solo, non uno per macchina" do
      organization = create(:organization)
      hosts = create_list(:server_host, 3, organization:, status: :up,
                          last_push_at: (threshold + 60).seconds.ago)
      hosts.each { |host| reject_probe_of(host) }

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_ingest_rejected", organization_id: organization.id))
        .exactly(:once)
    end

    it "organizzazioni diverse ricevono ciascuna il proprio avviso" do
      other_organization = create(:organization)
      host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)
      other_host = create(:server_host, organization: other_organization, status: :up,
                          last_push_at: 10.seconds.ago,
                          last_seen_at: (silent_threshold + 60).seconds.ago)
      [ host, other_host ].each { |machine| reject_probe_of(machine) }

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_ingest_rejected", organization_id: host.organization_id))
        .and have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_ingest_rejected", organization_id: other_organization.id))
    end

    it "nessuna macchina sotto giudizio → il rifiuto non avvisa nessuno" do
      host = create(:server_host, status: :up, last_push_at: 10.seconds.ago)
      reject_probe_of(host)

      expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "niente broadcast: durante la sospensione nessuno stato cambia" do
      organization = create(:organization)
      host = create(:server_host, organization:, status: :up, last_push_at: (threshold + 60).seconds.ago)
      reject_probe_of(host)

      expect { described_class.perform_now }
        .not_to have_broadcasted_to(Realtime::Streams.servers(organization))
    end

    # DoD del ticket: un server che smette DAVVERO di rispondere continua a generare server_down.
    it "passata la finestra del rifiuto la macchina davvero ferma torna a essere down" do
      host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)
      reject_probe_of(host)

      travel((rejection_window + 1).seconds) do
        expect { described_class.perform_now }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "server_down", subject_id: host.id))

        expect(host.reload.status_down?).to be(true)
      end
    end

    # Il freno scatta anche su un Bearer inventato: se bastasse quello a sospendere il giudizio,
    # chiunque da fuori potrebbe spegnere la rilevazione dei guasti di tutte le organizzazioni.
    it "un rifiuto a una credenziale che non esiste non sospende nessuno" do
      host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)
      Servers::IngestRejections.record!(Digest::SHA256.hexdigest("cyi_s_maiemesso")[0, 32])

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "server_down"))

      expect(host.reload.status_down?).to be(true)
    end

    it "il rifiuto sospende SOLO l'organizzazione che l'ha ricevuto" do
      rifiutata = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)
      altra = create(:server_host, organization: create(:organization), status: :up,
                     last_push_at: (threshold + 60).seconds.ago)
      reject_probe_of(rifiutata)

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_down", subject_id: altra.id))

      expect(rifiutata.reload.status_up?).to be(true)
      expect(altra.reload.status_down?).to be(true)
    end

    it "senza rifiuti registrati il giudizio è quello di sempre" do
      host = create(:server_host, status: :up, last_push_at: (threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "server_down"))

      expect(host.reload.status_down?).to be(true)
    end
  end

  describe "broadcast realtime" do
    let(:organization) { create(:organization) }
    let(:servers_stream) { Realtime::Streams.servers(organization) }

    it "2 host stale stessa org: una riga + page-refresh per host, pill UNA sola volta (2+2+1 = 5 broadcast)" do
      host_a = create(:server_host, organization:, status: :up, last_push_at: (threshold + 60).seconds.ago)
      host_b = create(:server_host, organization:, status: :up, last_push_at: (threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .to have_broadcasted_to(servers_stream).exactly(3).times   # 2 righe + 1 stats
        .and have_broadcasted_to(Realtime::Streams.server_host(host_a)).once
        .and have_broadcasted_to(Realtime::Streams.server_host(host_b)).once
    end

    it "lo stream dell'host stale riceve un page-refresh Turbo (action=refresh), non un replace mirato" do
      host = create(:server_host, organization:, status: :up, last_push_at: (threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .to have_broadcasted_to(Realtime::Streams.server_host(host)).with(a_string_including('action="refresh"'))
    end

    it "la riga broadcastata colpisce il dom_id dell'host e le pill il target servers_stats" do
      host = create(:server_host, organization:, status: :up, last_push_at: (threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .to have_broadcasted_to(servers_stream).with(a_string_including("servers_host_#{host.id}"))
        .and have_broadcasted_to(servers_stream).with(a_string_including("servers_stats"))
    end

    it "host stale in org diverse: ciascuno sul proprio stream, mai su quello altrui" do
      other_org = create(:organization)
      create(:server_host, organization:, status: :up, last_push_at: (threshold + 60).seconds.ago)
      create(:server_host, organization: other_org, status: :up, last_push_at: (threshold + 60).seconds.ago)

      expect { described_class.perform_now }
        .to have_broadcasted_to(servers_stream).exactly(2).times                                # 1 riga + 1 stats
        .and have_broadcasted_to(Realtime::Streams.servers(other_org)).exactly(2).times
    end

    it "nessun host stale: nessun broadcast" do
      create(:server_host, organization:, status: :up, last_push_at: 10.seconds.ago)

      expect { described_class.perform_now }.not_to have_broadcasted_to(servers_stream)
    end
  end
end
