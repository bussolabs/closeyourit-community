# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Datasets", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    # Il member vede il progetto (assegnazione), ma NON ha datasets.manage.
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def create_params(overrides = {})
    {
      dataset: { name: "Difetti pezzi", description: "foto dei difetti", project_id: project.id },
      columns: {
        "0" => { label: "Foto pezzo", kind: "photo", role: "input" },
        "1" => { label: "Colore", kind: "text", role: "input", required: "1" },
        "2" => { label: "Esito", kind: "category", role: "target", options: "ok, ko" },
        "3" => { label: "A pagamento", kind: "boolean", role: "target" }
      }
    }.deep_merge(overrides)
  end

  describe "GET /member/datasets" do
    it "non autenticato → redirect a login" do
      get member_datasets_path
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200 e mostra i dataset visibili" do
      create(:dataset, project: project, name: "Alpha")
      sign_in(owner)
      get member_datasets_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Alpha")
    end

    # CYRA-454 — a sezione vuota il testo spiegava com'è fatto il dato, non a cosa serve la funzione.
    # Chi apre la pagina per la prima volta deve leggere un esempio di lavoro ripetitivo e trovare da
    # solo la strada per approfondire.
    describe "la sezione vuota (Scenario 1 e 2)" do
      before do
        sign_in(owner)
        get member_datasets_path
      end

      it "racconta un esempio concreto invece di descrivere il dato" do
        pagina = Nokogiri::HTML(response.body)
        vuoto = pagina.at_css("[data-test='datasets-empty']")

        expect(vuoto).to be_present
        expect(vuoto.text).to include(I18n.t("member.datasets.empty"))
        expect(vuoto.text).to include(I18n.t("member.datasets.empty_body"))
      end

      it "chiarisce che non ha a che vedere con le macchine che lavorano i ticket" do
        pagina = Nokogiri::HTML(response.body)

        expect(pagina.at_css("[data-test='datasets-empty'] [data-test='empty-example']").text)
          .to include(I18n.t("member.datasets.empty_note"))
      end

      it "non mostra una paginazione «0–0 di 0» sotto la sezione vuota" do
        expect(Nokogiri::HTML(response.body).at_css("[data-test='datasets-pagination']")).to be_nil
      end

      it "porta alla guida dedicata da dentro la sezione vuota" do
        pagina = Nokogiri::HTML(response.body)
        rimando = pagina.at_css("[data-test='datasets-empty-guide']")

        expect(rimando).to be_present
        expect(rimando["href"]).to eq(member_guides_datasets_path)
      end

      it "l'intestazione della pagina porta alla stessa guida" do
        expect(Guides::Map.path_for("/member/datasets")).to eq(member_guides_datasets_path)
        expect(response.body).to include(%(href="#{member_guides_datasets_path}"))
      end
    end
  end

  describe "GET /member/datasets/:id" do
    it "owner → 200" do
      dataset = create(:dataset, project: project)
      create(:dataset_column, :target, dataset: dataset)
      sign_in(owner)
      get member_dataset_path(dataset)
      expect(response).to have_http_status(:ok)
    end

    it "dataset di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:dataset)
      sign_in(owner)
      get member_dataset_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "le foto delle righe hanno alt testuale + lazy loading (a11y)" do
      dataset = create(:dataset, project: project)
      column = create(:dataset_column, :photo, dataset: dataset, label: "Foto pezzo")
      row = create(:dataset_row, dataset: dataset)
      create(:dataset_cell, row: row, column: column)
      sign_in(owner)
      get member_dataset_path(dataset)
      expect(response.body).to include(%(alt="#{I18n.t("member.datasets.rows.photo_alt", column: "Foto pezzo", row: 1)}"))
      expect(response.body).to include('loading="lazy"')
      expect(response.body).to include('decoding="async"')
    end

    it "mostra il blocco Audit e la cronologia attività quando ci sono eventi" do
      dataset = create(:dataset, project: project, name: "Originale")
      create(:dataset_column, dataset: dataset, role: :input)
      create(:dataset_row, dataset: dataset, purpose: :sample)
      Datasets::Save.call(organization: org, actor: owner, dataset: dataset,
                          params: { name: "Rinominato" })
      sign_in(owner)
      get member_dataset_path(dataset)
      expect(response.body).to include("dataset-audit", "activity-modal")
    end
  end

  describe "GET /member/datasets/new" do
    it "owner → 200" do
      sign_in(owner)
      get new_member_dataset_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="datasets-form-name"')
    end
  end

  describe "POST /member/datasets" do
    it "owner: crea il dataset con input e più target (dai param esatti del form)" do
      sign_in(owner)
      expect { post member_datasets_path, params: create_params }
        .to change(Datasets::Dataset, :count).by(1)

      dataset = Datasets::Dataset.order(:created_at).last
      expect(response).to redirect_to(member_dataset_path(dataset))
      expect(dataset.name).to eq("Difetti pezzi")

      expect(dataset.input_columns.map(&:code)).to contain_exactly("foto_pezzo", "colore")
      expect(dataset.target_columns.map(&:code)).to contain_exactly("esito", "a_pagamento")

      esito = dataset.target_columns.find { |c| c.code == "esito" }
      expect(esito.kind).to eq("category")
      expect(esito.option_values).to eq(%w[ok ko])

      colore = dataset.input_columns.find { |c| c.code == "colore" }
      expect(colore.required).to be(true)
      expect(dataset.input_columns.find { |c| c.code == "foto_pezzo" }.kind_photo?).to be(true)
    end

    it "nome vuoto → 422 e ri-render del form" do
      sign_in(owner)
      expect { post member_datasets_path, params: create_params(dataset: { name: "" }) }
        .not_to change(Datasets::Dataset, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "member senza datasets.manage → vietato (redirect), nessuna creazione" do
      sign_in(member)
      expect { post member_datasets_path, params: create_params }
        .not_to change(Datasets::Dataset, :count)
      expect(response).to redirect_to(root_path)
    end

    it "member con la sola datasets.manage → può creare (create è gated su manage, non owner-only)" do
      create(:account_permission, account: member, organization: org, permission_key: "datasets.manage", effect: :allow)
      sign_in(member)
      expect { post member_datasets_path, params: create_params }
        .to change(Datasets::Dataset, :count).by(1)
    end
  end

  describe "GET /member/datasets/:id/edit" do
    it "owner → 200" do
      dataset = create(:dataset, project: project)
      create(:dataset_column, :target, dataset: dataset)
      sign_in(owner)
      get edit_member_dataset_path(dataset)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /member/datasets/:id" do
    it "owner: rinomina il dataset" do
      dataset = create(:dataset, project: project, name: "Vecchio")
      # Con righe presenti le colonne sono bloccate: si aggiorna solo nome/descrizione.
      create(:dataset_row, dataset: dataset)
      sign_in(owner)
      patch member_dataset_path(dataset),
            params: { dataset: { name: "Nuovo", project_id: project.id } }
      expect(response).to redirect_to(member_dataset_path(dataset))
      expect(dataset.reload.name).to eq("Nuovo")
    end
  end

  describe "DELETE /member/datasets/:id" do
    it "owner: elimina il dataset" do
      dataset = create(:dataset, project: project)
      sign_in(owner)
      expect { delete member_dataset_path(dataset) }.to change(Datasets::Dataset, :count).by(-1)
      expect(response).to redirect_to(member_datasets_path)
    end

    it "member senza datasets.manage → vietato, nessuna eliminazione" do
      dataset = create(:dataset, project: project)
      sign_in(member)
      expect { delete member_dataset_path(dataset) }.not_to change(Datasets::Dataset, :count)
      expect(response).to redirect_to(root_path)
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the row delete" do
      sign_in(owner)
      dataset = create(:dataset, project: project)
      row = create(:dataset_row, dataset: dataset)

      get member_dataset_path(dataset)

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='dataset-row-delete-dialog-#{row.id}']")
      expect(dialog.text).to include(I18n.t("member.datasets.rows.delete_dialog.title", number: 1))
      expect(dialog.at_css("form")["action"]).to eq(member_dataset_row_path(dataset, row))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(dialog.ancestors.first.at_css("[data-test='dataset-row-delete']")["data-action"]).to eq("ui--dialog#open")
    end
  end
end
