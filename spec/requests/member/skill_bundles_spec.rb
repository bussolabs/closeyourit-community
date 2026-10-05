# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::SkillBundles", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:pin_params) { { repo: "bussolabs/closeyourit-skills", ref: "v0.1.0", version: "0.1.0", digest: "a1b2c3d" } }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  context "owner (ha agents.view + agents.manage)" do
    before do
      create(:membership, account: owner, organization: org, role: :owner)
      sign_in(owner)
    end

    it "show senza pin → 200 con l'empty-state" do
      get member_skill_bundle_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("skill-bundle-empty")
    end

    it "show col pin → 200 coi 4 valori" do
      create(:agent_skill_bundle, organization: org, repo: "bussolabs/closeyourit-skills", ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)

      get member_skill_bundle_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("skill-bundle-current")
      expect(response.body).to include("0.3.0")
    end

    it "sotto il titolo solo i conteggi: la spiegazione sta nel riquadro del modulo, una volta sola" do
      create(:agent_skill_bundle, organization: org)

      get member_skill_bundle_path

      header = Nokogiri::HTML(response.body).at_css('[data-test="skill-bundle-header"]')
      expect(header.css("p")).to be_empty
      expect(response.body).to include(I18n.t("member.skill_bundle.form_hint"))
    end

    # CYRA-453 — la pagina dichiarava la versione fissata e taceva su quella davvero in uso: la
    # tabella in cima risponde a «il rilascio è arrivato ovunque?» senza aprire una macchina per volta.
    describe "tabella di conformità (CYRA-453)" do
      let!(:bundle) do
        create(:agent_skill_bundle, organization: org, repo: "bussolabs/closeyourit-skills",
                                    ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)
      end

      def runtime(name, version)
        { "name" => name, "present" => true, "version" => version, "required" => false }
      end

      it "elenca ogni macchina con versione attesa, versione in uso e stato" do
        create(:agent_host, organization: org, hostname: "mac-allineato",
                            runtimes: [ runtime("closeyourit-skills", "0.3.0") ])
        create(:agent_host, organization: org, hostname: "mac-vecchio",
                            runtimes: [ runtime("closeyourit-skills", "0.1.0") ])
        create(:agent_host, organization: org, hostname: "mac-muto", runtimes: [ runtime("node", "22.1.0") ])

        get member_skill_bundle_path

        expect(response.body).to include('data-test="skill-bundle-conformance"')
        expect(response.body).to include("mac-allineato", "mac-vecchio", "mac-muto")
        expect(response.body).to include("0.1.0")
        expect(response.body).to include(I18n.t("member.skill_bundle.conformance.aligned"))
        expect(response.body).to include(I18n.t("member.skill_bundle.conformance.mismatched"))
        expect(response.body).to include(I18n.t("member.skill_bundle.conformance.unknown"))
      end

      # CYRA-924 — every column sorts (C9).
      it "sorts the machines by host both ways and offers every column" do
        create(:agent_host, organization: org, hostname: "zulu-mac", runtimes: [ runtime("closeyourit-skills", "0.3.0") ])
        create(:agent_host, organization: org, hostname: "alpha-mac", runtimes: [ runtime("closeyourit-skills", "0.1.0") ])

        get member_skill_bundle_path(sort: "host")
        expect(response.body.index("alpha-mac")).to be < response.body.index("zulu-mac")
        get member_skill_bundle_path(sort: "-host")
        expect(response.body.index("zulu-mac")).to be < response.body.index("alpha-mac")
        %w[host expected actual state].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
      end

      it "senza macchine registrate mostra il vuoto, non una tabella vuota" do
        get member_skill_bundle_path

        expect(response.body).to include('data-test="skill-bundle-conformance-empty"')
        expect(response.body).to include(I18n.t("member.skill_bundle.conformance.empty"))
      end

      it "le macchine revocate non compaiono" do
        create(:agent_host, :revoked, organization: org, hostname: "mac-dismesso",
                                      runtimes: [ runtime("closeyourit-skills", "0.1.0") ])

        get member_skill_bundle_path

        expect(response.body).not_to include("mac-dismesso")
      end
    end

    # CYRA-453 — la scheda del browser diceva solo «CloseYourIt»: unica pagina senza il proprio nome
    # davanti, quindi irriconoscibile fra dieci schede aperte.
    it "la scheda del browser porta il nome della pagina" do
      get member_skill_bundle_path

      expect(response.body).to include("<title>#{I18n.t('member.skill_bundle.title')} · CloseYourIt</title>")
    end

    # CYRA-453 — «Aggiornato il 09 Aug 15:14» in mezzo a una pagina italiana: la data si scrive con
    # il formato localizzato, non col default di Rails.
    it "la data dell'ultimo aggiornamento è scritta in italiano" do
      owner.update!(locale: "it")
      bundle = create(:agent_skill_bundle, organization: org, repo: "bussolabs/closeyourit-skills",
                                           ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)

      get member_skill_bundle_path

      expect(response.body).to include(I18n.l(bundle.reload.updated_at, format: :short, locale: :it))
      expect(response.body).not_to include(bundle.updated_at.to_fs(:short))
    end

    it "update valido → redirect con notice, pin persistito come singleton" do
      expect { patch member_skill_bundle_path(confirm: 1), params: pin_params }
        .to change { org.reload.skill_bundle }.from(nil)

      expect(response).to redirect_to(member_skill_bundle_path)
      follow_redirect!
      expect(response.body).to include(I18n.t("member.skill_bundle.saved"))
      expect(::Agents::SkillBundle.where(organization: org).count).to eq(1)
    end

    it "update non valido (repo) → 422, ripopola i valori inviati, non persiste" do
      patch member_skill_bundle_path, params: pin_params.merge(repo: "non-un-repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.skill_bundle).to be_nil
      expect(response.body).to include("non-un-repo")
    end

    it "update di una versione più vecchia SENZA force → 422, il pin non regredisce (monotonicità)" do
      create(:agent_skill_bundle, organization: org, repo: "bussolabs/closeyourit-skills", ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)

      patch member_skill_bundle_path, params: pin_params.merge(ref: "v0.1.0", version: "0.1.0")

      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.skill_bundle.version).to eq("0.3.0")
    end

    it "update di una versione più vecchia CON force → rollback applicato, redirect con notice" do
      create(:agent_skill_bundle, organization: org, repo: "bussolabs/closeyourit-skills", ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)

      patch member_skill_bundle_path(confirm: 1), params: pin_params.merge(ref: "v0.1.0", version: "0.1.0", force: "1")

      expect(response).to redirect_to(member_skill_bundle_path)
      expect(org.reload.skill_bundle.version).to eq("0.1.0")
    end

    it "dopo un errore col rollback NON attivo (hidden '0') il checkbox resta spento (anti-bypass)" do
      create(:agent_skill_bundle, organization: org, repo: "bussolabs/closeyourit-skills", ref: "v0.3.0", version: "0.3.0", digest: "c" * 12)

      # Il form reale invia sempre l'hidden force=0 col checkbox spento: "0" NON deve rendere checked il box,
      # altrimenti il submit successivo forzerebbe un downgrade involontario.
      patch member_skill_bundle_path, params: pin_params.merge(ref: "v0.1.0", version: "0.1.0", force: "0")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to match(/name="force"[^>]*value="1"[^>]*checked/)
    end

    it "dopo un errore col rollback ATTIVO (checkbox '1') il checkbox resta acceso" do
      patch member_skill_bundle_path(confirm: 1), params: pin_params.merge(repo: "non-un-repo", force: "1")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/name="force"[^>]*value="1"[^>]*checked/)
    end
  end

  context "membro senza agents.manage" do
    let(:member) { create(:account) }

    before do
      create(:membership, account: member, organization: org, role: :member)
      sign_in(member)
    end

    it "update → redirect (permesso negato), nessun pin creato" do
      patch member_skill_bundle_path, params: pin_params

      expect(response).to have_http_status(:redirect)
      expect(org.reload.skill_bundle).to be_nil
    end
  end

  # CYRA-453 — è una pagina di amministrazione (quattro campi obbligatori e un rollback a una
  # versione più vecchia): la vede chi amministra le automazioni, non chiunque le guardi lavorare.
  context "membro con SOLO agents.view (guarda, non amministra)" do
    let(:osservatore) { create(:account) }

    before do
      create(:membership, account: osservatore, organization: org, role: :member)
      create(:account_permission, account: osservatore, organization: org, permission_key: "agents.view")
      sign_in(osservatore)
    end

    it "la show è negata → redirect fuori dalla pagina" do
      get member_skill_bundle_path

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(root_path)
    end
  end

  context "membro con agents.manage" do
    let(:manager) { create(:account) }

    before do
      create(:membership, account: manager, organization: org, role: :member)
      create(:account_permission, account: manager, organization: org, permission_key: "agents.manage")
      sign_in(manager)
    end

    it "accede alla show anche senza agents.view esplicito → 200" do
      get member_skill_bundle_path

      expect(response).to have_http_status(:ok)
    end

    it "può aggiornare il pin → redirect, pin creato" do
      patch member_skill_bundle_path(confirm: 1), params: pin_params

      expect(response).to redirect_to(member_skill_bundle_path)
      expect(org.reload.skill_bundle).to be_present
    end
  end
end
