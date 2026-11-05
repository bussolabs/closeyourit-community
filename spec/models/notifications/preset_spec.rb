# frozen_string_literal: true

require "rails_helper"

# CYRA-443 — le tre configurazioni pronte della pagina notifiche. Il rischio dichiarato nel ticket è
# che una definizione instabile faccia perdere le scelte fatte a mano: qui si fissa che cosa scrive
# ciascuna configurazione, e il lock di stabilità in fondo obbliga a bumpare VERSION per cambiarla.
RSpec.describe Notifications::Preset, type: :model do
  let(:catalogo) { Notifications::Catalog.event_types }
  let(:critici) { Notifications::Catalog::CRITICAL_EVENT_TYPES }

  describe "l'elenco" do
    it "sono tre, nell'ordine in cui le legge l'utente" do
      expect(described_class.all.map(&:key)).to eq(%w[essential everything urgent_only])
    end

    it "ognuna ha un nome e una spiegazione in entrambe le lingue" do
      %i[it en].each do |locale|
        described_class.all.each do |preset|
          expect(I18n.t("member.notifications.presets.#{preset.key}.label", locale: locale)).to be_present
          expect(I18n.t("member.notifications.presets.#{preset.key}.hint", locale: locale)).to be_present
        end
      end
    end

    it "una chiave sconosciuta non esiste (vocabolario chiuso)" do
      expect(described_class.find("bogus")).to be_nil
      expect(described_class.find(nil)).to be_nil
      expect(described_class.find("")).to be_nil
    end

    it "una chiave conosciuta torna la configurazione" do
      expect(described_class.find("essential").key).to eq("essential")
    end
  end

  describe "la matrice scritta" do
    it "copre TUTTI gli avvisi del catalogo, nessuno escluso" do
      described_class.all.each do |preset|
        expect(preset.cadences.keys).to match_array(catalogo), "#{preset.key} non copre tutto il catalogo"
      end
    end

    it "scrive solo cadenze valide" do
      described_class.all.each do |preset|
        invalide = preset.cadences.values.reject { |value| Notifications::Cadence.valid?(value) }
        expect(invalide).to be_empty, "#{preset.key} scrive cadenze non valide: #{invalide.uniq.inspect}"
      end
    end

    it "non inventa avvisi fuori catalogo" do
      described_class.all.each do |preset|
        expect(preset.cadences.keys - catalogo).to be_empty
      end
    end
  end

  describe "Tutto" do
    it "manda ogni avviso ogni volta" do
      expect(described_class.find("everything").cadences.values.uniq).to eq([ Notifications::Cadence::IMMEDIATE ])
    end
  end

  describe "Solo urgenze" do
    subject(:cadenze) { described_class.find("urgent_only").cadences }

    it "manda subito i guasti gravi" do
      critici.each { |evento| expect(cadenze[evento]).to eq(Notifications::Cadence::IMMEDIATE) }
    end

    it "spegne tutto il resto" do
      (catalogo - critici).each { |evento| expect(cadenze[evento]).to eq(Notifications::Cadence::OFF) }
    end
  end

  describe "Essenziale" do
    subject(:cadenze) { described_class.find("essential").cadences }

    it "manda subito quello che riguarda te di persona" do
      %w[ticket_assigned ticket_mentioned ticket_review_requested chat_mentioned].each do |evento|
        expect(cadenze[evento]).to eq(Notifications::Cadence::IMMEDIATE)
      end
    end

    it "manda subito i guasti gravi" do
      critici.each { |evento| expect(cadenze[evento]).to eq(Notifications::Cadence::IMMEDIATE) }
    end

    it "spegne i ritorni alla normalità: il ripristino non è una notizia urgente" do
      %w[uptime_up server_up server_container_up server_replication_up].each do |evento|
        expect(cadenze[evento]).to eq(Notifications::Cadence::OFF)
      end
    end

    it "riepiloga il resto una volta al giorno invece di spegnerlo" do
      expect(cadenze["server_cpu"]).to eq(Notifications::Cadence::DAILY)
      expect(cadenze["error_new"]).to eq(Notifications::Cadence::DAILY)
    end
  end

  describe "la stabilità della definizione" do
    # Il ticket lo chiede a lettere: una configurazione che cambia sotto i piedi fa perdere scelte
    # fatte a mano. Cambiare le liste senza bumpare VERSION rompe qui, di proposito.
    it "resta ferma finché non si bumpa VERSION" do
      expect(described_class::VERSION).to eq(3)
      expect(Digest::SHA256.hexdigest(described_class::DEFINITIONS.inspect))
        .to eq("74588e8201fe02c3c4a858a473351cd97bfa1afe2574fae7c62c5c45f4329659"),
             "definizioni cambiate: aggiorna il digest E bumpa Notifications::Preset::VERSION"
    end
  end
end
