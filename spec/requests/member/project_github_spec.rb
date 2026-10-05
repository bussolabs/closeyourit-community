# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectGithub", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }
  let(:project) { create(:project, organization: org) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def stub_repos(repos)
    allow(Github::Client).to receive(:new).and_return(instance_double(Github::Client, repositories: repos))
  end

  before { sign_in(owner) }

  describe "environment restrictions on vault export" do
    let!(:repository) do
      create(:github_repository, project:, installation: create(:github_installation, organization: org))
    end

    [ :organization, :project ].each do |level|
      context "with a #{level} restriction" do
        before do
          if level == :organization
            owner_m.update!(secret_environment_codes: [ "staging" ])
          else
            create(:account_secret_access, account: owner, project:, organization: org,
                                          environment_codes: [ "staging" ])
          end
        end

        it "refuses enabling all-environment secret synchronization" do
          patch member_project_github_path(project), params: { sync_secrets: "1" }, as: :json

          expect(response).to have_http_status(:forbidden)
          expect(repository.reload.sync_secrets).to be(false)
        end

        it "does not enqueue a manual export" do
          expect { post sync_member_project_github_path(project) }
            .not_to have_enqueued_job(Secrets::Github::SyncJob)
          expect(response).to redirect_to(member_project_github_path(project))
          expect(flash[:alert]).to eq(I18n.t("member.forbidden"))
        end

        it "keeps unrelated repository settings available" do
          patch member_project_github_path(project), params: { sync_enabled: "1" }, as: :json

          expect(response).to have_http_status(:no_content)
          expect(repository.reload.sync_enabled).to be(true)
        end
      end
    end
  end

  describe "GET show" do
    it "senza installazione org → guida all'installazione" do
      get member_project_github_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("github-needs-installation")
    end

    it "con installazione e repo disponibili → picker" do
      create(:github_installation, organization: org)
      stub_repos([ { "id" => 10, "full_name" => "bussolabs/app", "default_branch" => "main" } ])

      get member_project_github_path(project)

      expect(response.body).to include("github-repo-select")
    end

    it "con repo agganciato → impostazioni + full_name" do
      repo = create(:github_repository, :with_env_mapping,
                    project: project, installation: create(:github_installation, organization: org))

      get member_project_github_path(project)

      expect(response.body).to include("github-toggles")
      expect(response.body).to include(repo.full_name)
    end

    it "i select degli ambienti dicono a parole la scelta vuota, non il «Select…» di ripiego" do
      create(:github_repository, project: project, installation: create(:github_installation, organization: org))

      get member_project_github_path(project)

      doc = Nokogiri::HTML(response.body)
      %w[production staging preview].each do |kind|
        blank = doc.at_css("[data-test='github-#{kind}-env'] option[value='']")
        expect(blank.text).to eq(I18n.t("member.project_github.no_mapping"))
      end
    end

    # CYRA-106 — la scheda dichiara com'è andato l'ultimo invio dei secret. Prima taceva: un invio
    # fallito lasciava la pagina identica a uno riuscito, e la configurazione rotta si scopriva giorni
    # dopo guardando i log della pipeline.
    describe "esito dell'ultimo invio dei secret" do
      let(:repo) do
        create(:github_repository, :with_env_mapping, project: project, sync_secrets: true,
               installation: create(:github_installation, organization: org))
      end

      it "mai inviato → lo dice, senza fingere un esito" do
        repo

        get member_project_github_path(project)

        expect(response.body).to include("github-last-sync")
        expect(response.body).to include(I18n.t("member.project_github.last_sync_never"))
      end

      it "keeps the sync-now action inside the last sync panel, never on the page ground (T1, T5)" do
        repo

        get member_project_github_path(project)

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("[data-test='github-last-sync'] [data-test='github-sync-now']")).to be_present
      end

      it "invio riuscito → stato riuscito e quando" do
        repo.update_columns(last_sync_status: "ok", last_sync_at: 3.minutes.ago, last_sync_error: {})

        get member_project_github_path(project)

        expect(response.body).to include(I18n.t("member.project_github.last_sync_ok"))
        expect(response.body).not_to include("github-last-sync-error")
      end

      it "invio fallito → codice, motivo e dettagli della riga che lo blocca" do
        repo.update_columns(
          last_sync_status: "error", last_sync_at: 2.hours.ago,
          last_sync_error: { "code" => "R422-GITHUB-007", "message" => "riga secrets non supportata",
                             "slot" => "production",
                             "details" => { "path" => ".kamal/secrets", "line" => 8 } }
        )

        get member_project_github_path(project)

        expect(response.body).to include("github-last-sync-error")
        expect(response.body).to include("R422-GITHUB-007")
        expect(response.body).to include(I18n.t("member.project_github.sync_errors.R422-GITHUB-007"))
        expect(response.body).to include(".kamal/secrets")
        expect(response.body).to include("production")
      end

      it "un codice senza spiegazione dedicata mostra comunque il motivo registrato" do
        repo.update_columns(last_sync_status: "error", last_sync_at: 1.hour.ago,
                            last_sync_error: { "code" => "R502-GITHUB-042", "message" => "upstream a pezzi" })

        get member_project_github_path(project)

        expect(response.body).to include("R502-GITHUB-042")
        expect(response.body).to include("upstream a pezzi")
      end
    end

    it "progetto non visibile → 404 (anti-BOLA)" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      sign_in(member)

      get member_project_github_path(project)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update — connect repo" do
    it "aggancia il repo scelto e reindirizza" do
      create(:github_installation, organization: org)
      stub_repos([ { "id" => 10, "full_name" => "bussolabs/app", "default_branch" => "main" } ])

      patch member_project_github_path(project), params: { repo_id: "10" }

      expect(response).to redirect_to(member_project_github_path(project))
      expect(project.reload.github_repository.full_name).to eq("bussolabs/app")
    end

    it "repo non disponibile → 404" do
      create(:github_installation, organization: org)
      stub_repos([])

      patch member_project_github_path(project), params: { repo_id: "999" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update — regole (mapping environment)" do
    it "aggiorna il production_environment" do
      repo = create(:github_repository, :with_env_mapping,
                    project: project, installation: create(:github_installation, organization: org))
      staging = repo.staging_environment

      patch member_project_github_path(project), params: { production_environment_id: staging.id }

      expect(response).to redirect_to(member_project_github_path(project))
      expect(repo.reload.production_environment_id).to eq(staging.id)
    end
  end

  describe "PATCH update — toggle (JSON auto-save)" do
    it "toggla tag_binding_enabled a false → 204" do
      repo = create(:github_repository, project: project, installation: create(:github_installation, organization: org))

      patch member_project_github_path(project), params: { tag_binding_enabled: "0" }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(repo.reload.tag_binding_enabled).to be(false)
    end

    it "toggla sync_secrets a true → 204" do
      repo = create(:github_repository, project: project, installation: create(:github_installation, organization: org))

      patch member_project_github_path(project), params: { sync_secrets: "1" }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(repo.reload.sync_secrets).to be(true)
    end
  end

  describe "POST sync (Sync now)" do
    it "enfila il SyncJob e reindirizza con notice" do
      repo = create(:github_repository, :with_env_mapping, project: project,
                    installation: create(:github_installation, organization: org), sync_secrets: true)
      # Il preflight vero andrebbe a leggere la configurazione su GitHub: qui si prova l'accodamento,
      # non la preparazione degli slot (che ha i suoi spec).
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.ok([]))

      expect { post sync_member_project_github_path(project) }
        .to have_enqueued_job(Secrets::Github::SyncJob).with(github_repository_id: repo.id)
      expect(response).to redirect_to(member_project_github_path(project))
    end

    # CYRA-637 — senza nemmeno un ambiente collegato il job partiva lo stesso e finiva con
    # {pushed: 0, deleted: 0} e una riga verde: «riuscita» su una sincronizzazione che non aveva
    # scritto niente. Ora si ferma prima di accodare, e chi ha premuto legge perché.
    it "senza nessun ambiente collegato non enfila il job e dice cosa manca" do
      create(:github_repository, project: project,
             installation: create(:github_installation, organization: org), sync_secrets: true)

      expect { post sync_member_project_github_path(project) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to redirect_to(member_project_github_path(project))
      expect(flash[:alert]).to be_present
    end

    it "con un valore null legacy non enfila il job e mostra l'errore di preflight" do
      repo = create(:github_repository, :with_env_mapping, project: project,
                    installation: create(:github_installation, organization: org), sync_secrets: true)
      error = AppError.new("variabili senza valore", code: "R422-GITHUB-009",
                                                    details: { unset: %w[BROKEN_VALUE] })
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.err(error))

      expect { post sync_member_project_github_path(project) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to redirect_to(member_project_github_path(project))
      expect(flash[:alert]).to include("R422-GITHUB-009")
    end

    # CYRA-106 — l'avviso rosso sparisce al primo ricaricamento della pagina. Se l'esito non venisse
    # registrato anche qui, subito dopo un tentativo bloccato la scheda tornerebbe a mostrare il
    # vecchio "riuscito": il contrario di quello che è appena successo.
    it "un tentativo bloccato in partenza resta scritto sulla scheda" do
      repo = create(:github_repository, :with_env_mapping, project: project,
                    installation: create(:github_installation, organization: org), sync_secrets: true)
      repo.update_columns(last_sync_status: "ok", last_sync_at: 2.days.ago)
      error = AppError.new("variabili senza valore", code: "R422-GITHUB-009",
                                                    details: { unset: %w[BROKEN_VALUE], slot: "production" })
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.err(error))

      post sync_member_project_github_path(project)

      repo.reload
      expect(repo).to be_last_sync_failed
      expect(repo.last_sync_error).to include("code" => "R422-GITHUB-009", "slot" => "production")
      expect(repo.last_sync_at).to be_within(5.seconds).of(Time.current)
    end

    it "senza repo agganciato → redirect con alert, nessun job" do
      expect { post sync_member_project_github_path(project) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to redirect_to(member_project_github_path(project))
    end
  end

  describe "DELETE destroy" do
    it "scollega il repo dal progetto" do
      create(:github_repository, project: project, installation: create(:github_installation, organization: org))

      delete member_project_github_path(project)

      expect(response).to redirect_to(member_project_github_path(project))
      expect(project.reload.github_repository).to be_nil
    end
  end

  # CYRA-234 — chi ha solo github.manage gestisce l'aggancio del repo, ma NON può accendere né
  # lanciare la copia dei secret verso GitHub (esfiltrerebbe tutto il vault). Serve secrets.read: senza,
  # il toggle sync_secrets e il "Sync now" sono rifiutati. Gli altri toggle restano gestibili.
  describe "gate secrets.read su sync_secrets e Sync now (CYRA-234)" do
    let(:restricted) { create(:account) }

    before do
      create(:membership, account: restricted, organization: org, role: :member)
      create(:project_membership, account: restricted, project: project)
      Authorization::SetAccountPermissions.call(organization: org, account: restricted,
                                                allow_keys: [ "github.manage" ], actor: owner)
      sign_in(restricted)
    end

    it "toggle sync_secrets (JSON) senza secrets.read → 403 e il flag NON cambia" do
      repo = create(:github_repository, project: project, installation: create(:github_installation, organization: org), sync_secrets: false)

      patch member_project_github_path(project), params: { sync_secrets: "1" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(repo.reload.sync_secrets).to be(false)
    end

    it "POST sync senza secrets.read → nessun job accodato, redirect con alert" do
      create(:github_repository, project: project, installation: create(:github_installation, organization: org))

      expect { post sync_member_project_github_path(project) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to redirect_to(member_project_github_path(project))
      expect(flash[:alert]).to be_present
    end

    # CYRA-106 — l'esito racconta la sorte dei VALORI del vault (quali slot, quali nomi mancano):
    # sta dietro allo stesso gate del "Sync now", non davanti.
    it "senza secrets.read la scheda non mostra l'esito dell'ultimo invio" do
      repo = create(:github_repository, project: project, sync_secrets: true,
                    installation: create(:github_installation, organization: org))
      repo.update_columns(last_sync_status: "error", last_sync_at: 1.hour.ago,
                          last_sync_error: { "code" => "R422-GITHUB-007", "slot" => "production" })

      get member_project_github_path(project)

      expect(response.body).not_to include("github-last-sync")
      expect(response.body).not_to include("R422-GITHUB-007")
    end

    it "un altro toggle (tag_binding) resta gestibile con solo github.manage → 204" do
      repo = create(:github_repository, project: project, installation: create(:github_installation, organization: org))

      patch member_project_github_path(project), params: { tag_binding_enabled: "0" }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(repo.reload.tag_binding_enabled).to be(false)
    end
  end

  # CYRA-605 — la scelta si fa dalla scheda GitHub del progetto. Il canale Member ha lo stesso punto
  # in cui il campo può sparire in silenzio: `settings_params` fa `permit`, e ciò che non è elencato
  # non arriva errore — non arriva e basta.
  describe "release_probe dalla scheda del progetto" do
    let!(:repository) { create(:github_repository, project:) }

    before { sign_in(owner) }

    # La vista costruisce le voci dall'elenco del modello: se il modello e la vista divergessero, la
    # pagina esploderebbe qui e non nel salvataggio — e nessuna prova sul salvataggio se ne accorge.
    it "la scheda mostra le tre voci e quella vuota" do
      get member_project_github_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("github.release_probe.options.deploy_smoke"))
      expect(response.body).to include(I18n.t("github.release_probe.options.publish"))
      expect(response.body).to include(I18n.t("github.release_probe.options.merge"))
      expect(response.body).to include(I18n.t("github.release_probe.undeclared"))
    end

    it "salva la scelta" do
      # CYRA-625 — «il pacchetto è pubblicato» si salva insieme alle sue coordinate: senza, il
      # sistema non saprebbe su quale scaffale guardare né con che nome chiedere.
      patch member_project_github_path(project),
            params: { release_probe: "publish", registry: "npm", package_name: "@closeyourit/cli" }

      expect(repository.reload).to have_attributes(release_probe: "publish", registry: "npm",
                                                   package_name: "@closeyourit/cli")
    end

    it "«non dichiarato» si può rimettere: non scegliere resta una scelta possibile" do
      repository.update!(release_probe: :merge)

      patch member_project_github_path(project), params: { release_probe: "" }

      expect(repository.reload.release_probe).to be_nil
    end

    it "«il rilascio è in piedi» senza ambiente di produzione non passa" do
      patch member_project_github_path(project), params: { release_probe: "deploy_smoke" }

      expect(repository.reload.release_probe).to be_nil
    end
  end
end
