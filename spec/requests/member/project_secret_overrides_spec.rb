# frozen_string_literal: true

require "rails_helper"

# CYRA-79 — la pagina da cui chi gestisce il vault assegna a UNA persona un valore diverso dal default.
RSpec.describe "Member::ProjectSecretOverrides", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  # CYRA-759 — nome FISSO e con l'apostrofo: Faker lo generava a caso, e quando usciva un
  # «Jonas O'Kon» la pagina lo scriveva giustamente `O&#39;Kon` e il confronto qui sotto
  # falliva su una pagina corretta. Fissarlo toglie il caso, e sceglierlo proprio con
  # l'apostrofo fa di questa prova quella che dimostra l'escaping invece di subirlo.
  let(:reader) { create(:account, name: "Jonas O'Kon") }
  let(:project) { create(:project, organization: org) }
  let(:production) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }
  let(:staging) { create(:environment, organization: org, code: "staging").tap { |e| project.environments << e } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    # Il destinatario: un lettore vero dei secret di questo progetto (l'org ha un solo owner).
    create(:membership, account: reader, organization: org, role: :member)
    create(:project_membership, account: reader, project:)
    create(:account_permission, account: reader, organization: org, permission_key: "secrets.read", effect: :allow)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "shared secrets header" do
    it "shows the tabs, a one-line subtitle and no Vault button" do
      sign_in(owner)
      get member_project_secret_overrides_path(project)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='secrets-subnav-overrides'][aria-current='page']")).to be_present
      expect(document.at_css("[data-test='secret-overrides-lead']")).to be_present
      expect(document.at_css("[data-test='secret-overrides-vault-link']")).to be_nil
      expect(document.css("[data-test='member-project-secret-overrides'] h2").map(&:text)).not_to include(I18n.t("member.secret_overrides.section_title"))
    end
  end

  # CYRA-924 — every column but the actions sorts (C9).
  describe "GET index sort" do
    it "sorts by name both ways and offers every column" do
      create(:secret_override, project:, account: reader, environment: production, name: "ZETA_TOKEN")
      create(:secret_override, project:, account: reader, environment: production, name: "ALPHA_KEY")
      sign_in(owner)

      get member_project_secret_overrides_path(project, sort: "name")
      expect(response.body.index("ALPHA_KEY")).to be < response.body.index("ZETA_TOKEN")
      get member_project_secret_overrides_path(project, sort: "-name")
      expect(response.body.index("ZETA_TOKEN")).to be < response.body.index("ALPHA_KEY")
      %w[recipient environment name assigned].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_project_secret_overrides_path(project)
      expect(response).to redirect_to(login_path)
    end

    it "chi gestisce i secret → 200" do
      sign_in(owner)
      get member_project_secret_overrides_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "membro che vede il progetto ma senza secrets.manage → redirect (forbidden)" do
      create(:project_membership, account: member, project:)
      sign_in(member)

      get member_project_secret_overrides_path(project)

      expect(response).to redirect_to(root_path)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      get member_project_secret_overrides_path(create(:project))
      expect(response).to have_http_status(:not_found)
    end

    it "elenca i valori assegnati SENZA mai renderne il valore" do
      Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                   name: "DATABASE_URL", value: "valore-segretissimo", actor: owner)
      sign_in(owner)

      get member_project_secret_overrides_path(project)

      expect(response.body).to include("DATABASE_URL")
      expect(response.body).to include(ERB::Util.html_escape("Jonas O'Kon"))
      expect(response.body).not_to include("valore-segretissimo")
    end

    # CYRA-670 — questa tabella non aveva mai dichiarato di dover scorrere (lo scorrimento era
    # opt-in): su schermo stretto sfondava la pagina invece di scorrere. Ora scorre di default, e
    # nessuno deve più ricordarsi un flag.
    it "su schermo stretto la tabella scorre invece di sfondare la pagina" do
      Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                   name: "DATABASE_URL", value: "v", actor: owner)
      sign_in(owner)

      get member_project_secret_overrides_path(project)

      scroller = Nokogiri::HTML(response.body).css(".overflow-x-auto").find { |node| node.at_css("table") }
      expect(scroller).to be_present
      expect(scroller["data-ui--scroll-hint-target"]).to eq("scroller")
      expect(scroller.parent["data-controller"].to_s).to include("ui--scroll-hint")
    end
  end

  # La pagina vive dentro la scheda dei secret: senza il pulsante nella matrice esisterebbe senza che
  # nessuno la trovi (ed è da lì che la guida dice di passare).
  describe "come ci si arriva" do
    it "la matrice dei secret porta ai valori su misura, ma solo a chi può assegnarli" do
      production
      sign_in(owner)
      get member_project_secrets_path(project)
      expect(response.body).to include(member_project_secret_overrides_path(project))

      create(:project_membership, account: member, project:)
      create(:account_permission, account: member, organization: org, permission_key: "secrets.read", effect: :allow)
      sign_in(member)
      get member_project_secrets_path(project)
      expect(response.body).not_to include(member_project_secret_overrides_path(project))
    end
  end

  describe "POST create" do
    it "assegna il valore alla persona scelta" do
      sign_in(owner)

      post member_project_secret_overrides_path(project),
           params: { confirm: "1", account_id: reader.id, environment_id: production.id, name: "DATABASE_URL", value: "solo-suo" }

      expect(response).to redirect_to(member_project_secret_overrides_path(project))
      override = Secrets::Override.sole
      expect(override.account).to eq(reader)
      expect(override.value).to eq("solo-suo")
      expect(override.created_by).to eq(owner)
    end

    # BOLA: il destinatario si sceglie fra chi quei secret li può già leggere. Un account di un'altra
    # organizzazione non è nemmeno un candidato: la richiesta viene rifiutata, non applicata a metà.
    it "rifiuta un destinatario di un'altra organizzazione" do
      estraneo = create(:account)
      sign_in(owner)

      post member_project_secret_overrides_path(project),
           params: { account_id: estraneo.id, environment_id: production.id, name: "API_KEY", value: "v" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Secrets::Override.count).to be_zero
    end

    it "rifiuta un ambiente non dichiarato dal progetto" do
      altrui = create(:environment, organization: org, code: "preview")
      sign_in(owner)

      post member_project_secret_overrides_path(project),
           params: { account_id: reader.id, environment_id: altrui.id, name: "API_KEY", value: "v" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Secrets::Override.count).to be_zero
    end

    it "senza secrets.manage non assegna niente" do
      create(:project_membership, account: member, project:)
      sign_in(member)

      post member_project_secret_overrides_path(project),
           params: { account_id: reader.id, environment_id: production.id, name: "API_KEY", value: "v" }

      expect(Secrets::Override.count).to be_zero
    end
  end

  describe "DELETE destroy" do
    it "toglie l'override e la persona torna al valore standard" do
      override = Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                              name: "API_KEY", value: "v", actor: owner).value
      sign_in(owner)

      delete member_project_secret_override_path(project, override), params: { confirm: "1" }

      expect(response).to redirect_to(member_project_secret_overrides_path(project))
      expect(Secrets::Override.count).to be_zero
    end

    # Se la cancellazione non riesce, la riga è ancora lì e quella persona continua a ricevere il suo
    # valore: dirle «tolto» sarebbe la bugia peggiore su questa pagina.
    it "una cancellazione fallita non diventa un messaggio di riuscita" do
      override = Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                              name: "API_KEY", value: "v", actor: owner).value
      allow(Secrets::Overrides::Delete).to receive(:call)
        .and_return(Result.err(AppError.new("cancellazione non riuscita", code: "R422-SECRET-007")))
      sign_in(owner)

      delete member_project_secret_override_path(project, override), params: { confirm: "1" }

      expect(flash[:notice]).not_to include("API_KEY")
      expect(flash[:alert]).to eq("cancellazione non riuscita")
      expect(Secrets::Override.count).to eq(1)
    end

    it "override di un altro progetto → 404 (anti-BOLA)" do
      altro_progetto = create(:project, organization: org)
      altro_ambiente = create(:environment, organization: org, code: "production").tap { |e| altro_progetto.environments << e }
      create(:project_membership, account: reader, project: altro_progetto)
      override = Secrets::Overrides::Set.call(project: altro_progetto, environment: altro_ambiente,
                                              account: reader, name: "API_KEY", value: "v", actor: owner).value
      sign_in(owner)

      delete member_project_secret_override_path(project, override), params: { confirm: "1" }

      expect(response).to have_http_status(:not_found)
      expect(Secrets::Override.count).to eq(1)
    end
  end

  # CYRA-78 — il confine ambienti vale anche qui: chi è confinato a staging non assegna valori su
  # production, e nella lista non ne vede nemmeno i nomi.
  describe "confine ambienti" do
    let(:confinato) { create(:account) }

    before do
      create(:membership, account: confinato, organization: org, role: :member,
             secret_environment_codes: [ "staging" ])
      create(:project_membership, account: confinato, project:)
      create(:account_permission, account: confinato, organization: org, permission_key: "secrets.manage", effect: :allow)
      staging
      production
    end

    it "non mostra gli override degli ambienti vietati" do
      Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                   name: "PROD_ONLY", value: "v", actor: owner)
      Secrets::Overrides::Set.call(project:, environment: staging, account: reader,
                                   name: "STG_ONLY", value: "v", actor: owner)
      sign_in(confinato)

      get member_project_secret_overrides_path(project)

      expect(response.body).to include("STG_ONLY")
      expect(response.body).not_to include("PROD_ONLY")
    end

    # Un ambiente vietato non è un campo compilato male: è un tentativo, e come ogni altro ramo del
    # vault lascia traccia PRIMA del rifiuto (CYRA-78).
    it "non assegna su un ambiente vietato, e lascia traccia del tentativo" do
      sign_in(confinato)

      post member_project_secret_overrides_path(project),
           params: { confirm: "1", account_id: reader.id, environment_id: production.id, name: "API_KEY", value: "v" }

      expect(response).to have_http_status(:forbidden)
      expect(Secrets::Override.count).to be_zero
      expect(project.secret_events.where(action: "denied", actor: confinato, name: "API_KEY")).to be_present
    end

    it "un ambiente non dichiarato dal progetto resta un errore di compilazione, non un tentativo" do
      estraneo = create(:environment, organization: org, code: "preview")
      sign_in(confinato)

      post member_project_secret_overrides_path(project),
           params: { account_id: reader.id, environment_id: estraneo.id, name: "API_KEY", value: "v" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(project.secret_events.where(action: "denied")).to be_empty
    end

    it "non toglie un override di un ambiente vietato, e lascia traccia del tentativo" do
      override = Secrets::Overrides::Set.call(project:, environment: production, account: reader,
                                              name: "API_KEY", value: "v", actor: owner).value
      sign_in(confinato)

      delete member_project_secret_override_path(project, override), params: { confirm: "1" }

      expect(response).to have_http_status(:forbidden)
      expect(Secrets::Override.count).to eq(1)
      expect(project.secret_events.where(action: "denied", actor: confinato)).to be_present
    end
  end
end
