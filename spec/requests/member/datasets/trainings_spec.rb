# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Datasets::Trainings", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:dataset) { create(:dataset, project: project) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto") }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def add_sample_rows(count)
    count.times { create(:dataset_row, dataset: dataset, purpose: :sample, cell_values: { "esito" => "ok" }) }
  end

  describe "POST create" do
    it "owner con abbastanza righe: crea il training e accoda il job" do
      add_sample_rows(3)
      sign_in(owner)
      expect do
        post member_dataset_trainings_path(dataset), params: { confirm: "1" }
      end.to change(Datasets::Training, :count).by(1)
        .and have_enqueued_job(Datasets::TrainJob)
      expect(response).to redirect_to(member_dataset_training_path(dataset, Datasets::Training.last))
    end

    it "righe insufficienti → redirect con alert, nessun training" do
      add_sample_rows(1)
      sign_in(owner)
      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }.not_to change(Datasets::Training, :count)
      expect(response).to redirect_to(member_dataset_path(dataset))
    end

    it "member senza datasets.train → vietato" do
      add_sample_rows(3)
      sign_in(member)
      expect { post member_dataset_trainings_path(dataset) }.not_to change(Datasets::Training, :count)
      expect(response).to redirect_to(root_path)
    end

    it "la sola datasets.manage NON basta per allenare: il gate è datasets.train" do
      create(:account_permission, account: member, organization: org, permission_key: "datasets.manage", effect: :allow)
      add_sample_rows(3)
      sign_in(member)
      expect { post member_dataset_trainings_path(dataset) }.not_to change(Datasets::Training, :count)
      expect(response).to redirect_to(root_path)
    end

    it "la sola datasets.train basta per allenare (senza datasets.manage)" do
      create(:account_permission, account: member, organization: org, permission_key: "datasets.train", effect: :allow)
      add_sample_rows(3)
      sign_in(member)
      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }.to change(Datasets::Training, :count).by(1)
    end

    # CYRA-246: un training occupa a lungo la corsia AI; niente doppioni sullo stesso dataset.
    it "training già pending sullo stesso dataset → redirect con alert, nessun nuovo training" do
      create(:dataset_training, dataset: dataset, status: :pending)
      add_sample_rows(3)
      sign_in(owner)
      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }.not_to change(Datasets::Training, :count)
      expect(response).to redirect_to(member_dataset_path(dataset))
      expect(flash[:alert]).to eq(I18n.t("member.datasets.trainings.already_running"))
    end

    it "training già running sullo stesso dataset → rifiutato" do
      create(:dataset_training, dataset: dataset, status: :running)
      add_sample_rows(3)
      sign_in(owner)
      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }.not_to change(Datasets::Training, :count)
      expect(response).to redirect_to(member_dataset_path(dataset))
    end

    it "un training concluso (done/failed) NON blocca un nuovo avvio" do
      create(:dataset_training, :done, dataset: dataset)
      add_sample_rows(3)
      sign_in(owner)
      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }.to change(Datasets::Training, :count).by(1)
    end

    # CYRA-791: l'addestramento ucciso col processo resta "in corso" e bloccava OGNI avvio successivo.
    # Riprovare dalla pagina è il recupero: non serve aspettare il giro periodico, che nello scenario
    # del guasto (motore dei lavori giù) non parte.
    it "un training interrotto oltre la soglia non blocca un nuovo avvio dalla pagina" do
      interrotto = create(:dataset_training, dataset: dataset, status: :running,
                                             heartbeat_at: (Datasets::Constants::TRAINING_STALE_AFTER + 1.minute).ago)
      add_sample_rows(3)
      sign_in(owner)

      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }
        .to change(Datasets::Training, :count).by(1)

      expect(interrotto.reload).to be_status_failed
      expect(interrotto.error_code).to eq("R500-DATASET-001")
    end

    it "un training pending su un ALTRO dataset non blocca questo" do
      create(:dataset_training, status: :pending)
      add_sample_rows(3)
      sign_in(owner)
      expect { post member_dataset_trainings_path(dataset), params: { confirm: "1" } }.to change(Datasets::Training, :count).by(1)
    end

    # CYRA-246: se l'accodamento del job fallisce, il training appena creato NON deve restare pending,
    # altrimenti la guardia "già in corso" bloccherebbe ogni avvio futuro per sempre.
    it "accodamento del job fallito → nessun addestramento orfano" do
      add_sample_rows(3)
      sign_in(owner)
      allow(Datasets::TrainJob).to receive(:perform_later).and_raise(StandardError, "coda non disponibile")

      begin
        post member_dataset_trainings_path(dataset)
      rescue StandardError
        # l'errore di accodamento si propaga: è il comportamento atteso
      end

      expect(Datasets::Training.where(status: %i[pending running])).to be_empty
    end
  end

  describe "GET show" do
    it "owner → 200 (training done mostra prompt e metriche)" do
      training = create(:dataset_training, :done, dataset: dataset)
      sign_in(owner)
      get member_dataset_training_path(dataset, training)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="training-prompt"')
    end

    # CYRA-791 — l'esito di un addestramento interrotto deve essere RECUPERABILE anche a vedersi:
    # il motivo scritto in chiaro e, per chi può allenare, il modo di riprovare senza cercarlo altrove.
    it "un addestramento interrotto spiega il motivo e offre di riprovare a chi può allenare" do
      training = create(:dataset_training, dataset: dataset, status: :failed,
                                           error_code: "R500-DATASET-001",
                                           error_message: I18n.t("datasets.errors.interrupted"))
      sign_in(owner)

      get member_dataset_training_path(dataset, training)

      expect(response.body).to include(I18n.t("datasets.errors.interrupted"))
      expect(response.body).to include('data-test="training-retry"')
    end

    it "chi non può allenare vede il motivo ma non il modo di riprovare" do
      training = create(:dataset_training, dataset: dataset, status: :failed,
                                           error_code: "R500-DATASET-001",
                                           error_message: I18n.t("datasets.errors.interrupted"))
      sign_in(member)

      get member_dataset_training_path(dataset, training)

      expect(response.body).to include(I18n.t("datasets.errors.interrupted"))
      expect(response.body).not_to include('data-test="training-retry"')
    end

    it "training di un dataset di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:dataset_training)
      sign_in(owner)
      get member_dataset_training_path(foreign.dataset, foreign)
      expect(response).to have_http_status(:not_found)
    end
  end
end
