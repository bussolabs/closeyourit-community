# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Members", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }
  let(:member) { create(:account, email: "member@example.com") }
  let!(:member_m) { create(:membership, account: member, organization: org, role: :member) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Conta le occorrenze di un marker data-test nel body renderizzato.
  def count_test(tag) = response.body.scan(%r{data-test=["']#{Regexp.escape(tag)}["']}).size

  # Con la posta ferma l'invito non arriva a nessuno: dal pannello il link deve essere recuperabile,
  # ma solo da chi può invitare — vedere l'elenco dei membri non basta per far entrare qualcuno.
  describe "link di un invito in attesa" do
    let!(:invitation) { create(:invitation, organization: org, email: "linkme@example.com") }

    it "owner: il bottone c'è e il link compare quando lo chiede" do
      sign_in(owner)
      get member_members_path
      expect(response.body).to include("data-test=\"member-invitation-link\"")

      get member_members_path(reveal: invitation.id)
      expect(response.body).to include("data-test=\"invitation-link\"")
      # Il token porta dentro la scadenza, quindi due generazioni non danno la stessa stringa: si
      # verifica che quello in pagina apra QUESTO invito, non che sia uguale a uno rigenerato qui.
      token = response.body[%r{/invitations/([^/"]+)/edit}, 1]
      expect(Connections::Invitation.find_by_token_for(:invitation, token)).to eq(invitation)
    end

    it "chi può solo vedere i membri non ottiene né bottone né link" do
      sign_in(member)
      get member_members_path(reveal: invitation.id)
      expect(response.body).not_to include("data-test=\"member-invitation-link\"")
      expect(response.body).not_to include("data-test=\"invitation-link\"")
    end
  end

  describe "GET /member/members" do
    it "membro senza permesso → redirect a root (gate members.view)" do
      sign_in(member)
      get member_members_path
      expect(response).to redirect_to(root_path)
    end

    it "membro con members.view → 200 con la lista" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "members.view" ], actor: owner
      )
      sign_in(member)
      get member_members_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("member@example.com")
    end

    it "non autenticato → redirect al login" do
      get member_members_path
      expect(response).to redirect_to(login_path)
    end

    context "filtro per ruolo (role[])" do
      before { create(:membership, account: create(:account, email: "filtered-admin@example.com"), organization: org, role: :admin) }

      it "ritorna solo le membership del ruolo richiesto" do
        sign_in(owner)
        get member_members_path, params: { role: [ "admin" ] }

        expect(response).to have_http_status(:ok)
        # 1 sola riga membro (l'admin); member_m e owner_m esclusi.
        expect(count_test("member-member-row")).to eq(1)
        expect(response.body).to include("filtered-admin@example.com")
        expect(response.body).not_to include("member@example.com")
      end
    end

    context "ricerca testuale (q)" do
      it "filtra per email" do
        sign_in(owner)
        get member_members_path, params: { q: "member@example" }

        expect(response).to have_http_status(:ok)
        # Solo la riga di member_m: owner_m è filtrato fuori (1 sola riga membro).
        expect(count_test("member-member-row")).to eq(1)
        expect(response.body).to include("member@example.com")
      end

      it "filtra per nome" do
        create(:membership, account: create(:account, name: "Zelda Searchable", email: "zelda@example.com"), organization: org, role: :member)
        sign_in(owner)
        get member_members_path, params: { q: "Zelda Searchable" }

        expect(response).to have_http_status(:ok)
        expect(count_test("member-member-row")).to eq(1)
        expect(response.body).to include("zelda@example.com")
        expect(response.body).not_to include("member@example.com")
      end
    end

    context "paginazione membri (page)" do
      before do
        # owner_m + member_m esistono già: aggiungo TABLE_PER_PAGE + 1 → totale TABLE_PER_PAGE + 3.
        create_list(:membership, App::Constants::TABLE_PER_PAGE + 1, organization: org, role: :member)
      end

      it "page 1 mostra la prima pagina piena con il footer" do
        sign_in(owner)
        get member_members_path

        expect(response).to have_http_status(:ok)
        expect(count_test("member-member-row")).to eq(App::Constants::TABLE_PER_PAGE)
        expect(count_test("members-pagination")).to eq(1)
      end

      it "page 2 ritorna le righe residue oltre la prima pagina" do
        sign_in(owner)
        get member_members_path, params: { page: 2 }

        expect(response).to have_http_status(:ok)
        # owner + member + (TABLE_PER_PAGE + 1) = TABLE_PER_PAGE + 3 totali → 3 righe in pagina 2.
        expect(count_test("member-member-row")).to eq(3)
      end
    end

    context "paginazione inviti (invitations_page)" do
      before { create_list(:invitation, App::Constants::TABLE_PER_PAGE + 1, organization: org, role: :member) }

      it "invitations_page 2 ritorna gli inviti residui" do
        sign_in(owner)
        get member_members_path, params: { invitations_page: 2 }

        expect(response).to have_http_status(:ok)
        # TABLE_PER_PAGE + 1 inviti → 1 riga in pagina 2.
        expect(count_test("member-invitation-row")).to eq(1)
        expect(count_test("invitations-pagination")).to eq(1)
      end
    end
  end

  # CYRA-556 — le utenze usate dai programmi stavano nell'elenco identiche alle persone: stesso
  # cerchietto con le iniziali, stessa etichetta «Membro» e lo stesso menu che offre «Rendi admin» e
  # «Rimuovi». Il conteggio in testata le sommava alle persone, così il numero prometteva colleghi
  # che non esistono. Ora la riga porta un segno suo e i due numeri sono separati.
  describe "GET /member/members — utenze di servizio (CYRA-556)" do
    let(:bot) { create(:account, :service, name: "Agente Notturno") }
    let!(:bot_m) { create(:membership, account: bot, organization: org, role: :member) }

    def html = Capybara.string(response.body)

    it "la riga di un'utenza di servizio si distingue da quella di una persona" do
      sign_in(owner)
      get member_members_path

      expect(response).to have_http_status(:ok)
      expect(count_test("member-member-row")).to eq(3)
      # Il segno visivo (al posto delle iniziali) e quello scritto, uno per la sola riga dell'utenza.
      expect(count_test("member-service-avatar")).to eq(1)
      expect(count_test("member-role-service")).to eq(1)
      # La persona con lo stesso livello continua a leggersi «Membro»: il suo livello non cambia.
      expect(count_test("member-role-member")).to eq(1)
    end

    # Al livello base «Membro» non aggiunge nulla e traveste l'utenza da collega; se invece qualcuno
    # l'ha portata più in alto, quel privilegio resta scritto — nasconderlo sarebbe peggio.
    it "un'utenza portata più in alto continua a mostrare il suo livello" do
      bot_m.update!(role: :admin)
      sign_in(owner)
      get member_members_path

      expect(count_test("member-role-service")).to eq(1)
      expect(count_test("member-role-admin")).to eq(1)
    end

    it "i conteggi in testata separano le persone dalle utenze di servizio" do
      sign_in(owner)
      get member_members_path

      expect(html).to have_css("[data-test='members-count-members']", text: "2")
      expect(html).to have_css("[data-test='members-count-service']", text: "1")
    end

    # CYRA-924 — the bar carries no count: people and service accounts are counted apart above.
    it "the toolbar carries no count" do
      owner.update!(locale: "it")
      sign_in(owner)
      get member_members_path

      expect(html).not_to have_css("[data-test='members-toolbar']", text: "3 in elenco")
    end
  end

  # CYRA-440: la colonna del ruolo mostra il LIVELLO di membership (owner/admin/member/customer),
  # non i permessi effettivi — che arrivano dai team. La pagina deve dirlo (callout), mostrare in
  # ogni riga i team col loro ruolo e ambito, e scrivere i valori in italiano, senza N+1 sui membri.
  describe "GET /member/members — livello vs ruoli effettivi (CYRA-440)" do
    # L'app localizza dalla preferenza dell'account: renderizzo in italiano come un utente reale.
    before { owner.update!(locale: "it") }

    it "mostra il callout che distingue livello e permessi, con l'intestazione «Livello»" do
      sign_in(owner)
      get member_members_path

      expect(response).to have_http_status(:ok)
      expect(count_test("members-roles-notice")).to eq(1)
      expect(response.body).to include("«Livello»") # frammento del callout (guillemet non escapati)
      expect(response.body).to include(I18n.t("member.members.col_level", locale: :it))
    end

    it "floats the notice and hides it once the person closed it" do
      sign_in(owner)
      get member_members_path
      expect(response.body).to match(/<aside[^>]+data-test="members-roles-notice"/)

      owner.update!(dismissed_notices: [ "members_roles" ])
      get member_members_path
      expect(count_test("members-roles-notice")).to eq(0)
    end

    it "in ogni riga mostra i team del membro coi ruoli portati e lo scope" do
      team = create(:team, organization: org, name: "DriverOne Team", color: "amber")
      role = create(:role, organization: org, name: "Maintainer", color: "sky")
      create(:team_role, team: team, role: role)
      project = create(:project, organization: org, name: "DriverOne")
      create(:team_project_access, team: team, project: project)
      create(:team_membership, team: team, account: member)

      sign_in(owner)
      get member_members_path

      expect(response).to have_http_status(:ok)
      expect(count_test("member-team-roles")).to be >= 1
      expect(response.body).to include("DriverOne Team")
      expect(response.body).to include("Maintainer")
      expect(response.body).to include("DriverOne") # ambito del team
    end

    it "per chi non è in alcun team mostra l'assenza di ruoli portati" do
      sign_in(owner)
      get member_members_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.members.no_team_roles", locale: :it))
    end

    it "scrive in italiano i valori del livello (owner→Proprietario, customer→Cliente)" do
      create(:membership, account: create(:account, email: "cust@example.com"), organization: org, role: :customer)
      sign_in(owner)
      get member_members_path

      expect(response.body).to include("Proprietario") # owner_m
      expect(response.body).to include("Cliente")      # customer
    end

    it "non introduce query N+1 al crescere dei membri con team (gate Prosopite)" do
      # Setup bulk isolato dallo scan: sono INSERT/validazioni di fixture, non N+1 di produzione.
      allow_n_plus_one do
        3.times do |i|
          acc = create(:account, email: "teamed-#{i}@example.com")
          create(:membership, account: acc, organization: org, role: :member)
          team = create(:team, organization: org, name: "Squad #{i}")
          role = create(:role, organization: org, name: "Portato #{i}")
          create(:team_role, team: team, role: role)
          project = create(:project, organization: org, name: "Ambito #{i}")
          create(:team_project_access, team: team, project: project)
          create(:team_membership, team: team, account: acc)
        end
      end

      sign_in(owner)
      get member_members_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH role" do
    it "owner promuove un member ad admin" do
      sign_in(owner)
      patch role_member_member_path(member_m), params: { confirm: "1", role: "admin" }
      expect(response).to redirect_to(member_members_path)
      expect(member_m.reload).to be_admin
    end

    it "un member semplice non può gestire (redirect home)" do
      sign_in(member)
      patch role_member_member_path(member_m), params: { role: "admin" }
      expect(response).to redirect_to(root_path)
      expect(member_m.reload).to be_member
    end

    it "BOLA: membership di un'altra org → 404" do
      sign_in(owner)
      other = create(:membership, role: :member)
      patch role_member_member_path(other), params: { confirm: "1", role: "admin" }
      expect(response).to have_http_status(:not_found)
      expect(other.reload).to be_member
    end
  end

  describe "DELETE destroy" do
    it "admin rimuove un membro" do
      admin = create(:account)
      create(:membership, account: admin, organization: org, role: :admin)
      sign_in(owner)
      expect { delete member_member_path(member_m), params: { confirm: "1" } }.to change(Connections::Membership, :count).by(-1)
      expect(response).to redirect_to(member_members_path)
    end

    it "vieta di rimuovere l'ultimo owner" do
      sign_in(owner)
      delete member_member_path(owner_m), params: { confirm: "1" }
      expect(response).to redirect_to(member_members_path)
      expect(Connections::Membership).to exist(owner_m.id)
    end
  end

  describe "GET edit" do
    it "owner apre il form di modifica del membro" do
      sign_in(owner)
      get edit_member_member_path(member_m)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("member@example.com")
      expect(count_test("member-edit-form")).to eq(1)
    end

    it "membro senza members.edit → redirect a root" do
      sign_in(member)
      get edit_member_member_path(member_m)
      expect(response).to redirect_to(root_path)
    end

    it "non autenticato → redirect al login" do
      get edit_member_member_path(member_m)
      expect(response).to redirect_to(login_path)
    end

    it "BOLA: membership di un'altra org → 404" do
      sign_in(owner)
      other = create(:membership, role: :member)
      get edit_member_member_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    it "allows an owner to update display fields without changing the recovery email" do
      sign_in(owner)
      patch member_member_path(member_m),
            params: { name: "Renamed", email: member.email, handle: "renamed_h" }

      expect(response).to redirect_to(member_members_path)
      member.reload
      expect(member.name).to eq("Renamed")
      expect(member.email).to eq("member@example.com")
      expect(member.handle).to eq("renamed_h")
    end

    it "membro senza members.edit non può aggiornare (redirect home)" do
      sign_in(member)
      patch member_member_path(member_m), params: { name: "Hacked" }
      expect(response).to redirect_to(root_path)
      expect(member.reload.name).not_to eq("Hacked")
    end

    it "nome vuoto → 422, re-render del form con l'errore mostrato" do
      sign_in(owner)
      patch member_member_path(member_m),
            params: { name: "", email: member.email, handle: member.handle }

      expect(response).to have_http_status(:unprocessable_content)
      expect(count_test("member-edit-form")).to eq(1)
      expect(response.body).to include("border-red-400") # marker d'errore del campo
    end

    it "handle di formato invalido → 422 con errore mostrato, senza persistere" do
      sign_in(owner)
      patch member_member_path(member_m),
            params: { name: member.name, email: member.email, handle: "Bad Handle!" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("border-red-400")
      expect(member.reload.handle).not_to eq("bad handle!")
    end

    it "email duplicata → 422 senza persistere" do
      sign_in(owner)
      patch member_member_path(member_m),
            params: { name: member.name, email: owner.email, handle: member.handle }

      expect(response).to have_http_status(:unprocessable_content)
      expect(member.reload.email).to eq("member@example.com")
    end

    it "owner modifica il proprio record (self-edit)" do
      sign_in(owner)
      patch member_member_path(owner_m),
            params: { name: "Owner Renamed", email: owner.email, handle: owner.handle }

      expect(response).to redirect_to(member_members_path)
      expect(owner.reload.name).to eq("Owner Renamed")
    end

    it "non autenticato → redirect al login" do
      patch member_member_path(member_m), params: { name: "X" }
      expect(response).to redirect_to(login_path)
    end

    it "BOLA: membership di un'altra org → 404" do
      sign_in(owner)
      other = create(:membership, role: :member)
      patch member_member_path(other), params: { name: "X" }
      expect(response).to have_http_status(:not_found)
    end
  end

  # Escalation: email/handle sono credenziali globali → un delegato con members.edit ma
  # non owner/god NON deve poter riscrivere l'identità di un target protetto (owner o god),
  # altrimenti takeover via password reset. Owner/god editano chiunque.
  describe "target protetti (owner/god)" do
    let(:delegate) { create(:account, email: "delegate@example.com") }
    let!(:delegate_m) { create(:membership, account: delegate, organization: org, role: :member) }

    before do
      Authorization::SetAccountPermissions.call(
        organization: org, account: delegate, allow_keys: [ "members.edit" ], actor: owner
      )
    end

    it "delegato (members.edit, non owner) → GET edit sull'owner è vietato" do
      sign_in(delegate)
      get edit_member_member_path(owner_m)
      expect(response).to redirect_to(member_members_path)
    end

    it "delegato non può riscrivere l'email dell'owner (no takeover)" do
      sign_in(delegate)
      patch member_member_path(owner_m),
            params: { name: owner.name, email: "attacker@evil.com", handle: owner.handle }

      expect(response).to redirect_to(member_members_path)
      expect(owner.reload.email).not_to eq("attacker@evil.com")
    end

    it "delegato non può editare un account god" do
      god_account = create(:account, god: true, email: "god@example.com")
      god_m = create(:membership, account: god_account, organization: org, role: :member)
      sign_in(delegate)
      patch member_member_path(god_m),
            params: { name: "Hijack", email: god_account.email, handle: god_account.handle }

      expect(response).to redirect_to(member_members_path)
      expect(god_account.reload.name).not_to eq("Hijack")
    end

    it "delegato PUÒ editare un membro normale (delega funziona sui non protetti)" do
      sign_in(delegate)
      patch member_member_path(member_m),
            params: { name: "Peer Renamed", email: member.email, handle: member.handle }

      expect(response).to redirect_to(member_members_path)
      expect(member.reload.name).to eq("Peer Renamed")
    end

    it "owner PUÒ editare l'owner (bypass del guard)" do
      sign_in(owner)
      get edit_member_member_path(owner_m)
      expect(response).to have_http_status(:ok)
    end

    it "god (attore, con membership) PUÒ editare l'owner (privilegiato via true_account.god?)" do
      god_actor = create(:account, god: true, email: "godactor@example.com")
      create(:membership, account: god_actor, organization: org, role: :member)
      sign_in(god_actor)
      get edit_member_member_path(owner_m)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH role — declassare l'ultimo owner" do
    it "viene bloccato con un alert" do
      sign_in(owner)
      patch role_member_member_path(owner_m), params: { confirm: "1", role: "member" }
      expect(response).to redirect_to(member_members_path)
      expect(flash[:alert]).to be_present
      expect(owner_m.reload).to be_owner
    end
  end

  describe "accesso senza organizzazione" do
    it "account non-god senza membership → redirect alla home" do
      orphan = create(:account)
      post login_path, params: { email: orphan.email, password: "Secret123!" }
      get member_members_path
      expect(response).to redirect_to(root_path)
    end

    it "god senza membership → entra comunque nella prima org (cross-tenant nativo), 200" do
      god = create(:account, god: true)
      post login_path, params: { email: god.email, password: "Secret123!" }
      get member_members_path
      expect(response).to have_http_status(:ok)
    end

    it "god senza membership e senza alcuna org → redirect a Valhalla" do
      Connections::Membership.delete_all
      Organizations::Organization.delete_all
      god = create(:account, god: true)
      post login_path, params: { email: god.email, password: "Secret123!" }
      get member_members_path
      expect(response).to redirect_to(valhalla_root_path)
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the removal" do
      sign_in(owner)

      get member_members_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='member-remove-dialog-#{member_m.id}']")
      expect(dialog.text).to include(I18n.t("member.members.remove_dialog.title", name: member.name))
      expect(dialog.at_css("form")["action"]).to eq(member_member_path(member_m))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(dialog.ancestors.first.at_css("[data-test='member-member-remove']")["data-action"]).to eq("ui--dialog#open")
    end
  end
end
