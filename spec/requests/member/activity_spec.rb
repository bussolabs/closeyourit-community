# frozen_string_literal: true

require "rails_helper"

# CYRA-745 — la pagina «chi ha fatto cosa e quando»: un solo posto dove leggere le azioni delle persone,
# compreso il registro dei PERMESSI, che il prodotto scriveva senza che nessuna pagina lo leggesse.
RSpec.describe "Member::Activity", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  # CYRA-759 — nomi FISSI: questa pagina li mostra, e le prove qui sotto li cercano dentro
  # l'HTML. Con un nome generato a caso il confronto dipende dall'estrazione (un apostrofo e la
  # pagina scrive `&#39;`); con l'apostrofo scelto apposta dimostra invece come la pagina lo rende.
  let(:member) { create(:account, name: "Ada D'Angelo") }
  let(:project) { create(:project, organization: org, name: "Progetto Visibile") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_activity_path
      expect(response).to redirect_to(login_path)
    end

    it "senza il permesso activity.view → redirect" do
      sign_in(member)
      get member_activity_path
      expect(response).to redirect_to(root_path)
    end

    it "owner → 200" do
      sign_in(owner)
      get member_activity_path
      expect(response).to have_http_status(:ok)
    end

    # Il difetto che il ticket chiude: il dato c'era, la risposta no.
    it "mostra chi ha cambiato un permesso e su cosa" do
      sign_in(owner)
      create(:authorization_event, organization: org, actor: member, actor_name: member.name,
                                   action: "permission_granted", data: { "role" => "Maintainer" })

      get member_activity_path

      expect(response.body).to include(ERB::Util.html_escape("Ada D'Angelo"))
      expect(response.body).to include("Maintainer")
    end

    it "mostra insieme le azioni di registri diversi" do
      sign_in(owner)
      create(:authorization_event, organization: org, action: "role_created", data: { "role" => "Triager" })
      create(:activity_event, subject: project, organization: org, action: "created")

      get member_activity_path

      expect(response.body).to include("Triager")
      expect(response.body).to include("Progetto Visibile")
    end

    it "filtra per registro d'origine" do
      sign_in(owner)
      etichettato = create(:project, organization: org, name: "Progetto Escluso")
      create(:authorization_event, organization: org, action: "role_created", data: { "role" => "Triager" })
      create(:activity_event, subject: etichettato, organization: org, action: "created")

      get member_activity_path(source: "permissions")

      expect(response.body).to include("Triager")
      expect(response.body).not_to include("Progetto Escluso")
    end

    it "filtra per persona" do
      sign_in(owner)
      altro = create(:account, name: "Persona Esclusa")
      create(:membership, account: altro, organization: org, role: :member)
      create(:authorization_event, organization: org, actor: member, actor_name: member.name,
                                   action: "role_created", data: { "role" => "Tenuto" })
      create(:authorization_event, organization: org, actor: altro, actor_name: altro.name,
                                   action: "role_created", data: { "role" => "Escluso" })

      get member_activity_path(actor_id: member.id)

      expect(response.body).to include("Tenuto")
      expect(response.body).not_to include("Escluso")
    end

    # Somma dei gate, non gate nuovo: la pagina non deve poter diventare la scorciatoia per leggere
    # l'audit del Vault senza averne il permesso.
    it "senza secrets_audit.view le righe dei segreti restano fuori" do
      role = create(:role, organization: org)
      create(:role_permission, role: role, permission_key: "activity.view")
      create(:account_role, account: member, role: role, organization: org)
      create(:secret_event, project: project, organization: org, action: "set", name: "CHIAVE_SEGRETA")

      sign_in(member)
      get member_activity_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("CHIAVE_SEGRETA")
    end

    it "con secrets_audit.view le righe dei segreti entrano" do
      sign_in(owner)
      create(:secret_event, project: project, organization: org, action: "set", name: "CHIAVE_SEGRETA")

      get member_activity_path

      expect(response.body).to include("CHIAVE_SEGRETA")
    end

    # BOLA: la pagina raccoglie tutto in un posto, quindi è anche il posto più comodo da cui leggere
    # quello che non si dovrebbe.
    it "non mostra il lavoro sui progetti che non si vedono" do
      role = create(:role, organization: org)
      create(:role_permission, role: role, permission_key: "activity.view")
      create(:account_role, account: member, role: role, organization: org)
      nascosto = create(:project, organization: org, name: "Progetto Riservato")
      create(:activity_event, subject: nascosto, organization: org, action: "created")

      sign_in(member)
      get member_activity_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Progetto Riservato")
    end

    it "dice quando un'azione è stata fatta entrando nei panni di qualcun altro" do
      sign_in(owner)
      god = create(:account)
      create(:authorization_event, organization: org, actor: member, actor_name: member.name,
                                   true_actor: god, action: "permission_revoked", data: { "role" => "Maintainer" })

      get member_activity_path

      expect(response.body).to include(I18n.t("member.activity.impersonated"))
    end

    it "il periodo si sceglie dalla pagina, non solo dall'indirizzo" do
      sign_in(owner)
      create(:authorization_event, organization: org, action: "role_created", data: { "role" => "Triager" })

      get member_activity_path

      expect(response.body).to include('data-test="activity-filter-from"')
      expect(response.body).to include('data-test="activity-filter-to"')
    end

    it "filtra per periodo" do
      sign_in(owner)
      create(:authorization_event, organization: org, action: "role_created",
                                   data: { "role" => "Vecchio" }, created_at: 5.days.ago)
      create(:authorization_event, organization: org, action: "role_updated",
                                   data: { "role" => "Recente" }, created_at: 1.hour.ago)

      get member_activity_path(from: 2.days.ago.iso8601)

      expect(response.body).to include("Recente")
      expect(response.body).not_to include("Vecchio")
    end

    it "pagina vuota → stato vuoto, non errore" do
      sign_in(owner)
      get member_activity_path
      expect(response.body).to include(I18n.t("member.activity.empty"))
    end

    it "«su cosa» porta al ticket e al progetto" do
      sign_in(owner)
      ticket = create(:ticket, organization: org, project: project)
      create(:ticket_event, ticket: ticket)
      create(:activity_event, subject: project, organization: org, action: "created")

      get member_activity_path

      expect(response.body).to include(%(href="#{member_ticket_path(ticket)}"))
      expect(response.body).to include(%(href="#{member_project_path(project)}"))
    end

    it "shows an owner the project moved to another organization, without a link to it (CYRA-879)" do
      moved = create(:project, organization: create(:organization), name: "Moved Away")
      create(:activity_event, subject: moved, organization: org, action: "moved_out", actor: owner)
      sign_in(owner)

      get member_activity_path

      expect(response.body).to include("Moved Away")
      expect(response.body).not_to include(%(href="#{member_project_path(moved)}"))
    end

    # CYRA-839 — sul telefono il pulsante «Successivo» del piede finiva fuori schermo: riepilogo,
    # scelta righe e pulsanti stavano su una riga sola. Qui si legge che il piede di QUESTA pagina
    # porta la disposizione impilata sotto `sm` e conserva tutte le azioni; la misura in pixel
    # sta in spec/system/member/activity_mobile_pagination_spec.rb.
    it "il piede di paginazione si impila sotto sm e conserva le azioni" do
      sign_in(owner)
      14.times { create(:activity_event, subject: project, organization: org, action: "created") }

      get member_activity_path(per: 12)

      expect(response.body).to include('data-test="activity-pagination"')
      expect(response.body).to include("flex-col")
      expect(response.body).to include("sm:flex-row sm:items-center sm:justify-between")
      expect(response.body).to include('data-test="pagination-summary"')
      expect(response.body).to include('data-test="pagination-controls"')
      expect(response.body).to include("1–12 of 14")
      expect(response.body).to include('data-test="pagination-next"')
      expect(response.body).to include('data-test="pagination-per-25"')
    end
  end

  # La guida serve a rispondere a «l'azione che cerco non c'è»: senza, l'assenza voluta dei registri
  # personali sembra un guasto.
  describe "guida" do
    it "si apre e porta al registro" do
      sign_in(owner)
      get member_guides_activity_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-guide-activity"')
      expect(response.body).to include(member_activity_path)
    end

    it "è raggiungibile dall'indice delle guide" do
      sign_in(owner)
      get member_guides_path
      expect(response.body).to include("member-guides-card-activity")
    end
  end

  # CYRA-924 — a register sorts on the date only: any other column would read six registers whole.
  describe "sorting" do
    def table_text = Nokogiri::HTML(response.body).css("tbody").text

    before do
      sign_in(owner)
      create(:authorization_event, organization: org, action: "role_created", data: { "role" => "OlderRole" },
                                   created_at: 2.days.ago)
      create(:authorization_event, organization: org, action: "role_created", data: { "role" => "NewerRole" },
                                   created_at: 1.hour.ago)
    end

    it "lists the newest first by default" do
      get member_activity_path

      expect(table_text.index("NewerRole")).to be < table_text.index("OlderRole")
    end

    it "lists the oldest first when the date is sorted ascending" do
      get member_activity_path(sort: "occurred_at")

      expect(table_text.index("OlderRole")).to be < table_text.index("NewerRole")
    end

    it "offers the date as the only sortable column" do
      get member_activity_path

      sortable = Nokogiri::HTML(response.body).css("thead a[data-test^='sort-']").map { |a| a["data-test"] }
      expect(sortable).to eq(%w[sort-occurred_at])
    end
  end
end
