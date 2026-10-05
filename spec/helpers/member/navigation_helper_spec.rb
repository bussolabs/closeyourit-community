# frozen_string_literal: true

require "rails_helper"

# CYRA-521 — la sidebar non si sceglie più, si costruisce una volta sola. Qui si verifica la forma
# dell'albero (voci fisse, macro-sezioni, gruppi) e le due proprietà che il vecchio modello a space
# non poteva garantire: nessuna voce compare due volte, e il gruppo della pagina aperta è quello che
# si apre da solo.
RSpec.describe Member::NavigationHelper, type: :helper do
  let(:organization) { build_stubbed(:organization) }

  # I gate vivono nei concern del controller (PermissionGates, NavigationVisibility): una view isolata
  # non li conosce, e i verifying double li rifiuterebbero prima di stubbare. Glieli si insegna una
  # volta sola, tutti aperti, così ogni esempio chiude soltanto quello che gli serve.
  GATE = %i[can? helpdesk_nav_visible? can_view_members? can_manage_permissions? can_view_platforms? can_view_environments?
            servers_nav_visible? workload_nav_visible? datasets_nav_visible? agents_nav_visible?
            analytics_nav_visible? seo_nav_visible? product_matrix_nav_visible? session_replay_nav_visible?
            vault_variable_search_nav_visible? vault_change_requests_nav_visible?
            errors_nav_visible? performance_nav_visible? logs_nav_visible? vulnerabilities_nav_visible?
            traces_nav_visible? measurements_nav_visible? session_health_nav_visible?
            replays_nav_visible? uptime_nav_visible? crons_nav_visible? alert_notifications_nav_visible?
            vault_nav_visible?].freeze

  before do
    GATE.each { |gate| helper.define_singleton_method(gate) { |*| true } }
    helper.define_singleton_method(:current_organization) { nil }
    allow(helper).to receive(:current_organization).and_return(organization)
    allow(Current).to receive(:account).and_return(build_stubbed(:account))
    on_page("member/tickets", "index")
  end

  # La pagina corrente decide solo la voce accesa e il gruppo aperto — mai quali voci esistono.
  def on_page(controller_path, action = "index", params = {})
    allow(helper.controller).to receive_messages(controller_path: controller_path, action_name: action)
    helper.define_singleton_method(:params) { ActionController::Parameters.new(params) }
  end

  def all_items(tree)
    tree.pinned + tree.sections.flat_map { |section| section.nodes.flat_map { |node| node.try(:items) || [ node ] } }
  end

  describe "#member_nav_tree" do
    {
      "member/monitoring/traces" => "member-nav-traces",
      "member/monitoring/measurements" => "member-nav-measurements",
      "member/monitoring/measurement_rules" => "member-nav-measurements",
      "member/monitoring/session_health" => "member-nav-session-health"
    }.each do |controller_path, test_id|
      it "highlights only #{test_id} and opens Observability on #{controller_path}" do
        on_page(controller_path)

        tree = helper.member_nav_tree
        expect(all_items(tree).select(&:active).map(&:test)).to eq([ test_id ])
        expect(tree.sections.flat_map(&:nodes).select(&:active).map(&:id)).to eq([ "observability" ])
      end
    end

    # Incident e gruppi sono schede della pagina Uptime: aprirle lasciava il menu senza area accesa.
    %w[member/monitoring/incidents member/monitoring/uptime_groups].each do |controller_path|
      it "aprendo #{controller_path} accende Uptime e apre Infrastruttura" do
        on_page(controller_path)

        infra = helper.member_nav_tree.sections.flat_map(&:nodes).find { |node| node.id == "infrastructure" }
        expect(infra.active).to be(true)
        expect(infra.items.select(&:active).map(&:test)).to eq([ "member-nav-uptime" ])
      end
    end

    # CYRA-593 aveva messo «Lavorazioni» subito sotto le Approvazioni; CYRA-630 l'ha tolta, perché
    # quello che diceva lo dice adesso il secondo numero sulla pagina delle decisioni, e due voci per
    # due tagli della stessa cosa chiedevano a chi guarda di sapere in anticipo quale aprire.
    # CYRA-903 — My work joined the pinned entries, Guides moved to the sidebar footer.
    it "opens with the five pinned entries, in sidebar order" do
      expect(helper.member_nav_tree.pinned.map(&:test)).to eq(
        %w[member-nav-home member-nav-my-work member-nav-approvals member-nav-conversations
           member-nav-home-todos]
      )
    end

    it "keeps Guides out of the pinned entries and offers them as the footer entry" do
      expect(helper.member_nav_tree.pinned.map(&:test)).not_to include("member-nav-guides")
      expect(helper.guides_nav_item.path).to eq(helper.member_guides_path)
    end

    # CYRA-903 — the group name is the link to the overview: no group lists «Overview» among its leaves.
    it "links every group name to its overview and keeps the overview out of the leaves" do
      groups = helper.member_nav_tree.sections.flat_map(&:nodes).select { |node| node.respond_to?(:items) }

      groups.each do |group|
        expect(group.path).to eq(helper.group_overview_path(Navigation::Group.find(group.id)))
        expect(group.items.map(&:overview)).to all(be(false))
      end
    end

    it "lights the group as current page when its overview is open" do
      on_page("member/overviews", "show", group_id: "observability")

      observability = helper.member_nav_tree.sections.flat_map(&:nodes).find { |node| node.id == "observability" }
      expect(observability).to have_attributes(active: true, overview_active: true)
      expect(observability.items.select(&:active)).to be_empty
    end

    it "rende le tre macro-sezioni con i loro nodi" do
      tree = helper.member_nav_tree

      expect(tree.sections.map(&:test)).to eq(
        %w[member-nav-section-work member-nav-section-system member-nav-section-account]
      )
      expect(tree.sections.first.nodes.map(&:id)).to eq(%w[projects product knowledge])
    end

    it "nessuna voce compare in due punti diversi della sidebar" do
      percorsi = all_items(helper.member_nav_tree).map(&:path)

      expect(percorsi).to eq(percorsi.uniq)
    end

    it "porta ticket, idee e carico di lavoro dentro il gruppo Prodotto" do
      prodotto = helper.member_nav_tree.sections.first.nodes.find { |node| node.id == "product" }

      expect(prodotto.items.map(&:test)).to include(
        "member-nav-tickets", "member-nav-ideas", "member-nav-workload"
      )
    end

    it "apre il gruppo che contiene la pagina aperta, e lascia chiusi gli altri" do
      on_page("member/monitoring/error_groups")

      gruppi = helper.member_nav_tree.sections.flat_map(&:nodes)

      expect(gruppi.select(&:active).map(&:id)).to eq([ "observability" ])
    end

    it "accende la voce della pagina aperta dentro il suo gruppo" do
      on_page("member/monitoring/error_groups")

      osservabilita = helper.member_nav_tree.sections.flat_map(&:nodes).find { |node| node.id == "observability" }

      expect(osservabilita.items.select(&:active).map(&:test)).to eq([ "member-nav-errors" ])
    end

    # CYRA-903 — rules, received notifications and channels are their own group, in chain order.
    def alerts_group
      helper.member_nav_tree.sections.flat_map(&:nodes).find { |node| node.id == "alerts" }
    end

    it "puts the alert chain in its own group, right after Infrastructure" do
      system_ids = helper.member_nav_tree.sections.find { |section| section.id == "system" }.nodes.map(&:id)

      expect(system_ids.index("alerts")).to eq(system_ids.index("infrastructure") + 1)
      expect(alerts_group.items.map(&:test)).to eq(
        %w[member-nav-alerts member-nav-alert-notifications member-nav-alert-channels]
      )
      expect(infrastruttura.items.map(&:test)).not_to include("member-nav-alerts", "member-nav-alert-notifications",
                                                             "member-nav-alert-channels")
    end

    it "porta le notifiche ricevute nel menu laterale, subito sotto le regole di avviso" do
      test_ids = alerts_group.items.map(&:test)

      expect(test_ids).to include("member-nav-alerts", "member-nav-alert-notifications")
      expect(test_ids.index("member-nav-alert-notifications")).to eq(test_ids.index("member-nav-alerts") + 1)

      notifiche = alerts_group.items.find { |item| item.test == "member-nav-alert-notifications" }
      expect(notifiche.path).to eq(helper.member_alerting_notifications_path)
    end

    it "opening received notifications lights Alerts and their entry, not the rules" do
      on_page("member/alerting_notifications")

      gruppi = helper.member_nav_tree.sections.flat_map(&:nodes)
      expect(gruppi.select(&:active).map(&:id)).to eq([ "alerts" ])
      expect(alerts_group.items.select(&:active).map(&:test)).to eq([ "member-nav-alert-notifications" ])
    end

    # CYRA-496 — i canali di consegna si raggiungevano solo dal bottone in cima alle regole: chi cerca
    # dove arrivano gli avvisi, e come portarli altrove, guarda nel menu e non li trova. Stanno sotto
    # le due voci degli avvisi, in fondo al gruppo, perché sono l'ultimo anello della catena.
    def infrastruttura
      helper.member_nav_tree.sections.flat_map(&:nodes).find { |node| node.id == "infrastructure" }
    end

    it "porta i canali di consegna nel menu laterale, sotto le voci degli avvisi" do
      test_ids = alerts_group.items.map(&:test)

      expect(test_ids).to include("member-nav-alert-channels")
      expect(test_ids.index("member-nav-alert-channels")).to eq(test_ids.index("member-nav-alert-notifications") + 1)

      canali = alerts_group.items.find { |item| item.test == "member-nav-alert-channels" }
      expect(canali.path).to eq(helper.member_alerting_channels_path)
      expect(canali.label).to eq(I18n.t("member.alerting.channels.title"))
    end

    it "opening delivery channels lights Alerts and their entry, not the rules" do
      on_page("member/alerting_channels")

      gruppi = helper.member_nav_tree.sections.flat_map(&:nodes)
      expect(gruppi.select(&:active).map(&:id)).to eq([ "alerts" ])
      expect(alerts_group.items.select(&:active).map(&:test)).to eq([ "member-nav-alert-channels" ])
    end

    # Il gate è quello del controller: senza il permesso la pagina non si apre, e una voce che porta
    # a una porta chiusa promette qualcosa che non c'è.
    it "senza il permesso sugli avvisi la voce dei canali sparisce, come quella delle regole" do
      allow(helper).to receive(:can?).with(any_args).and_return(true)
      allow(helper).to receive(:can?).with("alerts.manage").and_return(false)

      expect(alerts_group.items.map(&:test)).not_to include("member-nav-alert-channels", "member-nav-alerts")
    end

    # CYRA-453 — in mezzo al menu, accanto agli agenti, c'era una pagina di pura amministrazione:
    # quattro campi obbligatori e una spunta per tornare a una versione più vecchia. Non è una
    # destinazione per chi usa il prodotto: si raggiunge dalla pagina delle macchine, con i permessi.
    it "l'amministrazione delle versioni non è una voce del menu" do
      test_ids = all_items(helper.member_nav_tree).map(&:test)

      expect(test_ids).not_to include("member-nav-skill-bundle")
    end

    it "un gruppo con tutte le voci nascoste non compare, e nemmeno la sua macro-sezione se resta vuota" do
      allow(helper).to receive_messages(datasets_nav_visible?: false, agents_nav_visible?: false,
                                        analytics_nav_visible?: false, seo_nav_visible?: false)

      sistema = helper.member_nav_tree.sections.find { |section| section.id == "system" }

      expect(sistema.nodes.map(&:id)).not_to include("automation", "seo")
    end

    # CYRA-535 — l'area SEO raccoglie le tre pagine del cockpit (che erano schede) e le statistiche
    # del sito (che erano un nodo per una pagina sola).
    it "gives the SEO area its overview link and its four destinations, in this order" do
      seo = helper.member_nav_tree.sections.find { |s| s.id == "system" }.nodes.find { |n| n.id == "seo" }

      expect(seo.link_test).to eq("member-nav-seo-overview")
      expect(seo.items.map(&:test)).to eq(
        %w[member-nav-seo-sites member-nav-seo-issues member-nav-seo-pages member-nav-analytics]
      )
    end

    # Tre pagine sullo stesso controller: `start_with?("member/monitoring/seo")` le accenderebbe
    # tutte insieme, e chi guarda il menu non saprebbe dove si trova.
    it "accende una voce sola per volta dentro il SEO" do
      # `node_definitions` è memoizzato per richiesta: in una request reale l'helper è nuovo ogni
      # volta, qui è lo stesso oggetto e va svuotato fra una pagina e l'altra.
      accese = lambda do
        helper.instance_variable_set(:@node_definitions, nil)
        seo = helper.member_nav_tree.sections.find { |s| s.id == "system" }.nodes.find { |n| n.id == "seo" }
        seo.items.select(&:active).map(&:test)
      end

      on_page("member/monitoring/seo", "index")
      expect(accese.call).to eq([ "member-nav-seo-issues" ])

      on_page("member/monitoring/seo", "pages")
      expect(accese.call).to eq([ "member-nav-seo-pages" ])

      on_page("member/monitoring/seo", "show")
      expect(accese.call).to eq([ "member-nav-seo-issues" ])

      on_page("member/monitoring/seo_sites", "index")
      expect(accese.call).to eq([ "member-nav-seo-sites" ])

      on_page("member/monitoring/analytics", "show")
      expect(accese.call).to eq([ "member-nav-analytics" ])
    end

    # CYRA-535 — le statistiche del sito sono una FOGLIA di SEO, non più un nodo: il loro gate
    # nasconde la voce, non l'area, e l'area resta in piedi con le altre tre.
    it "senza statistiche resta l'area SEO, senza la sua voce" do
      allow(helper).to receive_messages(analytics_nav_visible?: false, seo_nav_visible?: true)

      seo = helper.member_nav_tree.sections.find { |s| s.id == "system" }.nodes.find { |n| n.id == "seo" }

      expect(seo.items.map(&:test)).to include("member-nav-seo-sites", "member-nav-seo-issues")
      expect(seo.items.map(&:test)).not_to include("member-nav-analytics")
    end

    it "senza organizzazione resta la sola Home: nessuna sezione, nessun gruppo" do
      allow(helper).to receive(:current_organization).and_return(nil)

      tree = helper.member_nav_tree

      expect(tree.pinned.map(&:test)).to eq([ "member-nav-home" ])
      expect(tree.sections).to be_empty
    end
  end

  # CYRA-428 — il Vault aveva undici voci: le variabili separate dai file (una distinzione che nessuno
  # fa quando cerca una chiave) e tre voci diverse per la stessa domanda — cosa devo fare adesso — di
  # cui due quasi sempre vuote. Ora ciò che stava diviso vive dentro le pagine, in schede.
  #
  # CYRA-430 aggiunge «Cosa puoi fare qui» subito sotto la panoramica: non è un doppione di una
  # domanda già in elenco — è la domanda che nessuna voce faceva, e le funzioni che elenca non si
  # scoprivano da nessuna parte.
  describe "gruppo Vault (CYRA-428)" do
    def vault
      helper.member_nav_tree.sections.flat_map(&:nodes).find { |node| node.id == "vault" }
    end

    # CYRA-903 — «What you can do here» moved into the vault overview: it explains, it is not a place.
    it "lists its entries in order, without the capabilities page" do
      expect(vault.link_test).to eq("member-nav-vault-overview")
      expect(vault.items.map(&:test)).to eq(
        %w[member-nav-vault-personal member-nav-vault-organization member-nav-vault-projects
           member-nav-vault-attention member-nav-vault-audit]
      )
    end

    it "manda «Personale» alle variabili, che tengono i file nella scheda accanto" do
      expect(vault.items.find { |item| item.test == "member-nav-vault-personal" }.path)
        .to eq(helper.member_personal_secrets_path)
    end

    it "manda «Organizzazione» alle variabili condivise" do
      expect(vault.items.find { |item| item.test == "member-nav-vault-organization" }.path)
        .to eq(helper.member_shared_secrets_path)
    end

    it "senza il permesso sulle variabili condivise «Organizzazione» porta ai file" do
      allow(helper).to receive(:can?).with(any_args).and_return(true)
      allow(helper).to receive(:can?).with("shared_secrets.manage").and_return(false)

      expect(vault.items.find { |item| item.test == "member-nav-vault-organization" }.path)
        .to eq(helper.member_shared_secret_assets_path)
    end

    it "senza nessuno dei due permessi «Organizzazione» sparisce" do
      allow(helper).to receive(:can?).with(any_args).and_return(true)
      allow(helper).to receive(:can?).with("shared_secrets.manage").and_return(false)
      allow(helper).to receive(:can?).with("shared_secret_files.manage").and_return(false)

      expect(vault.items.map(&:test)).not_to include("member-nav-vault-organization")
    end

    it "«Da sistemare» resta a chi può decidere le richieste anche senza sorveglianza" do
      allow(helper).to receive(:can?).with(any_args).and_return(true)
      allow(helper).to receive(:can?).with("secrets_audit.view").and_return(false)

      expect(vault.items.map(&:test)).to include("member-nav-vault-attention")
    end

    it "senza sorveglianza né richieste da decidere «Da sistemare» sparisce" do
      allow(helper).to receive(:can?).with(any_args).and_return(true)
      allow(helper).to receive(:can?).with("secrets_audit.view").and_return(false)
      allow(helper).to receive(:vault_change_requests_nav_visible?).and_return(false)

      expect(vault.items.map(&:test)).not_to include("member-nav-vault-attention")
    end

    # Le pagine dentro una scheda accendono la voce che le contiene, non nessuna: chi arriva ai file
    # personali deve vedere acceso «Personale».
    {
      "member/personal_secret_assets" => "member-nav-vault-personal",
      "member/personal_secret_versions" => "member-nav-vault-personal",
      "member/shared_secret_assets" => "member-nav-vault-organization",
      "member/vault/variable_search" => "member-nav-vault-projects",
      "member/project_secrets" => "member-nav-vault-projects",
      "member/vault/attention" => "member-nav-vault-attention"
    }.each do |controller_path, test_id|
      it "aprendo #{controller_path} accende #{test_id}" do
        on_page(controller_path)

        expect(vault.items.select(&:active).map(&:test)).to eq([ test_id ])
      end
    end

    # Gli indirizzi vecchi portano alla pagina nuova: durante quel redirect nessuna voce deve accendersi
    # a metà. Le tre pagine sostituite non hanno più una voce propria.
    it "le tre pagine sostituite non hanno più una voce di menu" do
      percorsi = vault.items.map(&:path)

      expect(percorsi).not_to include(helper.member_vault_health_path, helper.member_vault_rotation_path,
                                      helper.member_vault_change_requests_path)
    end
  end

  # CYRA-586 — le aree tecniche non sono più visibili per definizione: ognuna ha il suo gate, e per
  # un cliente esterno quel gate è vero solo dove c'è già qualcosa di suo. Qui si verifica che il
  # menu li consumi tutti — quale sia la condizione dietro ognuno lo decide Navigation::Visibility.
  describe "le aree tecniche seguono il loro gate (CYRA-586)" do
    def voci_del_menu
      all_items(helper.member_nav_tree).map(&:test)
    end

    {
      errors_nav_visible?: "member-nav-errors",
      performance_nav_visible?: "member-nav-performance",
      logs_nav_visible?: "member-nav-logs",
      traces_nav_visible?: "member-nav-traces",
      measurements_nav_visible?: "member-nav-measurements",
      session_health_nav_visible?: "member-nav-session-health",
      vulnerabilities_nav_visible?: "member-nav-vulnerabilities",
      replays_nav_visible?: "member-nav-replays",
      crons_nav_visible?: "member-nav-crons",
      alert_notifications_nav_visible?: "member-nav-alert-notifications"
    }.each do |gate, test_id|
      it "hides #{test_id} when #{gate} is false" do
        allow(helper).to receive(gate).and_return(false)

        expect(voci_del_menu).not_to include(test_id)
      end
    end

    # Uptime e pagina di stato condividono il gate: la seconda dice quali monitor sono pubblicati, e
    # senza monitor non ha niente da dire nemmeno lei.
    it "senza uptime spariscono sia i controlli sia la pagina di stato" do
      allow(helper).to receive(:uptime_nav_visible?).and_return(false)

      expect(voci_del_menu).not_to include("member-nav-uptime", "member-nav-status-page")
    end

    it "senza la cassaforte sparisce l'area intera, non solo le voci a permesso" do
      allow(helper).to receive(:vault_nav_visible?).and_return(false)

      expect(helper.member_nav_tree.sections.flat_map(&:nodes).map(&:id)).not_to include("vault")
      expect(voci_del_menu).not_to include("member-nav-vault-personal", "member-nav-vault-projects")
    end

    # Tutti i gate aperti = il menu di prima: chi lavora nel team continua a vedere le aree anche
    # quando sono vuote (CYRA-376).
    it "con tutti i gate aperti resta il menu completo" do
      expect(voci_del_menu).to include(
        "member-nav-errors", "member-nav-performance", "member-nav-logs", "member-nav-vulnerabilities",
        "member-nav-traces", "member-nav-measurements", "member-nav-session-health",
        "member-nav-uptime", "member-nav-status-page", "member-nav-crons", "member-nav-vault-personal"
      )
    end
  end

  # CYRA-163/334 — il calcolo dell'accensione su member/tickets distingue tre viste sullo stesso
  # controller. Era già così prima della sidebar unica e non deve essersi perso nel passaggio.
  describe "accensione su member/tickets" do
    def voci_accese
      all_items(helper.member_nav_tree).select(&:active).map(&:test)
    end

    it "la lista filtrata sull'account corrente accende Il mio lavoro, non Ticket" do
      on_page("member/tickets", "list", assignee_id: [ Current.account.id.to_s ])

      expect(voci_accese).to eq([ "member-nav-my-work" ])
    end

    it "la stessa lista con altri filtri torna ad accendere Ticket" do
      on_page("member/tickets", "list", assignee_id: [ "un-altro" ])

      expect(voci_accese).to eq([ "member-nav-tickets" ])
    end
  end
end
