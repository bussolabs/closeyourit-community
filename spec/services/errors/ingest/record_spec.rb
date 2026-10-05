# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Ingest::Record, type: :service do
  let(:project) { create(:project) }

  def payload(event_id:, type: "RuntimeError", value: "boom", func: "call",
              level: "error", user: nil, occurred: nil)
    {
      "event_id" => event_id,
      "level" => level,
      "timestamp" => (occurred || Time.current).to_f,
      "exception" => { "values" => [ {
        "type" => type, "value" => value,
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => func, "in_app" => true } ] }
      } ] }
    }.tap { |p| p["user"] = user if user }
  end

  def record(p) = described_class.call(project: project, payload: p)

  it "primo evento crea gruppo + evento con contatori e first/last_seen" do
    travel_to(Time.utc(2026, 6, 1, 12)) do
      result = record(payload(event_id: "e1"))
      expect(result).to be_ok
      group = project.error_groups.sole
      expect(group.events_count).to eq(1)
      expect(group.first_seen_at).to be_within(1).of(Time.utc(2026, 6, 1, 12))
      expect(group.last_seen_at).to be_within(1).of(Time.utc(2026, 6, 1, 12))
      expect(group.events.count).to eq(1)
      expect(result.value.project).to eq(project)   # project_id denormalizzato corretto
    end
  end

  it "seconda occorrenza stesso fingerprint → stesso gruppo, events_count 2" do
    record(payload(event_id: "e1"))
    expect { record(payload(event_id: "e2")) }.not_to change(Errors::Group, :count)
    expect(project.error_groups.sole.events_count).to eq(2)
  end

  it "persiste le colonne device context (os_name/os_version/app_version)" do
    result = record(payload(event_id: "dev1").merge(
      "contexts" => { "os" => { "name" => "Android", "version" => "14" },
                      "app" => { "app_version" => "1.2.0", "build_number" => "45" } }
    ))
    event = result.value
    expect(event.os_name).to eq("Android")
    expect(event.os_version).to eq("14")
    expect(event.app_version).to eq("1.2.0+45")
  end

  it "fingerprint diverso → nuovo gruppo" do
    record(payload(event_id: "e1", type: "RuntimeError"))
    expect { record(payload(event_id: "e2", type: "TypeError")) }.to change(Errors::Group, :count).by(1)
  end

  it "idempotenza: stesso event_id → nessun nuovo evento, contatore invariato" do
    record(payload(event_id: "dup"))
    expect { record(payload(event_id: "dup")) }.not_to change(Errors::Event, :count)
    expect(project.error_groups.sole.events_count).to eq(1)
  end

  describe "reopen su regressione" do
    it "gruppo resolved + nuovo evento → unresolved" do
      record(payload(event_id: "e1"))
      project.error_groups.sole.status_resolved!
      record(payload(event_id: "e2"))
      expect(project.error_groups.sole).to be_status_unresolved
    end

    it "gruppo ignored + nuovo evento → resta ignored (operatore l'ha mutato)" do
      record(payload(event_id: "e1"))
      project.error_groups.sole.status_ignored!
      record(payload(event_id: "e2"))
      expect(project.error_groups.sole).to be_status_ignored
    end
  end

  describe "users_count" do
    it "stesso user_hash su 2 eventi → users_count 1" do
      u = { "id" => "user-1" }
      record(payload(event_id: "e1", user: u))
      record(payload(event_id: "e2", user: u))
      expect(project.error_groups.sole.users_count).to eq(1)
    end

    it "user diversi → users_count 2" do
      record(payload(event_id: "e1", user: { "id" => "user-1" }))
      record(payload(event_id: "e2", user: { "id" => "user-2" }))
      expect(project.error_groups.sole.users_count).to eq(2)
    end

    it "senza utente → users_count 0" do
      record(payload(event_id: "e1"))
      expect(project.error_groups.sole.users_count).to eq(0)
    end
  end

  # CYRA-380: fatto storico «il gruppo ha ricevuto contesto utente», acceso al primo user_hash e mai
  # spento. Distinto da users_count: sopravvive a potatura/split che azzerano il conteggio.
  describe "user_context_seen" do
    it "un evento con identità utente accende il flag" do
      record(payload(event_id: "e1", user: { "id" => "user-1" }))
      expect(project.error_groups.sole.user_context_seen).to be(true)
    end

    it "eventi senza identità utente lasciano il flag spento" do
      record(payload(event_id: "e1"))
      record(payload(event_id: "e2"))
      expect(project.error_groups.sole.user_context_seen).to be(false)
    end

    it "una volta acceso resta acceso anche se l'evento successivo non porta l'utente (monotòno)" do
      record(payload(event_id: "e1", user: { "id" => "user-1" }))
      record(payload(event_id: "e2"))
      expect(project.error_groups.sole.user_context_seen).to be(true)
    end
  end

  # CYRA-49: mechanism.handled distingue i crash veri (handled=false) dalle catture volontarie
  # (handled=true). L'evento lo persiste; il gruppo alza has_unhandled (monotòno) al primo crash.
  describe "mechanism.handled" do
    def payload_handled(event_id:, handled:)
      payload(event_id:).tap { |p| p["exception"]["values"].last["mechanism"] = { "handled" => handled } }
    end

    it "crash non gestito → event.handled false + gruppo has_unhandled true" do
      event = record(payload_handled(event_id: "u1", handled: false)).value
      expect(event.handled).to be(false)
      expect(project.error_groups.sole.has_unhandled).to be(true)
    end

    it "cattura volontaria → event.handled true + gruppo has_unhandled false" do
      event = record(payload_handled(event_id: "h1", handled: true)).value
      expect(event.handled).to be(true)
      expect(project.error_groups.sole.has_unhandled).to be(false)
    end

    it "evento senza mechanism → event.handled nil, has_unhandled resta false" do
      event = record(payload(event_id: "n1")).value
      expect(event.handled).to be_nil
      expect(project.error_groups.sole.has_unhandled).to be(false)
    end

    it "has_unhandled è monotòno: una cattura volontaria dopo un crash NON lo spegne" do
      record(payload_handled(event_id: "u1", handled: false))
      record(payload_handled(event_id: "h1", handled: true))
      expect(project.error_groups.sole.has_unhandled).to be(true)
    end

    it "has_unhandled diventa true al primo crash su un gruppo finora tutto gestito" do
      record(payload_handled(event_id: "h1", handled: true))
      expect(project.error_groups.sole.has_unhandled).to be(false)
      record(payload_handled(event_id: "u1", handled: false))
      expect(project.error_groups.sole.has_unhandled).to be(true)
    end

    describe "propagazione all'alerting" do
      include ActiveJob::TestHelper

      it "il primo evento non gestito accoda l'alert con handled=false" do
        expect { record(payload_handled(event_id: "u1", handled: false)) }
          .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_new", handled: false))
      end

      it "il primo evento gestito accoda l'alert con handled=true" do
        expect { record(payload_handled(event_id: "h1", handled: true)) }
          .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_new", handled: true))
      end
    end
  end

  it "last_seen_at avanza al più recente, first_seen_at resta" do
    record(payload(event_id: "e1", occurred: Time.utc(2026, 5, 1)))
    record(payload(event_id: "e2", occurred: Time.utc(2026, 6, 1)))
    group = project.error_groups.sole
    expect(group.first_seen_at).to be_within(1).of(Time.utc(2026, 5, 1))
    expect(group.last_seen_at).to be_within(1).of(Time.utc(2026, 6, 1))
  end

  it "title e level del gruppo riflettono l'ultimo evento" do
    record(payload(event_id: "e1", value: "first", level: "warning"))
    record(payload(event_id: "e2", value: "latest", level: "fatal"))
    group = project.error_groups.sole
    expect(group.title).to eq("RuntimeError: latest")
    expect(group).to be_level_fatal
  end

  it "event_id mancante → genera comunque (nessun crash)" do
    expect(record(payload(event_id: nil))).to be_ok
    expect(project.error_groups.sole.events_count).to eq(1)
  end

  describe "trigger alerting" do
    include ActiveJob::TestHelper

    it "primo evento (gruppo nuovo) → accoda EvaluateJob error_new col livello" do
      expect { record(payload(event_id: "e1", level: "error")) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "error_new", subject_type: "Errors::Group",
                             project_id: project.id, level: Errors::Group.levels["error"]))
    end

    it "regressione (gruppo resolved + nuovo evento) → accoda error_regression" do
      record(payload(event_id: "e1"))
      project.error_groups.sole.status_resolved!
      expect { record(payload(event_id: "e2")) }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_regression"))
    end

    it "occorrenza su gruppo già unresolved (nessuna transizione) → NON accoda" do
      record(payload(event_id: "e1"))
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect { record(payload(event_id: "e2")) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "gruppo ignored + nuovo evento → NON accoda (resta muto per scelta operatore)" do
      record(payload(event_id: "e1"))
      project.error_groups.sole.status_ignored!
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect { record(payload(event_id: "e2")) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "replay idempotente (stesso event_id) → NON accoda" do
      record(payload(event_id: "dup"))
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect { record(payload(event_id: "dup")) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "race concorrenti (rescue RecordNotUnique)" do
    it "RecordNotUnique nella transazione (delivery concorrente) → rescue idempotente, ritorna l'esistente" do
      first = record(payload(event_id: "race")).value
      relation = project.error_events
      allow(project).to receive(:error_events).and_return(relation)
      seen = 0
      # find_by di idempotenza (1ª) NON vede il record (race); rescue (2ª) lo ritrova.
      allow(relation).to receive(:find_by) do |*|
        seen += 1
        seen == 1 ? nil : first
      end
      allow(ApplicationRecord).to receive(:transaction).and_raise(ActiveRecord::RecordNotUnique)

      result = record(payload(event_id: "race"))

      expect(result).to be_ok
      expect(result.value).to eq(first)
    end

    it "race sulla creazione del gruppo: find_or_create_by! solleva RecordNotUnique → riusa il gruppo esistente" do
      existing = create(:error_group, project:, events_count: 0)
      groups = project.error_groups
      allow(project).to receive(:error_groups).and_return(groups)
      allow(groups).to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique)
      allow(groups).to receive(:find_by!).and_return(existing)

      result = record(payload(event_id: "grp-race"))

      expect(result).to be_ok
      expect(result.value.group_id).to eq(existing.id)
    end
  end
  describe "embedding on-ingest" do
    it "gruppo nuovo → accoda EmbedGroupJob" do
      expect { record(payload(event_id: "e1")) }
        .to have_enqueued_job(Errors::EmbedGroupJob).exactly(:once)
    end

    it "occorrenza ripetuta (stesso title) → NON riaccoda" do
      record(payload(event_id: "e1"))
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      expect { record(payload(event_id: "e2")) }
        .not_to have_enqueued_job(Errors::EmbedGroupJob)
    end

    it "title cambiato sul gruppo esistente → riaccoda il re-embed" do
      record(payload(event_id: "e1", value: "boom"))
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      expect { record(payload(event_id: "e2", value: "boom diverso")) }
        .to have_enqueued_job(Errors::EmbedGroupJob).exactly(:once)
    end
  end

  describe "release tracking" do
    def payload_with_release(event_id:, release:, occurred: nil)
      payload(event_id:).merge("release" => release,
                               "timestamp" => (occurred || Time.current).to_f)
    end

    it "il primo evento con release crea la Projects::Release e fissa first_seen_release sul gruppo" do
      record(payload_with_release(event_id: "r1", release: "v1.0.0"))

      group = project.error_groups.sole
      expect(group.first_seen_release).to eq("v1.0.0")
      release = project.releases.find_by!(version: "v1.0.0")
      expect(release.events_count).to eq(1)
    end

    it "eventi successivi con release nuova aggiornano release (last) ma NON first_seen_release" do
      record(payload_with_release(event_id: "r1", release: "v1.0.0"))
      record(payload_with_release(event_id: "r2", release: "v1.1.0"))

      group = project.error_groups.sole.reload
      expect(group.first_seen_release).to eq("v1.0.0")
      expect(group.release).to eq("v1.1.0")
      expect(project.releases.pluck(:version)).to contain_exactly("v1.0.0", "v1.1.0")
    end

    it "updates the release after the group transaction has committed (CYRA-894)" do
      baseline = ActiveRecord::Base.connection.open_transactions
      depth = nil
      allow(Projects::Release).to receive(:track_event!).and_wrap_original do |original, **kwargs|
        depth = ActiveRecord::Base.connection.open_transactions
        original.call(**kwargs)
      end

      record(payload_with_release(event_id: "r1", release: "v1.0.0"))

      expect(depth).to eq(baseline)
      expect(project.releases.find_by!(version: "v1.0.0").events_count).to eq(1)
    end

    it "evento senza release → nessuna Projects::Release" do
      record(payload(event_id: "r3"))
      expect(project.releases).to be_empty
    end
  end

  describe "regressione con release nel contenuto dell'alert" do
    include ActiveJob::TestHelper

    it "gruppo resolved che riceve un evento in release successiva → alert error_regression con la release nel body" do
      record(payload(event_id: "q1").merge("release" => "v1.0.0"))
      group = project.error_groups.sole
      Errors::Triage.call(group:, action: "resolve")

      perform_enqueued_jobs only: Errors::IngestJob do
        record(payload(event_id: "q2").merge("release" => "v2.0.0"))
      end

      content = Alerting::Content.for(event_type: "error_regression", subject: group.reload)
      expect(content.body).to include("v2.0.0")
    end
  end

  # CYRA-44: un evento tardivo con release PRECEDENTE a quella del fix è un residuo di client vecchio,
  # non una regressione — non riapre il gruppo né allarma. Solo una release pari/successiva riapre.
  describe "audit di regressione release-aware (CYRA-44)" do
    include ActiveJob::TestHelper

    def record_release(event_id:, release:)
      record(payload(event_id:).merge("release" => release))
    end

    # Gruppo risolto quando la release live era v1.2 (binding attivo).
    def resolved_group_at_v12
      create(:release, project:, version: "v1.2", environment: "production", current: true)
      record_release(event_id: "seed", release: "v1.2")
      group = project.error_groups.sole
      Errors::Triage.call(group:, action: "resolve")
      group
    end

    it "evento tardivo pre-fix (v1.0 su gruppo risolto in v1.2) NON riapre il gruppo" do
      group = resolved_group_at_v12
      record_release(event_id: "late", release: "v1.0")
      expect(group.reload).to be_status_resolved
    end

    it "evento tardivo pre-fix NON registra alcuna release di regressione" do
      group = resolved_group_at_v12
      record_release(event_id: "late", release: "v1.0")
      expect(group.reload.regressed_in_release).to be_nil
    end

    it "evento tardivo pre-fix NON accoda un alert di regressione" do
      resolved_group_at_v12
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect { record_release(event_id: "late", release: "v1.0") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "evento tardivo pre-fix conta comunque come occorrenza (events_count avanza)" do
      group = resolved_group_at_v12
      expect { record_release(event_id: "late", release: "v1.0") }
        .to change { group.reload.events_count }.by(1)
    end

    it "vera regressione (v2.0 su gruppo risolto in v1.2) riapre il gruppo" do
      group = resolved_group_at_v12
      record_release(event_id: "reg", release: "v2.0")
      expect(group.reload).to be_status_unresolved
    end

    it "vera regressione registra la release che ha causato il reopen" do
      group = resolved_group_at_v12
      record_release(event_id: "reg", release: "v2.0")
      expect(group.reload.regressed_in_release).to eq("v2.0")
    end

    it "vera regressione accoda l'alert error_regression" do
      resolved_group_at_v12
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect { record_release(event_id: "reg", release: "v2.0") }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_regression"))
    end

    it "senza release live (nessun binding) il reopen resta conservativo: qualsiasi evento riapre" do
      record_release(event_id: "seed", release: "v1.0")
      group = project.error_groups.sole
      Errors::Triage.call(group:, action: "resolve")   # resolved_in_release resta nil
      record_release(event_id: "any", release: "v0.9")
      expect(group.reload).to be_status_unresolved
      expect(group.regressed_in_release).to eq("v0.9")
    end

    # Anti-race del reopen: il gate atomico WHERE status=resolved fa sì che, tra più delivery
    # concorrenti che l'hanno visto resolved, un solo UPDATE transiti → un solo alert error_regression.
    describe "reopen_as_regression! (gate atomico)" do
      let(:normalized) do
        Errors::Ingest::Normalize.call(payload: { "event_id" => "z", "release" => "v3.0",
                                                  "exception" => { "values" => [ { "type" => "E", "value" => "x" } ] } })
      end
      let(:service) { described_class.new(project:, payload: {}) }

      it "gruppo resolved → transita, ritorna true e registra la release del reopen" do
        group = create(:error_group, project:, status: :resolved)
        expect(service.send(:reopen_as_regression!, group, normalized)).to be(true)
        expect(group.reload).to be_status_unresolved
        expect(group.regressed_in_release).to eq("v3.0")
      end

      it "gruppo già riaperto da un altro delivery → ritorna false e non tocca nulla" do
        group = create(:error_group, project:, status: :unresolved, regressed_in_release: nil)
        expect(service.send(:reopen_as_regression!, group, normalized)).to be(false)
        expect(group.reload.regressed_in_release).to be_nil
      end
    end
  end
end
