# frozen_string_literal: true

require "rails_helper"

# CYRA-740 — le regole del menu member, estratte da OrganizationContext. Si esercitano dal controller
# reale sui rami difficili da raggiungere via request spec: il gate del cliente esterno, la
# memoizzazione e i safe-nav su Current.*.
#
# CYRA-799 — il presenter riceve due collaboratori espliciti: gli elenchi visibili si stubbano
# sull'oggetto (`visible`), i permessi restano quelli del controller.
RSpec.describe Navigation::Visibility do
  subject(:visibility) { controller.send(:navigation_visibility) }

  let(:controller) do
    ctrl = Member::MembersController.new
    ctrl.set_request!(ActionDispatch::TestRequest.create)
    ctrl.set_response!(Member::MembersController.make_response!(ctrl.request))
    ctrl
  end

  after { Current.reset }

  # Voce sidebar "Richieste in attesa" (Vault, CYRA-138 C2b) — gate composto (OR), a differenza di
  # vault_variable_search_nav_visible? (un semplice .exists?): i progetti visibili vanno caricati UNA
  # SOLA VOLTA e riusati per entrambi i rami (manage OR richiedente), altrimenti la memoizzazione
  # "una chiamata sola" salterebbe.
  describe "#vault_change_requests_nav_visible?" do
    # Gli elenchi visibili arrivano dall'oggetto che il controller costruisce: qui si stubba lui.
    def vede(projects)
      elenchi = instance_double(Authorization::VisibleScope, projects: projects)
      allow(controller).to receive(:visible).and_return(elenchi)
      elenchi
    end

    it "vero se l'account gestisce (secrets.manage) almeno un progetto visibile" do
      project = create(:project)
      Current.account = create(:account)
      vede([ project ])
      allow(controller).to receive(:can?).with("secrets.manage", scope: project).and_return(true)

      expect(visibility.vault_change_requests_nav_visible?).to be(true)
    end

    it "vero se l'account è richiedente di una CR pending, anche senza secrets.manage" do
      project = create(:project)
      account = create(:account)
      create(:secret_change_request, project:, requested_by: account)
      Current.account = account
      vede([ project ])
      allow(controller).to receive(:can?).and_return(false)

      expect(visibility.vault_change_requests_nav_visible?).to be(true)
    end

    it "falso senza secrets.manage su alcun progetto visibile e senza richieste pending proprie" do
      project = create(:project)
      Current.account = create(:account)
      vede([ project ])
      allow(controller).to receive(:can?).and_return(false)

      expect(visibility.vault_change_requests_nav_visible?).to be(false)
    end

    it "falso con Current.account nil (safe-nav, nessuna query con requested_by_id nil)" do
      Current.account = nil
      vede([ create(:project) ])
      allow(controller).to receive(:can?).and_return(false)

      expect(visibility.vault_change_requests_nav_visible?).to be(false)
    end

    it "memoizza il risultato (seconda chiamata → i progetti visibili letti una volta sola)" do
      Current.account = create(:account)
      elenchi = vede([])

      expect(visibility.vault_change_requests_nav_visible?).to be(false)
      expect(visibility.vault_change_requests_nav_visible?).to be(false) # ramo memoizzato
      expect(elenchi).to have_received(:projects).once
    end
  end

  # CYRA-940 — the Help desk entry asks for helpdesk.manage on at least one visible project.
  describe "#helpdesk_nav_visible?" do
    let(:project) { create(:project) }

    def sees(projects)
      scope = instance_double(Authorization::VisibleScope, projects: projects)
      allow(controller).to receive(:visible).and_return(scope)
      scope
    end

    before { Current.account = create(:account) }

    it "is true with helpdesk.manage on a visible project" do
      sees(Projects::Project.where(id: project.id))
      allow(controller).to receive(:can?).with("helpdesk.manage", scope: project).and_return(true)

      expect(visibility.helpdesk_nav_visible?).to be(true)
    end

    it "is false without the key on any visible project" do
      sees(Projects::Project.where(id: project.id))
      allow(controller).to receive(:can?).and_return(false)

      expect(visibility.helpdesk_nav_visible?).to be(false)
    end

    it "reads the visible projects once" do
      scope = sees(Projects::Project.none)

      2.times { expect(visibility.helpdesk_nav_visible?).to be(false) }
      expect(scope).to have_received(:projects).once
    end
  end

  # CYRA-586 — il ruolo di membership qui non autorizza niente: decide cosa vale la pena mostrare a
  # un cliente esterno, che nelle aree tecniche non troverebbe mai niente di suo.
  describe "il menu di un cliente esterno" do
    let(:org) { create(:organization) }
    let(:cliente) { create(:account) }

    def entra_come(role)
      membership = create(:membership, account: cliente, organization: org, role: role)
      Current.account = cliente
      Current.organization = org
      controller.instance_variable_set(:@current_membership, membership)
    end

    describe "#customer_actor?" do
      it "vero per un cliente esterno" do
        entra_come(:customer)

        expect(visibility.customer_actor?).to be(true)
      end

      it "falso per chi lavora nel team" do
        entra_come(:member)

        expect(visibility.customer_actor?).to be(false)
      end

      # Un god in un'organizzazione di cui non è membro non ha membership: nessun ramo deve romperlo.
      it "falso senza membership" do
        Current.account = cliente
        Current.organization = org

        expect(visibility.customer_actor?).to be(false)
      end
    end

    describe "#customer_content_gate" do
      it "per chi lavora nel team è sempre vero, e non guarda nemmeno il contenuto" do
        entra_come(:member)
        guardato = false

        expect(visibility.customer_content_gate(:logs) { guardato = true }).to be(true)
        expect(guardato).to be(false)
      end

      it "per un cliente esterno vale quel che dice il contenuto" do
        entra_come(:customer)

        expect(visibility.customer_content_gate(:logs) { false }).to be(false)
        expect(visibility.customer_content_gate(:uptime) { true }).to be(true)
      end

      it "memoizza per chiave: la sidebar attraversa la stessa voce più volte per render" do
        entra_come(:customer)
        letture = 0

        2.times { visibility.customer_content_gate(:logs) { letture += 1; false } }

        expect(letture).to eq(1)
      end
    end

    it "senza contenuto proprio le aree tecniche restano fuori dal menu" do
      entra_come(:customer)

      expect(visibility.logs_nav_visible?).to be(false)
      expect(visibility.errors_nav_visible?).to be(false)
      expect(visibility.performance_nav_visible?).to be(false)
      expect(visibility.vulnerabilities_nav_visible?).to be(false)
      expect(visibility.replays_nav_visible?).to be(false)
      expect(visibility.uptime_nav_visible?).to be(false)
      expect(visibility.crons_nav_visible?).to be(false)
      expect(visibility.alert_notifications_nav_visible?).to be(false)
    end

    it "con del contenuto sul suo progetto l'area torna nel menu" do
      entra_come(:customer)
      progetto = create(:project, organization: org)
      create(:project_membership, account: cliente, project: progetto)
      create(:log_entry, project: progetto)

      expect(visibility.logs_nav_visible?).to be(true)
    end

    it "gli avvisi ricevuti compaiono quando ne ha davvero uno" do
      entra_come(:customer)
      create(:alerting_notification, account: cliente, organization: org, via: :in_app)

      expect(visibility.alert_notifications_nav_visible?).to be(true)
    end

    it "senza account non interroga gli avvisi con un destinatario nullo" do
      entra_come(:customer)
      Current.account = nil

      expect(visibility.alert_notifications_nav_visible?).to be(false)
    end

    it "la cassaforte e i dati per l'AI restano al team" do
      entra_come(:customer)

      expect(visibility.vault_nav_visible?).to be(false)
      expect(visibility.datasets_nav_visible?).to be(false)
    end

    it "per chi lavora nel team niente cambia, nemmeno con le aree vuote" do
      entra_come(:member)

      expect(visibility.vault_nav_visible?).to be(true)
      expect(visibility.logs_nav_visible?).to be(true)
      expect(visibility.uptime_nav_visible?).to be(true)
      expect(visibility.replays_nav_visible?).to be(true)
    end
  end

  # I predicati restano metodi del controller: la barra laterale, le scorciatoie da tastiera e le
  # poche pagine che si gatano da sole li scrivono per nome, e il refactor non deve farlo notare.
  describe "il filo verso il controller" do
    it "il controller risponde ancora a ogni predicato del menu, con la stessa risposta" do
      org = create(:organization)
      account = create(:account)
      create(:membership, account: account, organization: org, role: :member)
      Current.account = account
      Current.organization = org

      NavigationVisibility::NAV_PREDICATES.each do |predicato|
        expect(controller.send(predicato)).to be(visibility.public_send(predicato)),
                                              "#{predicato} risponde diverso passando dal controller"
      end
    end
  end
end
