# frozen_string_literal: true

require "rails_helper"

# Pagina «Da sistemare» (CYRA-428): l'unico posto dove si guarda cosa fare adesso sui segreti. Prende
# il posto di tre pagine che rispondevano alla stessa domanda — anomalie, rotazioni, richieste in
# attesa — e di cui due erano quasi sempre vuote. Il gate è la somma dei gate di prima: chi vedeva
# almeno una delle tre pagine vede questa, con dentro soltanto ciò a cui ha diritto.
RSpec.describe "Member::Vault::Attention", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:production) { create(:environment, organization: org, code: "production", label: "Production") }
  let(:staging) { create(:environment, organization: org, code: "staging", label: "Staging") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Un progetto con UN SOLO ambiente dichiarato e almeno un segreto dentro: così non nasce nessuna
  # anomalia collaterale (un ambiente senza segreti, o una variabile presente solo in metà degli
  # ambienti, sarebbero anomalie vere e sporcherebbero gli esempi che parlano d'altro).
  def project_on(environment, name: "SEEDED")
    create(:project, organization: org).tap do |project|
      project.environments << environment
      Secrets::Variables::Set.call(project: project, environment: environment, name: name, value: "v")
    end
  end

  def secret_with_rotation(project:, environment:, name:, days:, rotated_at:)
    variable = Secrets::Variables::Set.call(project: project, environment: environment, name:, value: "v").value
    variable.update!(rotation_interval_days: days, rotated_at:)
    variable
  end

  # Un buco vero: la variabile c'è in produzione e manca nell'altro ambiente dichiarato.
  def project_with_hole(name: "DATABASE_URL")
    create(:project, organization: org).tap do |project|
      project.environments << production
      project.environments << staging
      Secrets::Variables::Set.call(project: project, environment: production, name: name, value: "v")
      Secrets::Variables::Set.call(project: project, environment: staging, name: "OTHER", value: "v")
    end
  end

  def grant_manage(account, on:)
    create(:project_membership, account:, project: on)
    Authorization::SetAccountPermissions.call(organization: on.organization, account:,
                                              allow_keys: [ "secrets.manage" ], actor: owner)
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_vault_attention_path
      expect(response).to redirect_to(login_path)
    end

    it "senza il permesso di sorveglianza e senza richieste da decidere → redirect" do
      sign_in(member)
      get member_vault_attention_path

      expect(response).to redirect_to(root_path)
    end

    it "chi sorveglia il vault apre la pagina" do
      sign_in(owner)
      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.vault_attention.title")))
    end

    # Scenario 2 del ticket: anomalie, rotazioni e richieste in una lista sola.
    it "raccoglie anomalie, rotazioni e richieste in un'unica lista" do
      project_with_hole(name: "DATABASE_URL")
      rotating = project_on(production)
      secret_with_rotation(project: rotating, environment: production, name: "OLD_KEY", days: 30,
                           rotated_at: 90.days.ago)
      create(:secret_change_request, project: rotating, organization: org, environment: production,
                                     requested_by: member, name: "PENDING_TOKEN")

      sign_in(owner)
      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      lista = response.body[/data-test="vault-attention-list".*?<\/section>/m]
      expect(lista).to include("DATABASE_URL", "OLD_KEY", "PENDING_TOKEN")
      expect(lista).to include(I18n.t("member.vault_attention.kind.anomaly"),
                               I18n.t("member.vault_attention.kind.rotation_overdue"),
                               I18n.t("member.vault_attention.kind.change_request"))
    end

    # D12 — an environment with no secrets is not about one secret: its row carries no name and no dash.
    it "an empty environment shows no dash where the secret name would be" do
      empty = create(:project, organization: org)
      empty.environments << production
      create(:secret_health_anomaly, :empty_environment, project: empty, environment: production)

      sign_in(owner)
      get member_vault_attention_path

      row = Capybara.string(response.body).find("[data-test='vault-attention-row']", text: empty.name)
      expect(row).to have_no_css("[data-test='vault-attention-secret-name']")
      expect(row.text).not_to include("—")
    end

    it "mette in cima ciò che rischia di più" do
      in_produzione = project_on(production)
      fuori_produzione = project_on(staging)
      secret_with_rotation(project: in_produzione, environment: production, name: "PROD_OVERDUE",
                           days: 30, rotated_at: 90.days.ago)
      secret_with_rotation(project: fuori_produzione, environment: staging, name: "STAGING_SOON",
                           days: 30, rotated_at: 29.days.ago)

      sign_in(owner)
      get member_vault_attention_path

      expect(response.body.index("PROD_OVERDUE")).to be < response.body.index("STAGING_SOON")
    end

    it "ogni riga dice quanto rischia" do
      progetto = project_on(production)
      secret_with_rotation(project: progetto, environment: production, name: "PROD_OVERDUE", days: 30,
                           rotated_at: 90.days.ago)

      sign_in(owner)
      get member_vault_attention_path

      expect(response.body).to include('data-test="vault-attention-risk-high"')
      expect(response.body).to include(I18n.t("member.vault_attention.risk.high"))
    end

    it "conta quante cose ci sono e quante rischiano di più" do
      progetto = project_on(production)
      secret_with_rotation(project: progetto, environment: production, name: "PROD_OVERDUE", days: 30,
                           rotated_at: 90.days.ago)

      sign_in(owner)
      get member_vault_attention_path

      expect(response.body).to include('data-test="vault-attention-counts"')
      expect(response.body).to include('data-test="vault-attention-stat-total"')
      expect(response.body).to include('data-test="vault-attention-stat-high"')
    end

    it "senza nulla da sistemare mostra lo stato «tutto in ordine»" do
      project_on(production)

      sign_in(owner)
      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="vault-attention-empty"')
    end

    # Il gate composto: chi può solo decidere le richieste entra, ma non vede né anomalie né rotazioni
    # (che restano dietro secrets_audit.view, come prima).
    it "chi può solo decidere le richieste entra e vede quelle, non le anomalie" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      progetto = project_with_hole(name: "DATABASE_URL")
      grant_manage(manager, on: progetto)
      create(:secret_change_request, project: progetto, organization: org, environment: production,
                                     requested_by: owner, name: "PENDING_TOKEN")

      sign_in(manager)
      get member_vault_attention_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PENDING_TOKEN")
      expect(response.body).not_to include("DATABASE_URL")
    end

    it "porta con sé le azioni delle pagine che sostituisce" do
      progetto = project_with_hole(name: "DATABASE_URL")
      change_request = create(:secret_change_request, project: progetto, organization: org,
                                                      environment: production, requested_by: member,
                                                      name: "PENDING_TOKEN")

      sign_in(owner)
      get member_vault_attention_path

      anomaly = Secrets::HealthAnomaly.find_by!(secret_name: "DATABASE_URL")
      expect(response.body).to include(member_acknowledge_vault_health_anomaly_path(anomaly.id))
      expect(response.body).to include(approve_member_vault_change_request_path(change_request))
    end

    # CYRA-924 — the secrets without a rotation rule sort on every column (C9).
    it "sorts the secrets without a rule by variable both ways" do
      project_with_hole(name: "ZETA_SECRET")
      sign_in(owner)

      table = -> { Nokogiri::HTML(response.body).css("[data-test='vault-attention-uncovered-row']").map(&:text).join }
      get member_vault_attention_path(uncovered_sort: "variable")
      expect(table.call.index("OTHER")).to be < table.call.index("ZETA_SECRET")
      get member_vault_attention_path(uncovered_sort: "-variable")
      expect(table.call.index("ZETA_SECRET")).to be < table.call.index("OTHER")
      %w[variable project environment age].each { |key| expect(response.body).to include("uncovered_sort=#{key}").or include("uncovered_sort=-#{key}") }
    end

    # F169 — C1: the list has a bar: search by secret or project, and filters on risk and kind.
    it "narrows the list by risk, kind and search, and says when nothing matches" do
      project_with_hole(name: "DATABASE_URL")
      late = project_on(staging, name: "SEEDED")
      secret_with_rotation(project: late, environment: staging, name: "OLD_TOKEN", days: 30, rotated_at: 90.days.ago)
      sign_in(owner)
      names = -> { Capybara.string(response.body).all("[data-test='vault-attention-secret-name']").map(&:text) }

      get member_vault_attention_path
      expect(response.body).to include('data-test="vault-attention-toolbar"')
      expect(names.call).to include("DATABASE_URL", "OLD_TOKEN")

      get member_vault_attention_path, params: { kind: [ "rotation_overdue" ] }
      expect(names.call).to eq([ "OLD_TOKEN" ])

      get member_vault_attention_path, params: { q: "database" }
      expect(names.call).to eq([ "DATABASE_URL" ])

      get member_vault_attention_path, params: { q: "nothing-like-this" }
      expect(response.body).to include('data-test="vault-attention-no-match"')
      expect(response.body).not_to include('data-test="vault-attention-empty"')
    end

    # F166 — F5: a missing value could only be declared intended; the row now also leads to fixing it.
    it "an anomaly row leads to the project secrets, beside declaring it intended" do
      project = project_with_hole(name: "DATABASE_URL")
      sign_in(owner)

      get member_vault_attention_path

      anomaly = Secrets::HealthAnomaly.find_by!(secret_name: "DATABASE_URL")
      html = Capybara.string(response.body)
      expect(html.find("[data-test='vault-attention-fix-#{anomaly.id}']")[:href]).to eq(member_project_secrets_path(project, q: "DATABASE_URL"))
      expect(html).to have_css("[data-test='vault-attention-acknowledge-#{anomaly.id}']")
    end

    # F24 — the shared dialog opens in the standard shell; its submit, in the header, targets the shared form.
    it "opens the acknowledge dialog in the standard modal shell" do
      project_with_hole(name: "DATABASE_URL")
      sign_in(owner)

      get member_vault_attention_path

      dialog = Nokogiri::HTML(response.body).at_css("dialog[data-test='vault-attention-acknowledge-modal']")
      expect(dialog["class"]).to include("dark:bg-zinc-950")
      expect(dialog["data-dialog-name"]).to eq("health-acknowledge")
      expect(dialog.at_css("header [data-test='vault-attention-acknowledge-submit']")["form"]).to eq("vault-attention-acknowledge-form")
      expect(dialog.at_css("form#vault-attention-acknowledge-form [data-test='vault-attention-acknowledge-reason']")).to be_present
    end

    # F170 — F5: a secret no rule covers has its action on the row: open it where the rule is set.
    it "a secret without a rule links to where the rule is set" do
      project = project_on(production, name: "API_KEY")
      sign_in(owner)

      get member_vault_attention_path

      link = Capybara.string(response.body).find("[data-test='vault-attention-uncovered-row'] [data-test='vault-attention-set-rule']")
      expect(link[:href]).to eq(member_project_secrets_path(project, q: "API_KEY"))
    end

    # Il contesto che non è «da sistemare adesso» resta consultabile sotto la lista: le assenze già
    # dichiarate volute e i segreti senza alcuna regola di rotazione.
    it "tiene sotto la lista le assenze volute e i segreti senza regola" do
      project_with_hole(name: "DATABASE_URL")

      sign_in(owner)
      get member_vault_attention_path
      anomaly = Secrets::HealthAnomaly.find_by!(secret_name: "DATABASE_URL")
      post member_acknowledge_vault_health_anomaly_path(anomaly.id), params: { reason: "Voluto" }
      get member_vault_attention_path

      expect(response.body).to include('data-test="vault-attention-acknowledged"')
      expect(response.body).to include('data-test="vault-attention-uncovered"')
      expect(response.body).to include("OTHER")
    end
  end

  # CYRA-571 — ogni azione di ogni riga costruiva il suo modulo, con dentro un token diverso da tutti
  # gli altri: cinquantuno righe facevano trecentoventuno moduli e quasi un megabyte, e più che
  # comprimere non si poteva (i token sono tutti diversi). Ora il modulo sta in pagina una volta e le
  # righe lo puntano: il peso segue le righe che si vedono, non le azioni che offrono.
  describe "peso della pagina" do
    def moduli(body) = body.scan("<form").size

    # Variabili presenti in produzione e assenti in staging: una anomalia per variabile.
    def buchi(progetto, quanti, da: 0)
      allow_n_plus_one do
        quanti.times do |i|
          ::Secrets::Variables::Set.call(project: progetto, environment: production,
                                         name: "HOLE_#{da + i}", value: "v")
        end
      end
    end

    it "non costruisce un modulo per ogni anomalia da dichiarare voluta" do
      progetto = project_with_hole(name: "DATABASE_URL")
      sign_in(owner)
      get member_vault_attention_path
      con_una = moduli(response.body)

      buchi(progetto, 11)
      get member_vault_attention_path

      # Le anomalie sono tredici: gli undici buchi nuovi più i due di partenza (DATABASE_URL manca in
      # staging, OTHER manca in produzione). CYRA-684 — la lista è a pagine: la prima ne mostra
      # dodici e il pager dichiara il totale pieno.
      expect(response.body.scan('data-test="vault-attention-row"').size).to eq(Pagination::DEFAULT_PER)
      expect(response.body).to include('data-test="vault-attention-pagination"')
      expect(moduli(response.body)).to eq(con_una)
    end

    it "non costruisce un modulo per ogni richiesta da decidere" do
      progetto = project_on(production)
      create(:secret_change_request, project: progetto, organization: org, environment: production,
                                     requested_by: member, name: "PENDING_0")
      sign_in(owner)
      get member_vault_attention_path
      con_una = moduli(response.body)

      allow_n_plus_one do
        9.times do |i|
          create(:secret_change_request, project: progetto, organization: org, environment: production,
                                         requested_by: member, name: "PENDING_#{i + 1}")
        end
      end
      get member_vault_attention_path

      expect(moduli(response.body)).to eq(con_una)
    end

    def dichiara_volute(anomalie)
      allow_n_plus_one do
        anomalie.each do |anomalia|
          anomalia.update!(status: :acknowledged, acknowledged_at: Time.current,
                           acknowledgement_reason: "Voluto", acknowledged_by: owner)
        end
      end
    end

    it "non costruisce un modulo per ogni assenza già dichiarata voluta" do
      progetto = project_with_hole(name: "DATABASE_URL")
      sign_in(owner)
      buchi(progetto, 9)
      get member_vault_attention_path # è la visita che registra le anomalie

      # DATABASE_URL resta da guardare: così fra le due misure la lista non cambia e a cambiare sono
      # solo le assenze volute, che è quello che si sta misurando.
      volute = ::Secrets::HealthAnomaly.where.not(secret_name: "DATABASE_URL").to_a
      dichiara_volute(volute.first(1))
      get member_vault_attention_path
      con_una = moduli(response.body)

      dichiara_volute(volute)
      get member_vault_attention_path

      expect(response.body).to include('data-test="vault-attention-acknowledged"')
      expect(response.body.scan('data-test="vault-attention-acknowledged-row"').size).to eq(volute.size)
      expect(moduli(response.body)).to eq(con_una)
    end

    # La prova che il token del modulo condiviso è quello buono per QUALUNQUE riga: nei test la
    # protezione è spenta, quindi senza questo esempio il rifiuto di tutte le richieste si scoprirebbe
    # rotto solo in produzione.
    it "il modulo condiviso vale per l'indirizzo di ogni riga anche con la protezione accesa" do
      project_with_hole(name: "DATABASE_URL")
      sign_in(owner)
      get member_vault_attention_path # è la visita che registra le anomalie
      anomalia = ::Secrets::HealthAnomaly.find_by!(secret_name: "DATABASE_URL")

      originale = ActionController::Base.allow_forgery_protection
      begin
        ActionController::Base.allow_forgery_protection = true
        get member_vault_attention_path
        # Il token del modulo condiviso, non un altro qualsiasi della pagina: quelli degli altri
        # moduli valgono solo per il loro indirizzo e qui verrebbero rifiutati.
        token = Nokogiri::HTML(response.body).at_css("form#row-actions input[name='authenticity_token']")&.[]("value")
        expect(token).to be_present

        post member_acknowledge_vault_health_anomaly_path(anomalia.id),
             params: { reason: "Voluto", authenticity_token: token }
      ensure
        ActionController::Base.allow_forgery_protection = originale
      end

      expect(response).to redirect_to(member_vault_attention_path)
      expect(anomalia.reload.status).to eq("acknowledged")
    end
  end

  # Gli indirizzi delle tre pagine di prima restano validi: chi li ha nei segnalibri arriva qui.
  describe "le vecchie pagine portano qui" do
    before { sign_in(owner) }

    it "«Cosa non torna» porta a «Da sistemare»" do
      get member_vault_health_path
      expect(response).to redirect_to(member_vault_attention_path)
    end

    it "«Rotazione» porta a «Da sistemare»" do
      get member_vault_rotation_path
      expect(response).to redirect_to(member_vault_attention_path)
    end

    it "«Modifiche ai segreti» porta a «Da sistemare»" do
      get member_vault_change_requests_path
      expect(response).to redirect_to(member_vault_attention_path)
    end
  end
end
