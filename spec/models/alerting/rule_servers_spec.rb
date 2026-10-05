# frozen_string_literal: true

require "rails_helper"

# Estensione server_* dell'enum event_type (org-scoped, subject = Servers::Host).
RSpec.describe Alerting::Rule, type: :model do
  describe "eventi server_*" do
    it "espone i nuovi event_type in append (valori stabili, dopo cron_missed=6)" do
      expect(described_class.event_types).to include(
        "server_down" => 7, "server_up" => 8, "server_cpu" => 9, "server_mem" => 10,
        "server_disk" => 11, "server_temp" => 12, "server_service_failed" => 13,
        "server_smart_failing" => 14
      )
    end

    it "espone i tipi database in append (dopo log_alert=16)" do
      expect(described_class.event_types).to include(
        "server_db_down" => 17, "server_db_connections" => 18, "server_replication_lag" => 19
      )
    end

    it "espone server_container_down in append (dopo agents_stalled=20)" do
      expect(described_class.event_types).to include("server_container_down" => 21)
    end

    it "espone capacità, replica e restart loop in append dopo server_container_up=35" do
      expect(described_class.event_types).to include(
        "server_db_connection_usage" => 36, "server_data_volume_disk" => 37, "server_inode" => 38,
        "server_replication_down" => 39, "server_replication_up" => 40,
        "server_container_restart_loop" => 41, "server_container_stable" => 42
      )
    end

    it "#server_event? distingue server_* dagli altri" do
      expect(build(:alerting_rule, event_type: :server_down).server_event?).to be(true)
      expect(build(:alerting_rule, event_type: :server_db_down).server_event?).to be(true)
      expect(build(:alerting_rule, event_type: :server_replication_lag).server_event?).to be(true)
      expect(build(:alerting_rule, event_type: :server_container_down).server_event?).to be(true)
      expect(build(:alerting_rule, event_type: :error_new).server_event?).to be(false)
    end

    describe "validazione threshold" do
      it "server_cpu senza threshold è invalida" do
        rule = build(:alerting_rule, event_type: :server_cpu, threshold: nil)

        expect(rule).not_to be_valid
        expect(rule.errors[:threshold]).to be_present
      end

      it "server_cpu con threshold zero o negativa è invalida" do
        expect(build(:alerting_rule, event_type: :server_cpu, threshold: 0)).not_to be_valid
        expect(build(:alerting_rule, event_type: :server_cpu, threshold: -5)).not_to be_valid
      end

      it "server_cpu con threshold positiva è valida" do
        expect(build(:alerting_rule, event_type: :server_cpu, threshold: 90)).to be_valid
      end

      it "server_down non richiede threshold" do
        expect(build(:alerting_rule, event_type: :server_down, threshold: nil)).to be_valid
      end

      it "server_db_connections e server_replication_lag richiedono threshold" do
        expect(build(:alerting_rule, event_type: :server_db_connections, threshold: nil)).not_to be_valid
        expect(build(:alerting_rule, event_type: :server_replication_lag, threshold: nil)).not_to be_valid
        expect(build(:alerting_rule, event_type: :server_db_connections, threshold: 80)).to be_valid
        # Il lag è in secondi: una soglia sotto il secondo deve restare valida.
        expect(build(:alerting_rule, event_type: :server_replication_lag, threshold: 0.5)).to be_valid
      end


      it "le nuove percentuali di capacità richiedono threshold" do
        %i[server_db_connection_usage server_data_volume_disk server_inode].each do |event_type|
          expect(build(:alerting_rule, event_type:, threshold: nil)).not_to be_valid
          expect(build(:alerting_rule, event_type:, threshold: 80)).to be_valid
        end
      end

      it "server_db_down non richiede threshold (è una transizione, non una soglia)" do
        expect(build(:alerting_rule, event_type: :server_db_down, threshold: nil)).to be_valid
      end

      it "server_container_down non richiede threshold (è una transizione, non una soglia)" do
        expect(build(:alerting_rule, event_type: :server_container_down, threshold: nil)).to be_valid
      end

      it "error_new non richiede threshold" do
        expect(build(:alerting_rule, event_type: :error_new, threshold: nil)).to be_valid
      end
    end
  end
end
