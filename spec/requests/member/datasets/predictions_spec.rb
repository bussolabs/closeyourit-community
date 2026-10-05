# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Datasets::Predictions", type: :request do
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

  def png
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png")
  end

  describe "GET new" do
    it "senza training completato → redirect (serve allenare)" do
      sign_in(owner)
      get new_member_dataset_prediction_path(dataset)
      expect(response).to redirect_to(member_dataset_path(dataset))
    end

    it "con un training done → 200 con i campi input" do
      create(:dataset_training, :done, dataset: dataset)
      sign_in(owner)
      get new_member_dataset_prediction_path(dataset)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="predict-field-foto"')
    end
  end

  describe "select categoria searchable (input di tipo category)" do
    let!(:taglia) { create(:dataset_column, dataset: dataset, code: "taglia", kind: :category, role: :input, options: %w[s m l]) }

    it "è searchable (Ui::SelectComponent), stesso name/submit" do
      create(:dataset_training, :done, dataset: dataset)
      sign_in(owner)
      get new_member_dataset_prediction_path(dataset)

      doc = Nokogiri::HTML(response.body)
      select = doc.at_css("select[data-test='predict-value-taglia']")
      expect(select.name).to eq("select")
      expect(select["name"]).to eq("values[taglia]")
      expect(doc.at_css("div[data-controller='ui--select'] select[data-test='predict-value-taglia']")).to be_present
    end

    it "il submit coi param esatti del form crea comunque la predizione" do
      create(:dataset_training, :done, dataset: dataset)
      sign_in(owner)
      expect do
        post member_dataset_predictions_path(dataset), params: { confirm: "1", photos: { "foto" => png }, values: { "taglia" => "m" } }
      end.to change(Datasets::Prediction, :count).by(1)
      expect(Datasets::Prediction.last.input_row.value_for("taglia")).to eq("m")
    end
  end

  describe "POST create" do
    before { create(:dataset_training, :done, dataset: dataset) }

    it "owner: crea la riga input (prediction) + la predizione e accoda il job" do
      sign_in(owner)
      expect do
        post member_dataset_predictions_path(dataset), params: { confirm: "1", photos: { "foto" => png } }
      end.to change(Datasets::Prediction, :count).by(1)
        .and have_enqueued_job(Datasets::PredictJob)
      prediction = Datasets::Prediction.last
      expect(response).to redirect_to(member_dataset_prediction_path(dataset, prediction))
      expect(prediction.input_row).to be_purpose_prediction
    end

    it "member senza datasets.train → vietato" do
      sign_in(member)
      expect { post member_dataset_predictions_path(dataset), params: { photos: { "foto" => png } } }
        .not_to change(Datasets::Prediction, :count)
      expect(response).to redirect_to(root_path)
    end

    it "la sola datasets.manage NON basta per predire: il gate è datasets.train" do
      create(:account_permission, account: member, organization: org, permission_key: "datasets.manage", effect: :allow)
      sign_in(member)
      expect { post member_dataset_predictions_path(dataset), params: { photos: { "foto" => png } } }
        .not_to change(Datasets::Prediction, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET show" do
    it "owner → 200 (done mostra i valori predetti)" do
      training = create(:dataset_training, :done, dataset: dataset)
      prediction = create(:dataset_prediction, :done, dataset_record: dataset, training: training)
      sign_in(owner)
      get member_dataset_prediction_path(dataset, prediction)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="prediction-values"')
    end

    it "predizione di un dataset di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:dataset_prediction)
      sign_in(owner)
      get member_dataset_prediction_path(foreign.dataset, foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "la foto di input ha alt testuale + lazy loading (a11y)" do
      training = create(:dataset_training, :done, dataset: dataset)
      prediction = create(:dataset_prediction, :done, dataset_record: dataset, training: training)
      create(:dataset_cell, row: prediction.input_row, column: foto)
      sign_in(owner)
      get member_dataset_prediction_path(dataset, prediction)
      expect(response.body).to include(%(alt="#{I18n.t("member.datasets.rows.photo_preview_alt", column: foto.label)}"))
      expect(response.body).to include('loading="lazy"')
    end
  end
end
