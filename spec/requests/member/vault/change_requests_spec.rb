# frozen_string_literal: true

require "rails_helper"

# Le richieste in attesa + azioni approva/rifiuta/ritira (CYRA-138, Fase 4 pezzo C2b — UI
# dell'approvazione a due). Da CYRA-428 l'elenco vive dentro la lista unica di «Da sistemare»: gli
# scenari sono gli stessi, verificati dove le righe stanno adesso. Il gate resta composto
# (vault_change_requests_nav_visible?): un manager di ALMENO un progetto visibile, o chi ha ALMENO una
# propria richiesta pending, raggiunge la pagina; ogni riga è filtrata anti-disclosure (manage sul
# progetto O richiedente).
RSpec.describe "Member::Vault::ChangeRequests", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # secrets.manage è scoped: serve un override org-level PIÙ un link diretto al progetto (visibilità).
  # ORDINE OBBLIGATORIO: la project_membership genera la Connections::Membership mancante (il suo
  # after(:build)) — Authorization::AccountPermission valida che l'account sia già membro dell'org,
  # quindi va creata PRIMA di chiamare SetAccountPermissions (altrimenti fallisce silenziosamente).
  def grant_manage(account, on: project)
    create(:project_membership, account:, project: on)
    Authorization::SetAccountPermissions.call(organization: on.organization, account:, allow_keys: [ "secrets.manage" ], actor: owner)
  end

  def see_project_only(account, on: project)
    create(:project_membership, account:, project: on)
  end

  def pending_change_request(requester:, target_project: project, target_environment: environment, **attrs)
    create(:secret_change_request, project: target_project, organization: target_project.organization,
           environment: target_environment, requested_by: requester, **attrs)
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_vault_change_requests_path
      expect(response).to redirect_to(login_path)
    end

    # L'indirizzo resta valido per chi ce l'ha nei segnalibri: porta alla lista che ora le contiene.
    it "porta alla lista «Da sistemare»" do
      manager = create(:account)
      grant_manage(manager)
      sign_in(manager)

      get member_vault_change_requests_path

      expect(response).to redirect_to(member_vault_attention_path)
    end
  end

  describe "le richieste dentro «Da sistemare»" do
    it "account senza secrets.manage su alcun progetto visibile e senza richieste proprie → redirect (forbidden)" do
      outsider = create(:account)
      see_project_only(outsider)
      sign_in(outsider)

      get member_vault_attention_path

      expect(response).to redirect_to(root_path)
    end

    it "manager senza richieste pending → 200 con lo stato «niente da sistemare»" do
      manager = create(:account)
      grant_manage(manager)
      sign_in(manager)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.vault_attention.empty"))
    end

    it "manager con una richiesta pending sul proprio progetto → 200, elenca la richiesta" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      pending_change_request(requester:, name: "API_KEY")
      sign_in(manager)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("API_KEY")
      expect(response.body).not_to include(I18n.t("member.vault_attention.empty"))
    end

    it "mostra i chip conteggi" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      pending_change_request(requester:, name: "API_KEY")
      sign_in(manager)

      get member_vault_attention_path

      expect(response.body).to include('data-test="vault-attention-stat-decidable"')
    end

    # Nella lista unica la riga non porta affatto il valore proposto: prima era una colonna mascherata,
    # ora non c'è nemmeno il placeholder. L'invariante resta la stessa, più stretta.
    it "il valore proposto non appare MAI in chiaro nel markup" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      pending_change_request(requester:, name: "API_KEY", value: "s3cr3t-in-chiaro")
      sign_in(manager)

      get member_vault_attention_path

      expect(response.body).not_to include("s3cr3t-in-chiaro")
      expect(response.body).to include("API_KEY") # il nome sì, il valore mai
    end

    it "un'azione remove mostra l'etichetta di cancellazione, non di modifica" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      pending_change_request(requester:, name: "OLD_KEY", action: "remove", value: nil)
      sign_in(manager)

      get member_vault_attention_path

      expect(response.body).to include(I18n.t("member.vault_change_requests.action_remove"))
    end

    describe "anti-disclosure e azioni per riga" do
      it "un account che vede il progetto ma non gestisce e non è richiedente NON vede la riga altrui" do
        requester = create(:account)
        grant_manage(requester)
        pending_change_request(requester:, name: "HIDDEN_NAME")

        outsider = create(:account)
        see_project_only(outsider) # vede project, non lo gestisce, non l'ha richiesto

        # Per superare il gate della pagina SENZA concedergli secrets.manage da nessuna parte — un
        # override personale (Authorization::SetAccountPermissions) è ORG-WIDE, non per-progetto: si
        # applica a ogni progetto visibile all'account, quindi concederglielo "su other_project"
        # glielo darebbe automaticamente anche su project (visibile via see_project_only sopra) e
        # vanificherebbe il test. Gli diamo invece una PROPRIA richiesta pending altrove: la
        # condizione B del gate ("richiedente di ≥1 CR pending") non richiede alcun permesso.
        other_project = create(:project, organization: org)
        other_environment = create(:environment, organization: org).tap { |e| other_project.environments << e }
        create(:project_membership, account: outsider, project: other_project)
        pending_change_request(requester: outsider, target_project: other_project,
                                target_environment: other_environment, name: "MINE")
        sign_in(outsider)

        get member_vault_attention_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("HIDDEN_NAME")
        expect(response.body).to include("MINE")
      end

      # F24 — the shared dialog opens in the standard shell; its submit, in the header, targets the shared form.
      it "opens the reject dialog in the standard modal shell" do
        requester = create(:account)
        grant_manage(requester)
        pending_change_request(requester:, name: "API_KEY")
        sign_in(owner)

        get member_vault_attention_path

        dialog = Nokogiri::HTML(response.body).at_css("dialog[data-test='vault-change-request-reject-modal']")
        expect(dialog["class"]).to include("dark:bg-zinc-950")
        expect(dialog["data-dialog-name"]).to eq("change-request-reject")
        expect(dialog.at_css("header [data-test='vault-change-request-reject-submit']")["form"]).to eq("vault-change-request-reject-form")
        expect(dialog.at_css("form#vault-change-request-reject-form [data-test='vault-change-request-reject-reason']")).to be_present
      end

      it "il richiedente vede «Ritira» sulla propria riga ma non «Approva»" do
        requester = create(:account)
        grant_manage(requester)
        change_request = pending_change_request(requester:, name: "API_KEY")
        sign_in(requester)

        get member_vault_attention_path

        expect(response.body).to include("data-test=\"vault-change-request-cancel-#{change_request.id}\"")
        expect(response.body).not_to include("data-test=\"vault-change-request-approve-#{change_request.id}\"")
      end

      it "il manager (non richiedente) vede «Approva»/«Rifiuta» sulla riga altrui ma non «Ritira»" do
        manager = create(:account)
        grant_manage(manager)
        requester = create(:account)
        grant_manage(requester)
        change_request = pending_change_request(requester:, name: "API_KEY")
        sign_in(manager)

        get member_vault_attention_path

        expect(response.body).to include("data-test=\"vault-change-request-approve-#{change_request.id}\"")
        expect(response.body).to include("data-test=\"vault-change-request-reject-#{change_request.id}\"")
        expect(response.body).not_to include("data-test=\"vault-change-request-cancel-#{change_request.id}\"")
      end
    end
  end

  # CYRA-420 — due code con nomi sinonimi e flusso di protezione non scopribile. La coda generale resta
  # «Approvazioni» (glossario CYRA-318); questa, specifica dei segreti, prende un nome disgiunto e la sua
  # pagina insegna il meccanismo anche da vuota.
  describe "disgiunzione dei nomi (CYRA-420)" do
    it "il titolo della coda segreti non coincide con quello della coda generale «Approvazioni»" do
      expect(I18n.t("member.vault_change_requests.title", locale: :it)).to eq("Modifiche ai segreti")
      expect(I18n.t("member.vault_change_requests.title", locale: :it))
        .not_to eq(I18n.t("member.approvals.title", locale: :it))
    end

    # CYRA-428 — la coda dei segreti non ha più una voce propria: le sue richieste stanno dentro «Da
    # sistemare». Quella voce deve restare disgiunta dalla coda generale «Approvazioni».
    it "la voce di menu che le contiene è disgiunta dalla voce «Approvazioni»" do
      expect(I18n.t("member.nav.vault_attention", locale: :it)).to eq("Da sistemare")
      expect(I18n.t("member.nav.vault_attention", locale: :it))
        .not_to eq(I18n.t("member.approvals.title", locale: :it))
    end
  end

  describe "senza richieste la pagina insegna il meccanismo (CYRA-420, Scenario 2)" do
    it "spiega cosa rende protetto un segreto, chi approva e cosa succede nel frattempo" do
      manager = create(:account)
      grant_manage(manager)
      sign_in(manager)

      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.vault_change_requests.how_protected"))
      expect(response.body).to include(I18n.t("member.vault_change_requests.how_approver"))
      expect(response.body).to include(I18n.t("member.vault_change_requests.how_meanwhile"))
    end

    it "linka il punto in cui un segreto viene reso protetto (impostazioni del progetto)" do
      manager = create(:account)
      grant_manage(manager)
      sign_in(manager)

      get member_vault_attention_path

      expect(response.body).to include(I18n.t("member.vault_change_requests.protect_cta"))
      expect(response.body).to include("href=\"#{member_projects_path}\"")
    end
  end

  describe "i contatori sono spiegati nella pagina (CYRA-420, DoD)" do
    it "«Da decidere» ha la sua spiegazione nel markup, anche a coda vuota" do
      manager = create(:account)
      grant_manage(manager)
      sign_in(manager)

      get member_vault_attention_path

      expect(response.body).to include(I18n.t("member.vault_change_requests.stat_decidable_hint"))
    end
  end

  describe "POST approve" do
    it "manager approva: il service applica, il secret cambia, la CR diventa applied" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY", value: "nuovo-valore")
      sign_in(manager)

      post approve_member_vault_change_request_path(change_request), params: { confirm: "1" }

      expect(response).to redirect_to(member_vault_attention_path)
      expect(change_request.reload.status).to eq("applied")
      expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("nuovo-valore")
    end

    it "senza secrets.manage sul progetto → redirect (forbidden), la CR resta pending" do
      outsider = create(:account)
      see_project_only(outsider)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(outsider)

      post approve_member_vault_change_request_path(change_request)

      expect(response).to redirect_to(root_path)
      expect(change_request.reload.status).to eq("pending")
    end

    it "il richiedente stesso (pur avendo secrets.manage) non può approvare la propria richiesta → alert dal service" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(requester)

      post approve_member_vault_change_request_path(change_request), params: { confirm: "1" }

      expect(response).to redirect_to(member_vault_attention_path)
      follow_redirect!
      expect(response.body).to include("Non puoi decidere la tua stessa richiesta")
      expect(change_request.reload.status).to eq("pending")
    end

    it "CR di un progetto non visibile (altra org) → 404 anti-BOLA" do
      manager = create(:account)
      grant_manage(manager)
      other_requester = create(:account)
      other_project = create(:project)
      other_environment = create(:environment, organization: other_project.organization)
        .tap { |e| other_project.environments << e }
      create(:project_membership, account: other_requester, project: other_project)
      foreign_change_request = pending_change_request(requester: other_requester, target_project: other_project,
                                                       target_environment: other_environment, name: "FOREIGN")
      sign_in(manager)

      post approve_member_vault_change_request_path(foreign_change_request)

      expect(response).to have_http_status(:not_found)
    end

    it "una CR già decisa → R409 dal service, redirect con l'alert" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      change_request.update!(status: :applied, decided_by: manager, decided_at: Time.current)
      sign_in(manager)

      post approve_member_vault_change_request_path(change_request), params: { confirm: "1" }

      expect(response).to redirect_to(member_vault_attention_path)
      follow_redirect!
      expect(response.body).to include("La richiesta è già stata decisa")
    end
  end

  describe "POST reject" do
    it "manager rifiuta con motivo: la CR diventa rejected, il secret non cambia" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY", value: "v")
      sign_in(manager)

      post reject_member_vault_change_request_path(change_request), params: { confirm: "1", reason: "Valore non sicuro" }

      expect(response).to redirect_to(member_vault_attention_path)
      expect(change_request.reload).to have_attributes(status: "rejected", reason: "Valore non sicuro")
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end

    it "motivo assente → alert dal service, la CR resta pending" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(manager)

      post reject_member_vault_change_request_path(change_request), params: { confirm: "1", reason: "" }

      expect(response).to redirect_to(member_vault_attention_path)
      follow_redirect!
      expect(response.body).to include("Il motivo del rifiuto è obbligatorio")
      expect(change_request.reload.status).to eq("pending")
    end

    it "senza secrets.manage sul progetto → redirect (forbidden)" do
      outsider = create(:account)
      see_project_only(outsider)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(outsider)

      post reject_member_vault_change_request_path(change_request), params: { reason: "no" }

      expect(response).to redirect_to(root_path)
      expect(change_request.reload.status).to eq("pending")
    end

    it "il richiedente stesso non può rifiutare la propria richiesta → alert dal service" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(requester)

      post reject_member_vault_change_request_path(change_request), params: { confirm: "1", reason: "cambio idea" }

      follow_redirect!
      expect(response.body).to include("Non puoi decidere la tua stessa richiesta")
      expect(change_request.reload.status).to eq("pending")
    end
  end

  describe "POST cancel" do
    it "il richiedente ritira la propria richiesta: diventa cancelled, redirect con notice" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(requester)

      post cancel_member_vault_change_request_path(change_request)

      expect(response).to redirect_to(member_vault_attention_path)
      expect(change_request.reload.status).to eq("cancelled")
    end

    it "un altro account (anche manager) non può ritirare una richiesta non sua → alert dal service" do
      manager = create(:account)
      grant_manage(manager)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      sign_in(manager)

      post cancel_member_vault_change_request_path(change_request)

      follow_redirect!
      expect(response.body).to include("Solo chi ha fatto la richiesta può ritirarla")
      expect(change_request.reload.status).to eq("pending")
    end

    it "anti-BOLA: CR di un progetto non visibile → 404" do
      # Il richiedente della CR e chi effettua la richiesta HTTP devono essere ACCOUNT DIVERSI: se
      # fossero lo stesso account, dandogli project_membership su other_project per creare la CR lo
      # renderebbe visibile anche a lui (stessa org), vanificando il test anti-BOLA.
      my_account = create(:account)
      grant_manage(my_account) # membro di `org`, NESSUN legame con other_project

      other_project = create(:project) # org completamente diversa
      other_environment = create(:environment, organization: other_project.organization)
        .tap { |e| other_project.environments << e }
      other_requester = create(:account)
      create(:project_membership, account: other_requester, project: other_project)
      foreign_change_request = pending_change_request(requester: other_requester, target_project: other_project,
                                                       target_environment: other_environment, name: "FOREIGN")
      sign_in(my_account)

      post cancel_member_vault_change_request_path(foreign_change_request)

      expect(response).to have_http_status(:not_found)
    end
  end
end
