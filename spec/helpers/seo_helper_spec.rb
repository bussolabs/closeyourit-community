# frozen_string_literal: true

require "rails_helper"

RSpec.describe SeoHelper, type: :helper do
  # Gli URL delle pagine arrivano dalla scansione del sito del cliente e diventano `href` cliccabili:
  # se uno schema `javascript:` sopravvivesse fin qui, chi apre l'elenco lo eseguirebbe con un clic.
  # `Seo::Page#url` non ha una validazione di formato (a differenza di `Seo::Site#base_url`), quindi
  # il controllo dello schema è l'unica cosa che sta fra la scansione e il browser di chi guarda.
  describe "#seo_safe_url" do
    it "lascia passare http e https" do
      expect(helper.seo_safe_url("https://esempio.it/pagina")).to eq("https://esempio.it/pagina")
      expect(helper.seo_safe_url("http://esempio.it")).to eq("http://esempio.it")
    end

    it "riconosce lo schema anche scritto in maiuscolo" do
      expect(helper.seo_safe_url("HTTPS://esempio.it")).to eq("HTTPS://esempio.it")
    end

    it "rifiuta javascript: — è il caso per cui esiste" do
      expect(helper.seo_safe_url("javascript:alert(1)")).to be_nil
    end

    it "rifiuta gli altri schemi, compresi data: e file:" do
      expect(helper.seo_safe_url("data:text/html;base64,PHNjcmlwdD4=")).to be_nil
      expect(helper.seo_safe_url("file:///etc/passwd")).to be_nil
    end

    it "rifiuta un indirizzo senza schema, che il browser risolverebbe come relativo" do
      expect(helper.seo_safe_url("esempio.it/pagina")).to be_nil
    end

    it "non solleva su valore vuoto o non analizzabile" do
      expect(helper.seo_safe_url(nil)).to be_nil
      expect(helper.seo_safe_url("")).to be_nil
      expect(helper.seo_safe_url("http://[non valido")).to be_nil
    end
  end

  describe "#seo_status_color" do
    it "verde se la pagina risponde, rosso se non c'è" do
      expect(helper.seo_status_color(200)).to eq(:emerald)
      expect(helper.seo_status_color(404)).not_to eq(:emerald)
    end
  end

  # CYRA-537 — il colore di un vitals ha tre fasce, non le quattro delle gravità: «da migliorare» non
  # è «gravità alta», e riusare quella scala lo farebbe leggere così.
  describe "#seo_vital_color e #seo_vital_rating" do
    it "verde, ambra e rosso, e grigio per ciò che non è stato misurato" do
      expect(helper.seo_vital_color(helper.seo_vital_rating("lcp", 1_200))).to eq(:emerald)
      expect(helper.seo_vital_color(helper.seo_vital_rating("lcp", 3_000))).to eq(:amber)
      expect(helper.seo_vital_color(helper.seo_vital_rating("lcp", 9_000))).to eq(:red)
      expect(helper.seo_vital_color(helper.seo_vital_rating("lcp", nil))).to eq(:gray)
    end

    it "il verdetto ha sempre anche una parola, non solo un colore" do
      expect(helper.seo_vital_rating_label(:good)).to eq(I18n.t("seo.vitals.ratings.good"))
      expect(helper.seo_vital_rating_label(nil)).to eq(I18n.t("seo.vitals.ratings.unknown"))
    end
  end

  describe "#seo_vital_value" do
    it "secondi sopra il secondo, millisecondi sotto" do
      expect(helper.seo_vital_value("lcp", 2_400)).to eq(I18n.t("seo.vitals.units.seconds", value: "2.4"))
      expect(helper.seo_vital_value("inp", 180)).to eq(I18n.t("seo.vitals.units.milliseconds", value: 180))
    end

    it "il CLS non ha unità e si legge con tre decimali" do
      expect(helper.seo_vital_value("cls", 0.085)).to eq("0.085")
    end

    # Un trattino dice «non lo so»; uno zero direbbe «perfetto», che è il contrario.
    it "una misura assente resta un trattino, mai uno zero" do
      expect(helper.seo_vital_value("lcp", nil)).to eq("—")
    end
  end

  # CYRA-536 — tre esiti, mai uno che somigli a un altro: un giro fallito che si legge come un sito a
  # posto è la cosa peggiore che la scheda possa fare.
  describe "#seo_site_last_check_text" do
    it "dice quando non è mai stato controllato" do
      site = build(:seo_site, last_audited_at: nil)

      expect(helper.seo_site_last_check_text(site)).to eq(I18n.t("member.monitoring.seo_sites.never_audited"))
    end

    it "dice che l'ultimo giro è fallito, col suo motivo" do
      site = build(:seo_site, last_audited_at: 1.hour.ago, last_error: "robots.txt irraggiungibile")

      expect(helper.seo_site_last_check_text(site)).to include("robots.txt irraggiungibile")
    end

    it "dice da quanto tempo, quando è andato bene" do
      site = build(:seo_site, last_audited_at: 2.hours.ago, last_error: nil)

      expect(helper.seo_site_last_check_text(site)).to include("2")
    end
  end
end
