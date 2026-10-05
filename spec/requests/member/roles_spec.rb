# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Roles", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "gate permissions.manage" do
    it "owner → 200" do
      sign_in(owner)
      get member_roles_path
      expect(response).to have_http_status(:ok)
    end

    it "membro senza permesso → redirect" do
      sign_in(member)
      get member_roles_path
      expect(response).to redirect_to(root_path)
    end

    it "membro con ruolo che concede permissions.manage → 200 (delega)" do
      role = create(:role, organization: org)
      create(:role_permission, role: role, permission_key: "permissions.manage")
      create(:account_role, account: member, organization: org, role: role)
      sign_in(member)
      get member_roles_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET index con ricerca (q)" do
    it "filtra i ruoli per nome (ramo search_q.present?)" do
      create(:role, organization: org, name: "Searchable Role")
      create(:role, organization: org, name: "Altro")
      sign_in(owner)
      get member_roles_path, params: { q: "Searchable" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Searchable Role")
    end
  end

  describe "GET new" do
    it "owner → 200" do
      sign_in(owner)
      get new_member_role_path
      expect(response).to have_http_status(:ok)
    end

    it "le checkbox permesso hanno l'accent indigo (come gli altri form alerting)" do
      sign_in(owner)
      get new_member_role_path
      # Il primo input[name="permission_keys[]"] è l'hidden di fallback (niente selezione) —
      # la checkbox vera si distingue per type="checkbox".
      checkbox = Nokogiri::HTML(response.body).at_css('input[type="checkbox"][name="permission_keys[]"]')
      expect(checkbox["class"]).to include("accent-indigo-600")
    end
  end

  describe "GET edit" do
    it "owner → 200 con le chiavi correnti pre-selezionate" do
      role = create(:role, organization: org, name: "Editable")
      create(:role_permission, role: role, permission_key: "tickets.edit")
      sign_in(owner)
      get edit_member_role_path(role)
      expect(response).to have_http_status(:ok)
    end
  end

  # CYRA-439 — chi amministra non poteva capire cosa concedeva un ruolo: undici permessi su sessanta
  # mostravano il codice tecnico, nessuno spiegava l'effetto, e per leggerli bisognava entrare nel
  # modulo che ha «Elimina» e «Salva» in cima.
  describe "GET show (scheda di sola lettura)" do
    it "elenca i permessi con nome, effetto e perimetro, senza campi di scrittura" do
      role = create(:role, organization: org, name: "Manutentore")
      create(:role_permission, role:, permission_key: "tickets.edit")
      create(:role_permission, role:, permission_key: "servers.execute")
      sign_in(owner)

      get member_role_path(role)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-role-show"')
      expect(response.body).to include('data-test="role-show-key-tickets.edit"')
      expect(response.body).to include(I18n.t("authorization.permissions")[:"servers.execute"])
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("authorization.permission_descriptions")[:"servers.execute"]))
      expect(response.body).not_to include('name="permission_keys[]"')
    end

    it "segnala i permessi delicati e avvisa in cima" do
      role = create(:role, organization: org, name: "Potente")
      create(:role_permission, role:, permission_key: "servers.execute")
      sign_in(owner)

      get member_role_path(role)

      expect(response.body).to include('data-test="role-show-dangerous"')
      expect(response.body).to include('data-test="role-show-danger-servers.execute"')
    end

    it "un ruolo senza permessi lo dice, invece di mostrare una pagina vuota" do
      role = create(:role, organization: org, name: "Vuoto")
      sign_in(owner)

      get member_role_path(role)

      expect(response.body).to include('data-test="role-show-empty"')
    end

    # Il chip ripeteva il numero nell'etichetta: «0 team: 0».
    it "i chip in testata non ripetono il numero nell'etichetta" do
      owner.update!(locale: "it")
      role = create(:role, organization: org, name: "Contato")
      sign_in(owner)

      get member_role_path(role)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('[data-test="role-show-count-teams"]').text.squish).to eq("0 team")
      expect(doc.at_css('[data-test="role-show-count-members"]').text.squish).to eq("0 membri")
    end

    it "un ruolo di un'altra organizzazione → 404" do
      altrove = create(:role, organization: create(:organization), name: "Altrui")
      sign_in(owner)

      get member_role_path(altrove)

      expect(response).to have_http_status(:not_found)
    end

    it "senza permissions.manage non si apre" do
      role = create(:role, organization: org, name: "Chiuso")
      sign_in(member)

      get member_role_path(role)

      expect(response).to have_http_status(:found)
    end
  end

  describe "GET index (aree toccate)" do
    it "mostra le aree al posto del solo conteggio, e linka la scheda" do
      role = create(:role, organization: org, name: "Misto")
      create(:role_permission, role:, permission_key: "tickets.edit")
      create(:role_permission, role:, permission_key: "members.view")
      sign_in(owner)

      get member_roles_path

      expect(response.body).to include(%(data-test="roles-areas-#{role.id}"))
      cell = Nokogiri::HTML(response.body).at_css(%([data-test="roles-areas-#{role.id}"])).text
      expect(cell).to include(I18n.t("authorization.areas.tickets"), I18n.t("authorization.areas.people"))
      expect(response.body).to include(member_role_path(role))
    end

    # La colonna si chiama «Permessi»: «chiavi» era il nome interno.
    it "conta i permessi, non le «chiavi»" do
      owner.update!(locale: "it")
      role = create(:role, organization: org, name: "Contato")
      create(:role_permission, role:, permission_key: "tickets.edit")
      create(:role_permission, role:, permission_key: "members.view")
      sign_in(owner)

      get member_roles_path

      expect(response.body).to include("2 permessi")
      expect(response.body).not_to include("2 chiavi")
    end

    it "un ruolo senza permessi non stampa un elenco di aree vuoto" do
      role = create(:role, organization: org, name: "Nudo")
      sign_in(owner)

      get member_roles_path

      cell = Nokogiri::HTML(response.body).at_css(%([data-test="roles-areas-#{role.id}"])).text
      expect(cell.strip).to eq(I18n.t("member.roles.no_permissions"))
    end
  end

  describe "il modulo di modifica" do
    it "spiega ogni permesso e segnala quelli delicati" do
      role = create(:role, organization: org, name: "Editabile")
      sign_in(owner)

      get edit_member_role_path(role)

      expect(response.body).to include(ERB::Util.html_escape(I18n.t("authorization.permission_descriptions")[:"secrets.read"]))
      expect(response.body).to include('data-test="role-key-danger-servers.execute"')
      expect(response.body).not_to include('data-test="role-key-danger-members.view"')
    end
  end

  describe "POST create" do
    it "crea il ruolo con le chiavi selezionate" do
      sign_in(owner)
      expect do
        post member_roles_path, params: { confirm: "1", name: "Triager", color: "amber",
                                          permission_keys: [ "errors.triage", "errors.promote" ] }
      end.to change(Authorization::Role, :count).by(1)
      role = Authorization::Role.find_by(organization: org, name: "Triager")
      expect(role.permission_keys).to contain_exactly("errors.triage", "errors.promote")
      expect(response).to redirect_to(member_roles_path)
    end

    it "nome blank → 422" do
      sign_in(owner)
      post member_roles_path, params: { name: "", permission_keys: [] }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH update" do
    it "aggiorna nome e riconcilia le chiavi" do
      role = create(:role, organization: org, name: "Old")
      create(:role_permission, role: role, permission_key: "tickets.edit")
      sign_in(owner)
      patch member_role_path(role), params: { confirm: "1", name: "New", permission_keys: [ "errors.triage" ] }
      expect(role.reload.name).to eq("New")
      expect(role.permission_keys).to contain_exactly("errors.triage")
    end

    it "nome vuoto → 422 e re-render del form (ramo else)" do
      role = create(:role, organization: org, name: "Keep")
      sign_in(owner)
      patch member_role_path(role), params: { name: "", permission_keys: [ "errors.triage" ] }
      expect(response).to have_http_status(:unprocessable_content)
      expect(role.reload.name).to eq("Keep")
    end
  end

  describe "DELETE destroy" do
    it "elimina il ruolo" do
      role = create(:role, organization: org)
      sign_in(owner)
      expect { delete member_role_path(role), params: { confirm: "1" } }.to change(Authorization::Role, :count).by(-1)
    end
  end

  describe "anti-BOLA" do
    it "ruolo di un'altra org → 404" do
      other = create(:role) # org diversa
      sign_in(owner)
      get edit_member_role_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-26: il suggerimento va nel bulb title_tip accanto al titolo, mai in una nota
  # disegnata a mano a fondo pagina. Qui la nota default (ruoli di default) si CONSOLIDA
  # nel bulb insieme al consiglio già presente (coordinato con CYRA-3).
  describe "suggerimenti nel bulb title_tip (CYRA-26)" do
    before { sign_in(owner) }

    it "no longer renders the hand-drawn note (info icon) at the bottom of the page" do
      get member_roles_path
      expect(response.body).not_to include("data-icon=\"info\"")
    end
  end
  # CYRA-695 — un ruolo È l'oggetto che assegna i permessi: cancellarlo li toglie in un colpo a tutti
  # i team e a tutte le persone che lo portano, senza annullamento. Su 91 cancellazioni del prodotto
  # 85 chiedono conferma; queste erano fra le sei che non la chiedevano.
  describe "conferma prima di eliminare un ruolo (CYRA-695)" do
    before { sign_in(owner) }

    it "the list dialog names the role and says how many people and teams lose its permissions" do
      role = create(:role, organization: org, name: "Rilasci")
      create(:account_role, account: member, organization: org, role: role)
      create(:team_role, team: create(:team, organization: org), role: role)

      get member_roles_path
      confirm = Nokogiri::HTML(response.body).at_css("dialog[data-test='role-delete-dialog-#{role.id}']").text
      expect(confirm).to include("Rilasci")
      expect(confirm).to include(I18n.t("member.roles.used_members", count: 1))
      expect(confirm).to include(I18n.t("member.roles.used_teams", count: 1))
    end

    it "il pulsante del modulo di modifica chiede la stessa conferma" do
      role = create(:role, organization: org, name: "Rilasci")

      get edit_member_role_path(role)
      button = Nokogiri::HTML(response.body).at_css("[data-test='role-delete']")
      confirm = button.attr("data-turbo-confirm") || button.ancestors("form").first&.attr("data-turbo-confirm")
      expect(confirm).to be_present
      expect(confirm).to include("Rilasci")
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      sign_in(owner)
      role = create(:role, organization: org, name: "Revisori")

      get member_roles_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='role-delete-dialog-#{role.id}']")
      expect(dialog.text).to include(I18n.t("member.roles.delete_dialog.title", name: "Revisori"))
      expect(dialog.at_css("form")["action"]).to eq(member_role_path(role))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='roles-delete-#{role.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
