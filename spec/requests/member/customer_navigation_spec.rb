# frozen_string_literal: true

require "rails_helper"

# CYRA-586 — un cliente esterno vedeva quasi lo stesso menu di chi lavora al sistema, e quasi ogni
# voce lo portava su una pagina vuota: log, vulnerabilità, uptime, lavori programmati, cassaforte,
# dati per l'AI. I dati erano — e restano — filtrati sul suo progetto: il difetto era la promessa.
#
# Qui si prova la regola dalla parte di chi guarda il menu: per un cliente le aree tecniche compaiono
# solo quando contengono già qualcosa di suo, e le aree che sono strumenti del team non compaiono
# affatto. Per chi è nel team non cambia niente: la pagina vuota è quella che insegna ad accendere
# la funzione, e nasconderla toglierebbe l'unico posto da cui si comincia (CYRA-376).
RSpec.describe "Member — il menu di un cliente esterno (CYRA-586)", type: :request do
  let(:org) { create(:organization) }
  let(:cliente) { create(:account) }
  let(:progetto) { create(:project, organization: org) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # I test-id di tutte le voci del menu laterale, gruppi compresi.
  def voci_del_menu
    Nokogiri::HTML(response.body).css("#member-sidebar [data-test]")
                                 .map { |nodo| nodo["data-test"] }
                                 .select { |test| test.start_with?("member-nav-") }
  end

  # Cliente esterno con accesso a un solo progetto e nessun ruolo assegnato: il caso del ticket.
  def entra_come_cliente
    create(:membership, account: cliente, organization: org, role: :customer)
    create(:project_membership, account: cliente, project: progetto)
    sign_in(cliente)
    get root_path
  end

  describe "chi esplora il menu" do
    it "non vede le aree tecniche che per lui sarebbero vuote" do
      entra_come_cliente

      expect(response).to have_http_status(:ok)
      expect(voci_del_menu).not_to include(
        "member-nav-logs", "member-nav-vulnerabilities", "member-nav-errors", "member-nav-performance",
        "member-nav-uptime", "member-nav-crons", "member-nav-status-page"
      )
    end

    it "non vede la cassaforte né i dati per l'AI, che sono strumenti del team" do
      entra_come_cliente

      expect(voci_del_menu).not_to include(
        "member-nav-vault-overview", "member-nav-vault-personal", "member-nav-vault-projects",
        "member-nav-vault-capabilities", "member-nav-datasets"
      )
      expect(voci_del_menu).not_to include("member-nav-group-vault", "member-nav-group-automation")
    end

    it "vede le voci che riguardano il suo lavoro" do
      entra_come_cliente

      expect(voci_del_menu).to include(
        "member-nav-home", "member-nav-projects", "member-nav-tickets", "member-nav-ideas"
      )
    end

    # Rimaste senza destinazioni, le aree non restano nel menu con la sola panoramica: la pagina
    # d'ingresso di un'area vuota è la stessa promessa, scritta una volta sola (CYRA-29).
    it "non lascia in piedi le aree rimaste senza destinazioni" do
      entra_come_cliente

      expect(voci_del_menu).not_to include(
        "member-nav-group-observability", "member-nav-group-infrastructure", "member-nav-group-seo"
      )
    end

    # Le macro-sezioni sono etichette: senza un gruppo sotto restano titoli soli.
    it "non lascia in piedi le etichette delle sezioni rimaste senza aree" do
      entra_come_cliente

      expect(voci_del_menu).not_to include("member-nav-section-account", "member-nav-section-system")
    end
  end

  describe "quando nell'area c'è qualcosa che lo riguarda" do
    it "mostra i log appena il suo progetto ne manda" do
      create(:log_entry, project: progetto)

      entra_come_cliente

      expect(voci_del_menu).to include("member-nav-logs")
    end

    it "mostra l'uptime appena il suo progetto è monitorato" do
      create(:uptime_monitor, project: progetto)

      entra_come_cliente

      expect(voci_del_menu).to include("member-nav-uptime", "member-nav-status-page")
    end

    it "mostra gli errori appena il suo progetto ne registra, e con essi la sua area" do
      create(:error_group, project: progetto)

      entra_come_cliente

      expect(voci_del_menu).to include("member-nav-errors", "member-nav-group-observability")
    end

    # Il sito da tenere d'occhio lo dichiara il team: al cliente l'area serve quando c'è, non prima.
    it "mostra il SEO solo quando il sito del suo progetto è dichiarato" do
      progetto.project_platforms.create!(
        platform: create(:platform, organization: org, supports_analytics: true)
      )

      entra_come_cliente
      expect(voci_del_menu).not_to include("member-nav-seo-sites")

      create(:seo_site, project: progetto)
      get root_path

      expect(voci_del_menu).to include("member-nav-seo-sites")
    end

    # Il confine resta quello dei dati: quello che succede su un progetto non suo non gli accende
    # nessuna voce.
    it "resta senza voce se il contenuto è su un progetto che non gli appartiene" do
      create(:log_entry, project: create(:project, organization: org))

      entra_come_cliente

      expect(voci_del_menu).not_to include("member-nav-logs")
    end
  end

  describe "chi lavora nel team" do
    let(:collega) { create(:account) }

    it "continua a vedere le aree anche quando sono ancora vuote" do
      create(:membership, account: collega, organization: org, role: :member)
      create(:project_membership, account: collega, project: progetto)
      sign_in(collega)

      get root_path

      expect(voci_del_menu).to include(
        "member-nav-logs", "member-nav-vulnerabilities", "member-nav-errors", "member-nav-uptime",
        "member-nav-crons", "member-nav-datasets", "member-nav-vault-personal"
      )
    end
  end
end
