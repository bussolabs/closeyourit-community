# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Members access", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:admin) { create(:account) }
  let(:member) { create(:account) }
  let(:member_membership) { create(:membership, account: member, organization: org, role: :member) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: admin, organization: org, role: :admin)
    member_membership
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET access" do
    it "admin → 200" do
      sign_in(owner)
      get access_member_member_path(member_membership)
      expect(response).to have_http_status(:ok)
    end

    it "membro → redirect (gate)" do
      sign_in(member)
      get access_member_member_path(member_membership)
      expect(response).to redirect_to(root_path)
    end

    it "membership di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:membership, account: create(:account),
                                    organization: create(:organization), role: :member)
      get access_member_member_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "mostra gli override personali del target (blocco @overrides popolato)" do
      Authorization::SetAccountPermissions.call(
        organization: org, account: member, allow_keys: [ "tickets.edit" ], deny_keys: [ "errors.triage" ], actor: owner
      )
      sign_in(owner)
      get access_member_member_path(member_membership)
      expect(response).to have_http_status(:ok)
    end

    # CYRA-580 — i selettori vivono nella scheda «Eccezioni»: la pagina si apre sul riepilogo.
    it "matrice permessi: ogni segmentato tri-stato è un radiogroup etichettato dal nome del permesso (WP2.5)" do
      sign_in(owner)
      get access_member_member_path(member_membership, tab: "overrides")
      expect(response.body).to include('role="radiogroup"')
      expect(response.body).to match(/id="perm-[a-z0-9._]+"/)
      expect(response.body).to include('aria-labelledby="perm-')
    end

    it "matrice permessi: chiave grezza e badge \"non concesso\" non sono più su gray-400 (WP2.5)" do
      sign_in(owner)
      get access_member_member_path(member_membership, tab: "overrides")
      doc = Nokogiri::HTML(response.body)
      overrides_html = doc.at_css('[data-test="member-overrides"]').to_html
      identity_html = doc.at_css('[data-test="member-access-identity"]').to_html
      expect(overrides_html).not_to include("text-gray-400")
      expect(identity_html).not_to include("text-gray-400")
    end
  end

  describe "PATCH update_access" do
    it "admin assegna gruppi e progetti al membro" do
      sign_in(owner)
      group = create(:group, organization: org)
      project = create(:project, organization: org)
      patch access_member_member_path(member_membership),
            params: { confirm: "1", group_ids: [ group.id ], project_ids: [ project.id ] }
      expect(response).to redirect_to(member_members_path)
      expect(member.accessible_groups).to include(group)
      expect(member.directly_accessible_projects).to include(project)
    end

    it "scarta id di un'altra org (anti-BOLA)" do
      sign_in(owner)
      foreign_group = create(:group, organization: create(:organization))
      patch access_member_member_path(member_membership), params: { group_ids: [ foreign_group.id ] }
      expect(member.accessible_groups).to be_empty
    end

    it "membro → redirect (gate)" do
      sign_in(member)
      group = create(:group, organization: org)
      patch access_member_member_path(member_membership), params: { group_ids: [ group.id ] }
      expect(response).to redirect_to(root_path)
    end

    it "redirect alla pagina access con alert quando SetMemberAccess fallisce (ramo else)" do
      sign_in(owner)
      allow(Connections::SetMemberAccess).to receive(:call).and_return(
        Result.err(AppError.new("accesso non valido", code: "R422-ACCESS-001", status: :unprocessable_content))
      )
      patch access_member_member_path(member_membership), params: { confirm: "1", group_ids: [] }
      expect(response).to redirect_to(access_member_member_path(member_membership))
      expect(flash[:alert]).to eq("accesso non valido")
    end
  end

  # CYRA-237: chi gestisce i membri ma NON è owner non può assegnare progetti che non vede già.
  describe "PATCH update_access — guard di visibilità (CYRA-237)" do
    let(:manager) { create(:account) }
    let(:manager_membership) { create(:membership, account: manager, organization: org, role: :member) }
    let(:visible_project) { create(:project, organization: org) }
    let(:hidden_project) { create(:project, organization: org) }

    before do
      manager_membership
      # Gestisce i membri (members.manage) ma NON è owner: unscoped solo owner/god → il manager vede
      # esclusivamente visible_project.
      Authorization::SetAccountPermissions.call(
        organization: org, account: manager, allow_keys: [ "members.manage" ], actor: owner
      )
      create(:project_membership, account: manager, project: visible_project)
    end

    it "assegna a un altro membro un progetto che NON vede → alert, nessuna assegnazione" do
      sign_in(manager)
      patch access_member_member_path(member_membership), params: { confirm: "1", project_ids: [ hidden_project.id ] }
      expect(response).to redirect_to(access_member_member_path(member_membership))
      expect(flash[:alert]).to be_present
      expect(member.directly_accessible_projects).to be_empty
    end

    it "scenario 1: prova a darsi da sé tutti i progetti → rifiutato, niente escalation" do
      sign_in(manager)
      patch access_member_member_path(manager_membership),
            params: { confirm: "1", project_ids: [ visible_project.id, hidden_project.id ] }
      expect(response).to redirect_to(access_member_member_path(manager_membership))
      expect(flash[:alert]).to be_present
      expect(manager.directly_accessible_projects).to contain_exactly(visible_project)
    end

    it "assegna a un altro membro un progetto che vede → ok" do
      sign_in(manager)
      patch access_member_member_path(member_membership), params: { confirm: "1", project_ids: [ visible_project.id ] }
      expect(response).to redirect_to(member_members_path)
      expect(member.directly_accessible_projects).to contain_exactly(visible_project)
    end
  end

  # CYRA-243: progetti e ruoli si scelgono insieme nello stesso form. Se i ruoli sono rifiutati
  # (R403-ACCESS-001) i progetti NON devono restare salvati: il messaggio d'errore dice che non è stato
  # concesso nulla, quindi nulla dev'essere applicato.
  describe "PATCH update_access — atomicità scope/ruoli (CYRA-243)" do
    let(:manager) { create(:account) }
    let(:manager_membership) { create(:membership, account: manager, organization: org, role: :member) }
    let(:visible_project) { create(:project, organization: org) }

    before do
      manager_membership
      Authorization::SetAccountPermissions.call(
        organization: org, account: manager, allow_keys: [ "members.manage" ], actor: owner
      )
      create(:project_membership, account: manager, project: visible_project) # il manager vede il progetto
    end

    it "progetti + un ruolo non concedibile insieme → alert e progetti NON salvati" do
      role = create(:role, organization: org)
      create(:role_permission, role: role, permission_key: "organization.manage")
      sign_in(manager)

      patch access_member_member_path(member_membership),
            params: { confirm: "1", project_ids: [ visible_project.id ], role_ids: [ role.id ] }

      expect(response).to redirect_to(access_member_member_path(member_membership))
      expect(flash[:alert]).to be_present
      expect(member.directly_accessible_projects).to be_empty
      expect(member.assigned_roles.where(organization_id: org.id)).to be_empty
    end

    # Speculare: ruolo concedibile ma progetto NON visibile → è lo scope a essere rifiutato. Anche qui
    # nulla deve restare salvato, ruoli inclusi (atomicità piena, non solo l'ordine).
    it "un ruolo concedibile + un progetto non visibile insieme → alert e ruoli NON salvati" do
      role = create(:role, organization: org) # ruolo senza permessi speciali: concedibile dal manager
      hidden_project = create(:project, organization: org) # il manager NON lo vede
      sign_in(manager)

      patch access_member_member_path(member_membership),
            params: { confirm: "1", project_ids: [ hidden_project.id ], role_ids: [ role.id ] }

      expect(response).to redirect_to(access_member_member_path(member_membership))
      expect(flash[:alert]).to be_present
      expect(member.assigned_roles.where(organization_id: org.id)).to be_empty
      expect(member.directly_accessible_projects).to be_empty
    end
  end

  # CYRA-78 — il confine ambienti sui segreti si imposta anche per gli utenti umani, dalla stessa
  # pagina degli accessi: allow-list valida in tutta l'organizzazione + eccezioni per progetto.
  describe "ambienti dei segreti (CYRA-78)" do
    let(:project) { create(:project, organization: org) }
    let!(:staging) { create(:environment, organization: org, code: "staging") }
    let!(:production) { create(:environment, organization: org, code: "production") }

    # CYRA-580 — la card sta nella scheda «Accesso», insieme a gruppi, progetti e ruoli.
    describe "GET access" do
      it "mostra la card con la lista degli ambienti" do
        sign_in(owner)
        get access_member_member_path(member_membership, tab: "access")

        expect(response.body).to include('data-test="member-secret-environments"')
        expect(response.body).to include(I18n.t("member.members.access.secret_environments_title"))
      end

      it "senza progetti assegnati spiega che prima ne serve uno" do
        sign_in(owner)
        get access_member_member_path(member_membership, tab: "access")

        expect(response.body).to include('data-test="member-secret-environments-empty"')
      end

      it "con un progetto assegnato mostra il selettore di quel progetto" do
        create(:project_membership, account: member, project:)
        sign_in(owner)

        get access_member_member_path(member_membership, tab: "access")

        expect(response.body).to include("member-secret-environments-project-#{project.id}")
      end

      it "per un target owner (accesso a tutto) la card non compare" do
        owner_membership = org.memberships.find_by!(account: owner)
        sign_in(owner)

        get access_member_member_path(owner_membership, tab: "access")

        expect(response.body).not_to include('data-test="member-secret-environments"')
      end
    end

    describe "PATCH update_access" do
      it "salva l'allow-list valida in tutta l'organizzazione, scartando i code inesistenti" do
        sign_in(owner)

        patch access_member_member_path(member_membership),
              params: { confirm: "1", secret_environment_codes: [ "", "staging", "inesistente" ] }

        expect(response).to redirect_to(member_members_path)
        expect(member_membership.reload.secret_environment_codes).to eq([ "staging" ])
      end

      it "salva un'eccezione per progetto" do
        create(:project_membership, account: member, project:)
        sign_in(owner)

        patch access_member_member_path(member_membership),
              params: { confirm: "1", project_ids: [ project.id ], secret_environment_codes: [ "staging" ],
                        project_secret_environments: { project.id.to_s => [ "", "staging", "production" ] } }

        expect(response).to redirect_to(member_members_path)
        access = Connections::AccountSecretAccess.find_by(account: member, project:)
        expect(access.environment_codes).to eq(%w[staging production])
      end

      it "svuotare l'eccezione la rimuove" do
        create(:account_secret_access, account: member, project:, organization: org, environment_codes: [ "production" ])
        sign_in(owner)

        patch access_member_member_path(member_membership),
              params: { confirm: "1", secret_environment_codes: [], project_secret_environments: { project.id.to_s => [ "" ] } }

        expect(Connections::AccountSecretAccess.where(account: member, project:)).not_to exist
      end

      it "un salvataggio che non tocca la card lascia il confine com'era" do
        member_membership.update!(secret_environment_codes: [ "staging" ])
        sign_in(owner)

        patch access_member_member_path(member_membership), params: { project_ids: [ project.id ] }

        expect(member_membership.reload.secret_environment_codes).to eq([ "staging" ])
      end

      it "se i ruoli sono rifiutati, il confine ambienti non resta salvato (atomicità)" do
        manager = create(:account)
        create(:membership, account: manager, organization: org, role: :member)
        Authorization::SetAccountPermissions.call(
          organization: org, account: manager, allow_keys: [ "members.manage" ], actor: owner
        )
        role = create(:role, organization: org)
        create(:role_permission, role: role, permission_key: "organization.manage")
        sign_in(manager)

        patch access_member_member_path(member_membership),
              params: { confirm: "1", role_ids: [ role.id ], secret_environment_codes: [ "staging" ] }

        expect(flash[:alert]).to be_present
        expect(member_membership.reload.secret_environment_codes).to eq([])
      end
    end
  end

  # CYRA-580 — la pagina era alta quasi cinque schermate di selettori a tre posizioni, e il riquadro
  # che risponde alla domanda vera («cosa può fare davvero questa persona») cominciava dopo il 94%.
  # Chi la apre di solito vuole verificare, non riconfigurare: ora la scheda predefinita è di sola
  # lettura e i comandi di modifica stanno nelle altre due.
  describe "GET access — tre schede (CYRA-580)" do
    it "senza ?tab= apre i permessi effettivi, senza nessun comando di modifica in pagina" do
      sign_in(owner)
      get access_member_member_path(member_membership)

      expect(response.body).to include('data-test="member-access-tabs"')
      expect(response.body).to include('data-test="member-access-summary"')
      expect(response.body).not_to include('data-test="member-access-form"')
      expect(response.body).not_to include('data-test="member-overrides"')
      expect(response.body).not_to include('data-test="member-access-submit"')
    end

    it "?tab=access porta gruppi, progetti e ruoli diretti, non le eccezioni" do
      sign_in(owner)
      get access_member_member_path(member_membership, tab: "access")

      expect(response.body).to include('data-test="member-access-form"')
      expect(response.body).to include('data-test="member-access-groups"')
      expect(response.body).to include('data-test="member-access-projects"')
      expect(response.body).to include('data-test="member-direct-roles"')
      expect(response.body).not_to include('data-test="member-overrides"')
    end

    it "?tab=overrides porta le eccezioni, non gruppi/progetti/ruoli" do
      sign_in(owner)
      get access_member_member_path(member_membership, tab: "overrides")

      expect(response.body).to include('data-test="member-overrides"')
      expect(response.body).to include('data-test="member-access-form"')
      expect(response.body).not_to include('data-test="member-access-groups"')
      expect(response.body).not_to include('data-test="member-direct-roles"')
    end

    it "una scheda che non esiste ricade sui permessi effettivi (whitelist)" do
      sign_in(owner)
      get access_member_member_path(member_membership, tab: "qualsiasi-cosa")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-access-summary"')
      expect(response.body).not_to include('data-test="member-access-form"')
    end

    it "la scheda aperta è dichiarata a chi legge con lo schermo (aria-current)" do
      sign_in(owner)
      get access_member_member_path(member_membership, tab: "overrides")

      doc = Nokogiri::HTML(response.body)
      current = doc.css('[data-test="member-access-tabs"] a[aria-current="page"]')
      expect(current.size).to eq(1)
      expect(current.first["data-test"]).to eq("member-access-tab-overrides")
    end

    it "il riepilogo dice quali gruppi, progetti, ruoli ed eccezioni ha la persona" do
      group = create(:group, organization: org, name: "Piattaforma")
      project = create(:project, organization: org, name: "Portale")
      role = create(:role, organization: org, name: "Manutentore")
      create(:account_role, account: member, organization: org, role: role)
      Connections::SetMemberAccess.call(organization: org, account: member,
                                        group_ids: [ group.id ], project_ids: [ project.id ], actor: owner)
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "tickets.edit" ], deny_keys: [ "errors.triage" ], actor: owner)
      sign_in(owner)

      get access_member_member_path(member_membership)

      summary = Nokogiri::HTML(response.body).at_css('[data-test="member-access-summary"]').to_html
      expect(summary).to include("Piattaforma").and include("Portale").and include("Manutentore")
      expect(summary).to include(I18n.t("member.members.access.origin_personal_allow"))
      expect(summary).to include(I18n.t("member.members.access.origin_personal_deny"))
    end

    it "chi gestisce i membri ma non vede lo schema completo legge comunque il riepilogo" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      Authorization::SetAccountPermissions.call(
        organization: org, account: manager, allow_keys: [ "members.manage" ], actor: owner
      )
      sign_in(manager)

      get access_member_member_path(member_membership)

      expect(response.body).to include('data-test="member-access-summary"')
      expect(response.body).not_to include('data-test="access-schema"')
    end

    it "per un target che vede già tutto (owner) non ci sono schede da scegliere" do
      owner_membership = org.memberships.find_by!(account: owner)
      sign_in(owner)

      get access_member_member_path(owner_membership)

      expect(response.body).to include('data-test="member-access-all-notice"')
      expect(response.body).not_to include('data-test="member-access-tabs"')
    end
  end

  # CYRA-580 — con le schede il modulo invia solo i campi della scheda aperta: quello che non è in
  # pagina NON deve sparire dal database. Stesso principio già applicato al confine ambienti (CYRA-78).
  describe "PATCH update_access — salvataggio parziale per scheda (CYRA-580)" do
    let(:group) { create(:group, organization: org) }
    let(:project) { create(:project, organization: org) }
    let(:role) { create(:role, organization: org) }

    before do
      create(:account_role, account: member, organization: org, role: role)
      Connections::SetMemberAccess.call(organization: org, account: member,
                                        group_ids: [ group.id ], project_ids: [ project.id ], actor: owner)
    end

    it "salvare dalla scheda delle eccezioni non azzera gruppi, progetti e ruoli" do
      sign_in(owner)

      patch access_member_member_path(member_membership),
            params: { confirm: "1", tab: "overrides", overrides: { "tickets.edit" => "allow" } }

      expect(response).to redirect_to(member_members_path)
      expect(member.accessible_groups).to include(group)
      expect(member.directly_accessible_projects).to include(project)
      expect(member.assigned_roles.where(organization_id: org.id)).to include(role)
      expect(member.account_permissions.where(organization_id: org.id, permission_key: "tickets.edit").first.effect).to eq("allow")
    end

    it "salvare dalla scheda dell'accesso non azzera le eccezioni personali" do
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "tickets.edit" ], deny_keys: [ "errors.triage" ], actor: owner)
      sign_in(owner)

      patch access_member_member_path(member_membership),
            params: { confirm: "1", tab: "access", group_ids: [ group.id ], project_ids: [ project.id ], role_ids: [ role.id ] }

      expect(response).to redirect_to(member_members_path)
      effects = member.account_permissions.where(organization_id: org.id).pluck(:permission_key, :effect).to_h
      expect(effects).to eq({ "tickets.edit" => "allow", "errors.triage" => "deny" })
    end

    it "un salvataggio senza nessun campo non tocca niente e non esplode" do
      sign_in(owner)

      patch access_member_member_path(member_membership), params: { confirm: "1" }

      expect(response).to redirect_to(member_members_path)
      expect(member.accessible_groups).to include(group)
      expect(member.assigned_roles.where(organization_id: org.id)).to include(role)
    end

    it "un salvataggio rifiutato riporta sulla scheda da cui si stava salvando" do
      manager = create(:account)
      create(:membership, account: manager, organization: org, role: :member)
      Authorization::SetAccountPermissions.call(
        organization: org, account: manager, allow_keys: [ "members.manage" ], actor: owner
      )
      hidden_project = create(:project, organization: org)
      sign_in(manager)

      patch access_member_member_path(member_membership),
            params: { confirm: "1", tab: "access", project_ids: [ hidden_project.id ] }

      expect(response).to redirect_to(access_member_member_path(member_membership, tab: "access"))
      expect(flash[:alert]).to be_present
    end
  end
end
