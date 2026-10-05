# frozen_string_literal: true

require "rails_helper"

# CYRA-521 — erede di Navigation::Space. Il registro descrive la sidebar INTERA, sempre la stessa in
# ogni pagina: la membership controller→nodo non sceglie più QUALI voci mostrare (quella era la causa
# del menu che si riscriveva), serve solo a sapere quale gruppo aprire da solo e cosa scrivere nella
# briciola di pane.
RSpec.describe Navigation::Group do
  describe ".ids / .all" do
    it "elenca i nodi di primo livello, voci fisse comprese" do
      expect(described_class.ids).to include("home", "product", "vault")
      expect(described_class.all).to all(be_a(described_class))
      expect(described_class.all.map(&:id)).to eq(described_class.ids)
    end
  end

  describe ".find" do
    it "risolve un id noto" do
      expect(described_class.find("vault").id).to eq("vault")
    end

    it "ricade sulla Home per un id ignoto o manomesso (anti-tamper)" do
      expect(described_class.find("../../etc/passwd").id).to eq("home")
      expect(described_class.find(nil).id).to eq("home")
      expect(described_class.find("").id).to eq("home")
    end
  end

  describe ".known?" do
    it "distingue gli id validi da quelli ignoti" do
      expect(described_class.known?("vault")).to be(true)
      expect(described_class.known?(:home)).to be(true)
      expect(described_class.known?("nope")).to be(false)
    end
  end

  describe "#label / #icon" do
    it "espone la label i18n e l'icona dal registro" do
      vault = described_class.find("vault")
      expect(vault.icon).to eq("vault")
      expect(vault.label).to eq(I18n.t("member.nav.group_vault"))
    end
  end

  describe "#pinned? / #section" do
    it "le cinque voci fisse stanno in cima, fuori da ogni macro-sezione" do
      %w[home approvals conversations todos guides].each do |id|
        nodo = described_class.find(id)
        expect(nodo).to be_pinned, "#{id} dovrebbe essere una voce fissa"
        expect(nodo.section).to be_nil
      end
    end

    it "ogni nodo non fisso dichiara una delle tre macro-sezioni" do
      non_fissi = described_class.all.reject(&:pinned?)

      expect(non_fissi).not_to be_empty
      expect(non_fissi.map(&:section).uniq).to match_array(described_class::SECTIONS)
    end
  end

  describe ".sections" do
    it "raggruppa i nodi per macro-sezione, nell'ordine dichiarato" do
      expect(described_class.sections.keys).to eq(described_class::SECTIONS)
      expect(described_class.sections["work"].map(&:id)).to eq(%w[projects product knowledge])
      expect(described_class.sections["account"].map(&:id)).to eq(%w[vault settings])
    end
  end

  describe ".pinned" do
    it "sono le voci di uso quotidiano, nell'ordine della sidebar" do
      # Elenco fissato apposta: una voce in cima e' spazio caro, e ci finisce solo cio' che si apre
      # ogni giorno. Aggiungerne una deve essere una decisione, non una conseguenza — quindi questa
      # riga va cambiata a mano. Lavorazioni sta accanto alle Approvazioni, con cui fa coppia
      # (CYRA-593): la' cio' che aspetta una decisione, qui tutto il resto che sta girando.
      # CYRA-630 — «workflows» non è più fra le voci fisse: la pagina è diventata il secondo elenco
      # delle decisioni, e quello che la voce diceva lo dice il numero accanto al primo.
      expect(described_class.pinned.map(&:id)).to eq(%w[home approvals conversations todos guides])
    end
  end

  describe "uguaglianza" do
    it "due nodi con lo stesso id sono uguali e condividono l'hash" do
      expect(described_class.new("vault")).to eq(described_class.new("vault"))
      expect(described_class.new("vault").hash).to eq(described_class.new("vault").hash)
      expect(described_class.new("vault")).not_to eq(described_class.new("home"))
    end
  end

  describe ".for_controller" do
    it "porta Ticket, Idee e Carico di lavoro nel gruppo Prodotto" do
      expect(described_class.for_controller("member/tickets").id).to eq("product")
      expect(described_class.for_controller("member/ideas").id).to eq("product")
      expect(described_class.for_controller("member/workload/actions").id).to eq("product")
    end

    it "porta Knowledge, Book e matrice funzionalità nel gruppo Conoscenza" do
      expect(described_class.for_controller("member/knowledge/pages").id).to eq("knowledge")
      expect(described_class.for_controller("member/knowledge/books").id).to eq("knowledge")
      expect(described_class.for_controller("member/product/matrices").id).to eq("knowledge")
    end

    it "porta i progetti e le loro pagine di dettaglio sulla voce Progetti" do
      expect(described_class.for_controller("member/projects").id).to eq("projects")
      expect(described_class.for_controller("member/groups").id).to eq("projects")
      expect(described_class.for_controller("member/project_settings").id).to eq("projects")
    end

    # CYRA-535 — le statistiche del sito stanno dentro SEO: sono la seconda metà della stessa
    # domanda (chi PUÒ arrivare / chi è arrivato) e da nodo a sé non lo lasciavano capire a nessuno.
    it "tiene le statistiche del sito dentro l'area SEO, sottopagine comprese" do
      expect(described_class.for_controller("member/monitoring/analytics").id).to eq("seo")
      expect(described_class.for_controller("member/monitoring/analytics/goals").id).to eq("seo")
      expect(described_class.for_controller("member/monitoring/seo_sites").id).to eq("seo")
    end

    it "separa osservabilità e infrastruttura dentro member/monitoring" do
      expect(described_class.for_controller("member/monitoring/error_groups").id).to eq("observability")
      expect(described_class.for_controller("member/monitoring/monitors").id).to eq("infrastructure")
      # server_databases è un controller a sé: il prefisso "member/monitoring/servers" non lo copre
      # (il match per prefisso vuole lo slash), quindi è dichiarato esplicitamente.
      expect(described_class.for_controller("member/monitoring/server_databases").id).to eq("infrastructure")
    end

    it "il match più specifico vince su quello per prefisso" do
      # member/home/approvals è la sua voce fissa, non la Home che la contiene per prefisso.
      expect(described_class.for_controller("member/home/approvals").id).to eq("approvals")
      expect(described_class.for_controller("member/home/cards").id).to eq("home")
    end

    it "le pagine di servizio stanno sulla Home" do
      %w[member/preferences member/quick_add member/changelog member/saved_views].each do |path|
        expect(described_class.for_controller(path).id).to eq("home"), "#{path} non è sulla Home"
      end
    end

    it "una pagina fuori dall'area member non appartiene ad alcun nodo" do
      expect(described_class.for_controller("valhalla/accounts")).to be_nil
    end
  end
end
