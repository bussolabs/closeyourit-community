# frozen_string_literal: true

require "rails_helper"

# CYRA-477: la copertura di un evento project-scoped (cron_missed / uptime_down) sulle sue entità.
# Stesso resolver scope→entità di Alerting::Evaluate#matching_rules: una regola copre un'entità
# quando il suo scope (progetto + ambiente, nil = tutti) la contiene.
RSpec.describe Alerting::Coverage, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:other_project) { create(:project, organization:) }

  describe ".for con i cron monitor (cron_missed)" do
    it "senza alcuna regola tutte le entità sono scoperte" do
      create(:cron_monitor, project:)
      create(:cron_monitor, project: other_project)

      report = described_class.for(organization:, event_type: :cron_missed,
                                   entities: Crons::Monitor.where(project: [ project, other_project ]))

      expect(report.total).to eq(2)
      expect(report.covered).to eq(0)
      expect(report.uncovered).to eq(2)
      expect(report).to be_any_uncovered
      expect(report).not_to be_all_covered
    end

    it "una regola org-wide abilitata copre tutte le entità" do
      create(:cron_monitor, project:)
      create(:cron_monitor, project: other_project)
      create(:alerting_rule, organization:, event_type: :cron_missed)

      report = described_class.for(organization:, event_type: :cron_missed,
                                   entities: Crons::Monitor.where(project: [ project, other_project ]))

      expect(report.total).to eq(2)
      expect(report.covered).to eq(2)
      expect(report.uncovered).to eq(0)
      expect(report).to be_all_covered
    end

    it "una regola scoped su un progetto copre solo le entità di quel progetto" do
      create(:cron_monitor, project:)
      create(:cron_monitor, project: other_project)
      create(:alerting_rule, organization:, event_type: :cron_missed, project:)

      report = described_class.for(organization:, event_type: :cron_missed,
                                   entities: Crons::Monitor.where(project: [ project, other_project ]))

      expect(report.total).to eq(2)
      expect(report.covered).to eq(1)
      expect(report.uncovered).to eq(1)
    end

    it "una regola disabilitata non copre nulla" do
      create(:cron_monitor, project:)
      create(:alerting_rule, :disabled, organization:, event_type: :cron_missed)

      report = described_class.for(organization:, event_type: :cron_missed,
                                   entities: Crons::Monitor.where(project:))

      expect(report.covered).to eq(0)
      expect(report.uncovered).to eq(1)
    end

    it "una regola di un altro evento non copre i cron" do
      create(:cron_monitor, project:)
      create(:alerting_rule, :uptime_down, organization:)

      report = described_class.for(organization:, event_type: :cron_missed,
                                   entities: Crons::Monitor.where(project:))

      expect(report.covered).to eq(0)
    end

    it "una regola scoped su un ambiente copre solo le entità di quell'ambiente" do
      environment = create(:environment, organization:)
      create(:cron_monitor, project:, environment:)
      create(:cron_monitor, project:, environment: nil)
      create(:alerting_rule, organization:, event_type: :cron_missed, environment:)

      report = described_class.for(organization:, event_type: :cron_missed, entities: Crons::Monitor.where(project:))

      expect(report.total).to eq(2)
      expect(report.covered).to eq(1)
    end

    it "senza entità total è zero (né coperto né scoperto)" do
      create(:alerting_rule, organization:, event_type: :cron_missed)

      report = described_class.for(organization:, event_type: :cron_missed, entities: Crons::Monitor.none)

      expect(report.total).to eq(0)
      expect(report).not_to be_any_uncovered
      expect(report).not_to be_all_covered
    end
  end

  describe ".for con i monitor uptime (uptime_down)" do
    it "una regola org-wide copre i monitor, una assente li lascia scoperti" do
      covered = create(:uptime_monitor, project:)
      create(:alerting_rule, :uptime_down, organization:)

      report = described_class.for(organization:, event_type: :uptime_down,
                                   entities: Uptime::Monitor.where(id: covered.id))

      expect(report).to be_all_covered
    end
  end

  # CYRA-476: il verso "monitor → regole che lo avvisano" (pannello "Chi viene avvisato" sul detail).
  describe ".rules_for (le regole che avvisano un monitor)" do
    let(:monitor) { create(:uptime_monitor, project:) }

    it "include una regola uptime_down org-wide abilitata" do
      rule = create(:alerting_rule, :uptime_down, organization:)
      expect(described_class.rules_for(monitor:)).to include(rule)
    end

    it "include una regola scoped sul progetto del monitor" do
      rule = create(:alerting_rule, :uptime_down, organization:, project:)
      expect(described_class.rules_for(monitor:)).to include(rule)
    end

    it "esclude una regola scoped su un altro progetto" do
      rule = create(:alerting_rule, :uptime_down, organization:, project: other_project)
      expect(described_class.rules_for(monitor:)).not_to include(rule)
    end

    it "include una regola sull'ambiente del monitor ed esclude quella su un altro ambiente" do
      same = create(:alerting_rule, :uptime_down, organization:, environment: monitor.environment)
      other = create(:alerting_rule, :uptime_down, organization:, environment: create(:environment, organization:))
      rules = described_class.rules_for(monitor:)
      expect(rules).to include(same)
      expect(rules).not_to include(other)
    end

    it "esclude una regola disabilitata" do
      rule = create(:alerting_rule, :uptime_down, :disabled, organization:)
      expect(described_class.rules_for(monitor:)).not_to include(rule)
    end

    it "esclude una regola di un altro evento (default uptime_down)" do
      rule = create(:alerting_rule, :uptime_up, organization:)
      expect(described_class.rules_for(monitor:)).not_to include(rule)
    end

    it "esclude una regola di un'altra organizzazione" do
      rule = create(:alerting_rule, :uptime_down, organization: create(:organization))
      expect(described_class.rules_for(monitor:)).not_to include(rule)
    end
  end

  # CYRA-476: il verso "regola → cose che copre" (pannello sul detail della regola).
  describe ".entities_for (le entità che una regola sorveglia oggi)" do
    it "una regola uptime elenca i monitor nello scope col conteggio" do
      m1 = create(:uptime_monitor, project:)
      m2 = create(:uptime_monitor, project: other_project)
      rule = create(:alerting_rule, :uptime_down, organization:)

      result = described_class.entities_for(rule)

      expect(result.kind).to eq(:monitors)
      expect(result.total).to eq(2)
      expect(result.records).to include(m1, m2)
      expect(result).to be_any
    end

    it "una regola uptime scoped su un progetto elenca solo i suoi monitor" do
      m1 = create(:uptime_monitor, project:)
      create(:uptime_monitor, project: other_project)
      rule = create(:alerting_rule, :uptime_down, organization:, project:)

      result = described_class.entities_for(rule)

      expect(result.total).to eq(1)
      expect(result.records).to contain_exactly(m1)
    end

    it "una regola uptime scoped su un ambiente elenca solo i monitor di quell'ambiente" do
      environment = create(:environment, organization:)
      project.environments << environment
      scoped = create(:uptime_monitor, project:, environment:)
      create(:uptime_monitor, project:)
      rule = create(:alerting_rule, :uptime_down, organization:, environment:)

      result = described_class.entities_for(rule)

      expect(result.records).to contain_exactly(scoped)
    end

    it "una regola cron_missed elenca i cron monitor" do
      create(:cron_monitor, project:)
      rule = create(:alerting_rule, organization:, event_type: :cron_missed)

      result = described_class.entities_for(rule)

      expect(result.kind).to eq(:cron_monitors)
      expect(result.total).to eq(1)
    end

    it "una regola su un altro evento project-scoped elenca i progetti nello scope" do
      project
      other_project
      rule = create(:alerting_rule, organization:, event_type: :error_new)

      result = described_class.entities_for(rule)

      expect(result.kind).to eq(:projects)
      expect(result.total).to eq(2)
      expect(result.records).to include(project, other_project)
    end

    it "una regola org-scoped copre l'intera organizzazione senza elencare entità" do
      rule = create(:alerting_rule, :server_down, organization:)

      result = described_class.entities_for(rule)

      expect(result.kind).to eq(:organization)
      expect(result.records).to be_empty
      expect(result).to be_any
    end
  end

  # CYRA-458: le regole server_* che avvisano UNA macchina (pannello "Regole di avviso" sul detail host).
  # Org-scoped: una regola qualsiasi copre tutta l'org, quindi "che riguardano l'host" = tutte le server_*
  # abilitate, meno gli eventi database sugli host che un database non ce l'hanno.
  describe ".server_rules_for (le regole che avvisano una macchina)" do
    let(:host) { create(:server_host, organization:) }

    it "include una regola server_* abilitata dell'org" do
      rule = create(:alerting_rule, :server_down, organization:)
      expect(described_class.server_rules_for(host)).to include(rule)
    end

    it "esclude una regola disabilitata" do
      rule = create(:alerting_rule, :server_down, :disabled, organization:)
      expect(described_class.server_rules_for(host)).not_to include(rule)
    end

    it "esclude una regola di un altro evento (non server)" do
      rule = create(:alerting_rule, :uptime_down, organization:)
      expect(described_class.server_rules_for(host)).not_to include(rule)
    end

    it "esclude una regola di un'altra organizzazione" do
      rule = create(:alerting_rule, :server_down, organization: create(:organization))
      expect(described_class.server_rules_for(host)).not_to include(rule)
    end

    it "su un host senza database omette gli avvisi del database" do
      db_rule = create(:alerting_rule, organization:, event_type: :server_db_down, name: "DB down")
      expect(described_class.server_rules_for(host)).not_to include(db_rule)
    end

    it "su un host con database include gli avvisi del database" do
      host.update!(database_snapshot: { "databases" => [ { "name" => "app_production" } ] })
      db_rule = create(:alerting_rule, organization:, event_type: :server_db_down, name: "DB down")
      expect(described_class.server_rules_for(host)).to include(db_rule)
    end
  end

  # CYRA-458: l'ultimo istante in cui ciascuna regola ha avvisato SU QUESTA macchina (subject = host).
  describe ".last_triggered_for (l'ultimo scatto per regola su un host)" do
    let(:host) { create(:server_host, organization:) }
    let(:rule) { create(:alerting_rule, :server_down, organization:) }

    def notify(host:, rule:, at:)
      create(:alerting_notification, organization:, subject: host, rule:, event_type: :server_down,
                                     created_at: at)
    end

    it "riporta l'ultimo scatto per ogni regola" do
      notify(host:, rule:, at: 3.days.ago)
      last = notify(host:, rule:, at: 1.hour.ago)

      result = described_class.last_triggered_for(host, [ rule.id ])

      expect(result[rule.id]).to be_within(1.second).of(last.created_at)
    end

    it "ignora gli scatti su un altro host" do
      other_host = create(:server_host, organization:)
      notify(host: other_host, rule:, at: 1.hour.ago)

      expect(described_class.last_triggered_for(host, [ rule.id ])).to eq({})
    end

    it "una regola senza scatti non compare nella mappa" do
      expect(described_class.last_triggered_for(host, [ rule.id ])).to eq({})
    end

    it "senza regole ritorna una mappa vuota senza toccare il DB" do
      expect(described_class.last_triggered_for(host, [])).to eq({})
    end
  end
end
