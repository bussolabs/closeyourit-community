# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Datasets::Rows", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:dataset) { create(:dataset, project: project) }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }
  let!(:colore) { create(:dataset_column, dataset: dataset, code: "colore", kind: :text, role: :input, required: true) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto", required: false) }

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
    it "owner → 200 con i campi per colonna" do
      sign_in(owner)
      get new_member_dataset_row_path(dataset)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="row-field-colore"')
      expect(response.body).to include('data-test="row-field-foto"')
    end

    it "il select categoria (esito) è searchable (Ui::SelectComponent), stesso name/submit" do
      sign_in(owner)
      get new_member_dataset_row_path(dataset)
      doc = Nokogiri::HTML(response.body)
      select = doc.at_css("select[data-test='row-value-esito']")
      expect(select.name).to eq("select")
      expect(select["name"]).to eq("values[esito]")
      expect(doc.at_css("div[data-controller='ui--select'] select[data-test='row-value-esito']")).to be_present
    end

    it "dataset di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      get new_member_dataset_row_path(create(:dataset))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "owner: crea una riga con valori scalari" do
      sign_in(owner)
      expect { post member_dataset_rows_path(dataset), params: { values: { "esito" => "ok", "colore" => "rosso" } } }
        .to change(Datasets::Row, :count).by(1)
      expect(response).to redirect_to(member_dataset_path(dataset))
      expect(Datasets::Row.last.cell_values).to eq("esito" => "ok", "colore" => "rosso")
    end

    it "owner: crea una riga con foto (multipart → cella)" do
      sign_in(owner)
      expect do
        post member_dataset_rows_path(dataset),
             params: { values: { "esito" => "ok", "colore" => "rosso" }, photos: { "foto" => png } }
      end.to change(Datasets::Cell, :count).by(1)
      expect(Datasets::Cell.last.image).to be_attached
    end

    it "required mancante → 422" do
      sign_in(owner)
      expect { post member_dataset_rows_path(dataset), params: { values: { "esito" => "ok" } } }
        .not_to change(Datasets::Row, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "member senza datasets.manage → vietato" do
      sign_in(member)
      expect { post member_dataset_rows_path(dataset), params: { values: { "esito" => "ok", "colore" => "rosso" } } }
        .not_to change(Datasets::Row, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET edit / PATCH update" do
    let!(:row) { create(:dataset_row, dataset: dataset, cell_values: { "esito" => "ok", "colore" => "rosso" }) }

    it "owner edit → 200" do
      sign_in(owner)
      get edit_member_dataset_row_path(dataset, row)
      expect(response).to have_http_status(:ok)
    end

    it "owner update → aggiorna i valori" do
      sign_in(owner)
      patch member_dataset_row_path(dataset, row), params: { values: { "esito" => "ko", "colore" => "blu" } }
      expect(response).to redirect_to(member_dataset_path(dataset))
      expect(row.reload.cell_values).to eq("esito" => "ko", "colore" => "blu")
    end

    it "la foto già presente in edit ha alt testuale + lazy loading (a11y)" do
      create(:dataset_cell, row: row, column: foto)
      sign_in(owner)
      get edit_member_dataset_row_path(dataset, row)
      expect(response.body).to include(%(alt="#{I18n.t("member.datasets.rows.photo_preview_alt", column: foto.label)}"))
      expect(response.body).to include('loading="lazy"')
    end
  end

  describe "DELETE destroy" do
    let!(:row) { create(:dataset_row, dataset: dataset) }

    it "owner elimina la riga" do
      sign_in(owner)
      expect { delete member_dataset_row_path(dataset, row) }.to change(Datasets::Row, :count).by(-1)
      expect(response).to redirect_to(member_dataset_path(dataset))
    end

    it "member senza manage → vietato" do
      sign_in(member)
      expect { delete member_dataset_row_path(dataset, row) }.not_to change(Datasets::Row, :count)
      expect(response).to redirect_to(root_path)
    end
  end
end
