# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog::Areas do
  describe ".slug_for_path" do
    it "riconosce l'area dal path della destinazione" do
      expect(described_class.slug_for_path("/member/tickets")).to eq("tickets")
    end

    it "riconosce una pagina figlia dell'area" do
      expect(described_class.slug_for_path("/member/knowledge/pages")).to eq("knowledge")
    end

    it "sceglie il prefisso più specifico quando due si sovrappongono" do
      expect(described_class.slug_for_path("/member/home/approvals")).to eq("approvals")
      expect(described_class.slug_for_path("/member/home")).to eq("home")
    end

    it "non confonde due path che iniziano con le stesse lettere" do
      expect(described_class.slug_for_path("/member/monitoring/tokens")).to eq("servers")
      expect(described_class.slug_for_path("/member/monitoring/servers")).to eq("servers")
    end

    it "ignora le guide: sono un rimando di supporto, non un'area del menu" do
      expect(described_class.slug_for_path("/member/guides/uptime")).to be_nil
    end

    it "è nil per un path sconosciuto" do
      expect(described_class.slug_for_path("/member/qualcosa_che_non_esiste")).to be_nil
    end
  end

  describe ".label" do
    it "usa il nome esatto che l'area ha nel menu" do
      expect(described_class.label("uptime")).to eq(I18n.t("member.nav.uptime"))
      expect(described_class.label("performance")).to eq(I18n.t("member.nav.performance"))
      expect(described_class.label("knowledge")).to eq(I18n.t("member.nav.knowledge"))
      expect(described_class.label("agents")).to eq(I18n.t("member.nav.agents"))
    end

    it "è nil per uno slug sconosciuto" do
      expect(described_class.label("inesistente")).to be_nil
    end
  end

  describe ".label_for_path" do
    it "dà il nome di menu della destinazione" do
      expect(described_class.label_for_path("/member/monitoring/monitors")).to eq(I18n.t("member.nav.uptime"))
    end

    it "è nil dove non c'è un'area" do
      expect(described_class.label_for_path("/member/guides/uptime")).to be_nil
    end
  end

  describe ".in_entry" do
    it "estrae le aree dai link interni della voce, senza ripetizioni" do
      testo = "**Titolo**: apri i [Ticket](/member/tickets) e poi ancora i [ticket](/member/tickets)."

      expect(described_class.in_entry(testo)).to eq(%w[tickets])
    end

    it "tiene tutte le aree citate, nell'ordine in cui compaiono" do
      testo = "Vedi [Disponibilità](/member/monitoring/monitors) e [Server](/member/monitoring/servers)."

      expect(described_class.in_entry(testo)).to eq(%w[uptime servers])
    end

    it "non conta il rimando alla guida come area" do
      testo = "**Cosa cambia**: spiegato meglio. ([guida](/member/guides/analytics))"

      expect(described_class.in_entry(testo)).to be_empty
    end

    it "ignora i link esterni" do
      testo = "Un indirizzo [esterno](https://esempio.test) non è un'area."

      expect(described_class.in_entry(testo)).to be_empty
    end
  end

  describe ".options" do
    it "elenca le aree come [nome, slug], in ordine alfabetico di nome" do
      nomi = described_class.options.map(&:first)

      expect(nomi).to eq(nomi.sort)
      expect(described_class.options).to include([ I18n.t("member.nav.tickets"), "tickets" ])
    end
  end

  describe ".known" do
    it "tiene solo gli slug riconosciuti" do
      expect(described_class.known([ "tickets", "inventato", "" ])).to eq(%w[tickets])
    end
  end

  # Il ticket nasce da qui: nel changelog la stessa area aveva più nomi («Conoscenza» e «Knowledge»,
  # «Disponibilità» e «Uptime», «Rallentamenti» e «Performance»), e nessuno coincideva col menu.
  describe "coerenza col menu" do
    it "ogni area ha un nome tradotto in italiano e in inglese" do
      described_class::REGISTRY.each_key do |slug|
        %i[it en].each do |locale|
          nome = described_class.label(slug, locale: locale)
          expect(nome).to be_present, "area #{slug} senza nome in #{locale}"
          expect(nome).not_to include("translation missing")
        end
      end
    end

    it "non esistono due aree diverse con lo stesso nome" do
      nomi = described_class::REGISTRY.keys.map { |slug| described_class.label(slug) }

      expect(nomi.uniq.size).to eq(nomi.size), "nomi di area ripetuti: #{nomi.tally.select { |_, n| n > 1 }.keys}"
    end

    # Le pagine che non sono un'area del prodotto: la home (una scorciatoia, non un argomento) e la
    # console interna. Le guide sono escluse per costruzione, vedi il commento del modulo.
    FUORI_AREA = %w[/ /valhalla/settings /valhalla/health].freeze

    # Il guard che tiene aggiornato il registro: una voce nuova che rimanda a una pagina mai citata
    # prima fallisce qui, invece di finire nello storico senza area e sparire da ogni filtro.
    it "copre le pagine che il CHANGELOG cita davvero" do
      paths = Rails.root.join("CHANGELOG.md").read.scan(described_class::INTERNAL_LINK)
                   .map { |_, path| path }.uniq
      senza_area = paths.reject { |path| described_class.slug_for_path(path) || path.start_with?("/member/guides") }

      expect(senza_area - FUORI_AREA).to be_empty,
        "pagine citate dal CHANGELOG senza un'area: #{(senza_area - FUORI_AREA).sort.inspect}"
    end
  end
end
