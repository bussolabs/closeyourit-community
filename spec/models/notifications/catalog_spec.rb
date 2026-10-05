# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Catalog, type: :model do
  describe "completezza vs enum Alerting::Notification#event_type" do
    it "copre ESATTAMENTE tutti gli event_type dell'enum (niente buchi, niente extra)" do
      expect(described_class.event_types).to contain_exactly(*Alerting::Notification.event_types.keys)
    end

    it "ogni event_type compare in un solo gruppo" do
      grouped = described_class.groups.flat_map(&:event_types)
      expect(grouped).to match_array(described_class.event_types)
      expect(grouped.uniq).to eq(grouped)
    end
  end

  describe "voci i18n (title + description) presenti in en e it" do
    %w[en it].each do |locale|
      described_class.event_types.each do |event_type|
        it "#{locale}: #{event_type} ha titolo e descrizione" do
          expect(I18n.t("member.notifications.catalog.#{event_type}.title", locale: locale, raise: true)).to be_present
          expect(I18n.t("member.notifications.catalog.#{event_type}.description", locale: locale, raise: true))
            .to be_present
        end
      end
    end
  end

  describe "etichette e cadenze i18n" do
    %w[en it].each do |locale|
      it "#{locale}: ogni gruppo ha una label" do
        described_class.groups.each do |group|
          expect(I18n.t("member.notifications.groups.#{group.key}", locale: locale, raise: true)).to be_present
        end
      end

      it "#{locale}: ogni cadenza ha una label" do
        Notifications::Cadence::VALUES.each do |cadence|
          expect(I18n.t("member.notifications.cadences.#{cadence}", locale: locale, raise: true)).to be_present
        end
      end

      it "#{locale}: ogni natura ha una label" do
        described_class.natures.each do |nature|
          expect(I18n.t("member.notifications.natures.#{nature.key}", locale: locale, raise: true)).to be_present
        end
      end
    end
  end

  # CYRA-488: la natura è la classificazione macro (sistemi / ticket / agenti) che separa a colpo
  # d'occhio gli avvisi tecnici ripetuti dalle cose su cui un umano deve agire. DERIVATA dall'event_type.
  describe "nature (CYRA-488 — separazione per natura, derivata dall'event_type)" do
    it "le nature coprono ESATTAMENTE tutti gli event_type (niente buchi, niente extra)" do
      covered = described_class.natures.flat_map(&:event_types)
      expect(covered).to match_array(described_class.event_types)
      expect(covered.uniq).to eq(covered)
    end

    it "ogni gruppo di dominio appartiene a una sola natura" do
      described_class.groups.each do |group|
        owners = described_class.natures.select { |nature| (nature.event_types & group.event_types).any? }
        expect(owners.size).to eq(1), "il gruppo #{group.key} è in #{owners.map(&:key)}"
      end
    end

    describe ".nature_for" do
      it "gli avvisi tecnici (infrastruttura, errori, uptime, servizi) sono 'systems'" do
        %w[server_down uptime_down error_new log_alert cron_missed embedding_down].each do |event_type|
          expect(described_class.nature_for(event_type)).to eq(:systems), "#{event_type} → systems"
        end
      end

      it "ticket, revisioni, conversazioni e attività umane sono 'tickets'" do
        %w[ticket_created ticket_review_requested chat_message idea_created workload_due_soon].each do |event_type|
          expect(described_class.nature_for(event_type)).to eq(:tickets), "#{event_type} → tickets"
        end
      end

      it "gli agenti di automazione sono 'agents'" do
        %w[agents_stalled agents_host_failing agents_host_stale].each do |event_type|
          expect(described_class.nature_for(event_type)).to eq(:agents), "#{event_type} → agents"
        end
      end

      it "accetta sia stringa sia simbolo; event_type ignoto → nil" do
        expect(described_class.nature_for(:server_down)).to eq(:systems)
        expect(described_class.nature_for("bogus_event")).to be_nil
      end
    end

    describe ".nature_event_types" do
      it "ritorna gli event_type della natura (server sì, ticket no per 'systems')" do
        systems = described_class.nature_event_types(:systems)
        expect(systems).to include("server_down").and include("uptime_down")
        expect(systems).not_to include("ticket_created")
      end

      it "accetta stringa e simbolo; natura ignota → [] (vale come nessun filtro)" do
        expect(described_class.nature_event_types("tickets")).to include("ticket_created")
        expect(described_class.nature_event_types(:bogus)).to eq([])
        expect(described_class.nature_event_types(nil)).to eq([])
      end
    end
  end

  # CYRA-315: la Home contava le conversazioni con un elenco di event_type suo, invisibile al centro
  # notifiche — che quindi non sapeva filtrarle e mostrava un altro totale. Il vocabolario è uno solo,
  # e sta qui come CRITICAL_EVENT_TYPES: è una proprietà del tipo, non un dato salvato per riga.
  describe "conversazioni (CYRA-315 — sottoinsieme nominato, condiviso da Home e centro notifiche)" do
    it "sono un sottoinsieme del catalogo (mai un event_type inventato)" do
      expect(described_class.event_types).to include(*described_class.conversation_event_types)
    end

    it "sono le menzioni, i commenti e gli esiti di review — non gli avvisi delle macchine" do
      expect(described_class.conversation_event_types)
        .to include("ticket_commented", "ticket_mentioned", "ticket_review_requested",
                    "ticket_review_rejected", "chat_mentioned")
      expect(described_class.conversation_event_types).not_to include("server_down", "error_new")
    end

    it "stanno tutte nella natura dei ticket (la scheda su cui atterra il link della Home)" do
      expect(described_class.nature_event_types(:tickets)).to include(*described_class.conversation_event_types)
    end
  end

  describe "tono/icona" do
    it "ogni voce ha un'icona (dalla mappa condivisa col notification center)" do
      described_class.event_types.each do |event_type|
        expect(described_class.entry(event_type).icon).to be_present
      end
    end
  end

  describe ".critical? (guasti gravi che scavalcano le quiet hours, CYRA-479)" do
    it "i guasti gravi di infrastruttura sono critici" do
      %w[uptime_down server_down server_db_down cron_missed].each do |event_type|
        expect(described_class.critical?(event_type)).to be(true), "#{event_type} dovrebbe essere critico"
      end
    end

    it "gli eventi di routine non sono critici" do
      %w[error_new uptime_up uptime_slow ticket_created idea_created].each do |event_type|
        expect(described_class.critical?(event_type)).to be(false), "#{event_type} non dovrebbe essere critico"
      end
    end

    it "accetta sia stringa sia simbolo, ignoto → false" do
      expect(described_class.critical?(:uptime_down)).to be(true)
      expect(described_class.critical?("bogus_event")).to be(false)
    end

    it "ogni evento critico è un event_type noto del catalogo (nessun vocabolario parallelo)" do
      expect(described_class::CRITICAL_EVENT_TYPES).to all(satisfy { |ev| described_class.include?(ev) })
    end
  end

  describe ".entry" do
    it "ritorna nil per un event_type ignoto" do
      expect(described_class.entry("bogus_event")).to be_nil
    end
  end

  describe "parità chiavi en/it del file notifiche" do
    def flatten_keys(hash, prefix = nil)
      hash.flat_map do |key, value|
        full = [ prefix, key ].compact.join(".")
        value.is_a?(Hash) ? flatten_keys(value, full) : [ full ]
      end
    end

    def keys_for(locale)
      file = Rails.root.join("config/locales/member/notifications.#{locale}.yml")
      flatten_keys(YAML.load_file(file).fetch(locale)).sort
    end

    it "en e it espongono lo stesso set di chiavi" do
      en = keys_for("en")
      it_keys = keys_for("it")
      expect(it_keys - en).to eq([]), "solo in it: #{(it_keys - en).join(', ')}"
      expect(en - it_keys).to eq([]), "solo in en: #{(en - it_keys).join(', ')}"
    end
  end

  # CYRA-875 — CloseYourIt's own services are the gods' business: the other users never see the group.
  describe ".groups_for" do
    it "hides the internal services group from a regular account" do
      expect(described_class.groups_for(build(:account)).map(&:key)).not_to include(:services)
    end

    it "shows every group to a god" do
      expect(described_class.groups_for(build(:account, god: true)).map(&:key)).to eq(described_class.groups.map(&:key))
    end
  end
end
