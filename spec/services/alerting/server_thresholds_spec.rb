# frozen_string_literal: true

require "rails_helper"

# CYRA-458: soglia d'allarme EFFETTIVA per host+metrica (override per-macchina || regola org || nil),
# così le viste server possono affiancare al valore il limite oltre cui scatta l'avviso.
RSpec.describe Alerting::ServerThresholds do
  let(:org) { create(:organization) }

  describe ".for + #for_host" do
    it "usa la soglia della regola org come valore di partenza per un host senza override" do
      create(:alerting_rule, organization: org, event_type: :server_cpu, name: "CPU", threshold: 90)
      create(:alerting_rule, organization: org, event_type: :server_disk, name: "Disk", threshold: 80)
      host = create(:server_host, organization: org)

      effective = described_class.for(org).for_host(host)

      expect(effective[:cpu]).to eq(90)
      expect(effective[:disk]).to eq(80)
    end

    it "la soglia per-macchina vince sulla regola org" do
      create(:alerting_rule, organization: org, event_type: :server_cpu, name: "CPU", threshold: 90)
      host = create(:server_host, organization: org, cpu_threshold: 60)

      expect(described_class.for(org).for_host(host)[:cpu]).to eq(60)
    end

    it "con più regole sulla stessa metrica prende la soglia più bassa (la prima a scattare)" do
      create(:alerting_rule, organization: org, event_type: :server_mem, name: "Mem alta", threshold: 95)
      create(:alerting_rule, organization: org, event_type: :server_mem, name: "Mem media", threshold: 70)
      host = create(:server_host, organization: org)

      expect(described_class.for(org).for_host(host)[:mem]).to eq(70)
    end

    it "ignora le regole disabilitate" do
      create(:alerting_rule, :disabled, organization: org, event_type: :server_cpu, name: "CPU off", threshold: 50)
      host = create(:server_host, organization: org)

      expect(described_class.for(org).for_host(host)[:cpu]).to be_nil
    end

    it "ignora le regole di un'altra organizzazione" do
      create(:alerting_rule, event_type: :server_cpu, name: "Altrui", threshold: 50)
      host = create(:server_host, organization: org)

      expect(described_class.for(org).for_host(host)[:cpu]).to be_nil
    end

    it "senza regola né override la soglia della metrica è nil" do
      host = create(:server_host, organization: org)

      expect(described_class.for(org).for_host(host)).to eq({ cpu: nil, mem: nil, disk: nil })
    end

    it "risolve gli host senza una query per host (il set org è precalcolato una volta)" do
      create(:alerting_rule, organization: org, event_type: :server_disk, name: "Disk", threshold: 80)
      hosts = create_list(:server_host, 3, organization: org)
      set = described_class.for(org)

      queries = 0
      counter = ->(_name, _start, _finish, _id, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        hosts.each { |host| set.for_host(host) }
      end

      expect(queries).to eq(0)
    end
  end
end
