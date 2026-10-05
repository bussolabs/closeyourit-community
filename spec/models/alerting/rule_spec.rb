# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Rule, type: :model do
  describe "factory" do
    it "produce un record valido" do
      expect(build(:alerting_rule)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede il nome" do
      expect(build(:alerting_rule, name: "")).not_to be_valid
    end

    it "richiede l'organizzazione" do
      expect(build(:alerting_rule, organization: nil)).not_to be_valid
    end

    it "accetta project ed environment nulli (scope = tutti)" do
      rule = build(:alerting_rule, project: nil, environment: nil)
      expect(rule).to be_valid
    end

    context "throttle_seconds ai confini" do
      it "è invalida a 0" do
        expect(build(:alerting_rule, throttle_seconds: 0)).not_to be_valid
      end

      it "è valida a 1" do
        expect(build(:alerting_rule, throttle_seconds: 1)).to be_valid
      end

      it "è invalida se negativa" do
        expect(build(:alerting_rule, throttle_seconds: -1)).not_to be_valid
      end
    end

    context "min_level" do
      it "accetta nil" do
        expect(build(:alerting_rule, min_level: nil)).to be_valid
      end

      it "accetta un livello valido (error)" do
        expect(build(:alerting_rule, min_level: Errors::Group.levels["error"])).to be_valid
      end

      it "rifiuta un livello fuori scala" do
        expect(build(:alerting_rule, min_level: 99)).not_to be_valid
      end

      # CYRA-236: i canali API (CLI/SDK/agent/curl) mandano il NOME del livello, non l'intero. Prima
      # il cast Rails di "error" dava 0 (debug) e passava in silenzio, salvando l'opposto del richiesto.
      it "accetta il nome del livello e lo converte nell'intero corrispondente" do
        rule = build(:alerting_rule, min_level: "error")
        expect(rule).to be_valid
        expect(rule.min_level).to eq(Errors::Group.levels["error"])
      end

      it "salva il livello indicato per nome e lo rilegge correttamente" do
        rule = create(:alerting_rule, min_level: "error")
        expect(rule.reload.min_level).to eq(Errors::Group.levels["error"])
      end

      it "accetta una stringa numerica e la tratta come intero" do
        expect(build(:alerting_rule, min_level: "3").min_level).to eq(3)
      end

      it "rifiuta un nome di livello inesistente invece di salvarne uno qualsiasi" do
        rule = build(:alerting_rule, min_level: "bogus")
        expect(rule).not_to be_valid
        expect(rule.errors[:min_level]).to be_present
      end

      # Regressione: dopo un'assegnazione invalida, reload deve ripristinare uno stato valido — la
      # coercizione non deve lasciare stato appiccicoso che sopravvive al ricaricamento dal DB.
      it "dopo un'assegnazione invalida, reload ripristina uno stato valido" do
        rule = create(:alerting_rule, min_level: "error")
        rule.min_level = "bogus"
        expect(rule).not_to be_valid

        rule.reload
        expect(rule).to be_valid
        expect(rule.min_level).to eq(Errors::Group.levels["error"])
      end
    end
  end

  describe "event_type enum" do
    it "espone i tipi monitoring (storici + server_* + log + database + agents + container + slow + analytics/idea/workload/dataset + vulnerabilità + servizi interni)" do
      expect(described_class.event_types.keys)
        .to contain_exactly("error_new", "error_regression", "error_spike", "uptime_down", "uptime_up",
                            "metric_threshold", "uptime_ssl_expiring", "cron_missed",
                            "server_down", "server_up", "server_cpu", "server_mem", "server_disk",
                            "server_temp", "server_service_failed", "server_smart_failing", "log_alert",
                            "server_db_down", "server_db_connections", "server_replication_lag",
                            "agents_stalled", "server_container_down", "agents_host_failing", "uptime_slow",
                            "analytics_traffic_drop", "analytics_traffic_spike", "idea_created",
                            "idea_commented", "workload_due_soon", "dataset_training_completed",
                            "dataset_training_failed", "agents_host_stale",
                            "vulnerability_new", "runtime_eol", "embedding_down", "server_container_up",
                            "server_db_connection_usage", "server_data_volume_disk", "server_inode",
                            "server_replication_down", "server_replication_up",
                            "server_container_restart_loop", "server_container_stable", "seo_issue_new",
                            "secret_read", "secret_denied",
                            "server_security_updates", "server_silent", "server_disk_forecast",
                            "ai_unavailable", "ai_available", "server_ingest_rejected",
                            "cache_unavailable", "cluster_down", "cluster_up", "cluster_node_not_ready",
                            "cluster_node_pressure", "cluster_workload_crashloop", "cluster_workload_degraded",
                            "measurement_threshold")
    end

    it "predicato di tipo" do
      expect(build(:alerting_rule, :uptime_down)).to be_event_uptime_down
    end
  end

  # CYRA-55: le regole sui log error/fatal usano min_level come gli errori (level confrontabile: i
  # livelli di Logs::Entry e Errors::Group condividono gli stessi interi).
  describe "#log_event?" do
    it "è true per una regola sui log (log_alert) e NON è un error_event?" do
      rule = build(:alerting_rule, event_type: :log_alert)
      expect(rule.log_event?).to be(true)
      expect(rule.error_event?).to be(false)
    end

    it "è false per le regole di altri domini (errori/uptime/server)" do
      expect(build(:alerting_rule, event_type: :error_new).log_event?).to be(false)
      expect(build(:alerting_rule, event_type: :uptime_down).log_event?).to be(false)
      expect(build(:alerting_rule, event_type: :server_down).log_event?).to be(false)
    end
  end

  describe "scopes" do
    it ".enabled esclude le regole disattivate" do
      on = create(:alerting_rule)
      off = create(:alerting_rule, :disabled)
      expect(described_class.enabled).to include(on)
      expect(described_class.enabled).not_to include(off)
    end
  end

  describe "associazioni" do
    it "appartiene all'organizzazione" do
      expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to)
    end

    it "ha created_by opzionale verso Account" do
      assoc = described_class.reflect_on_association(:created_by)
      expect(assoc.options[:class_name]).to eq("Accounts::Account")
      expect(assoc.options[:optional]).to be(true)
    end
  end
end
