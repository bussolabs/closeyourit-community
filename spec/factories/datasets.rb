# frozen_string_literal: true

FactoryBot.define do
  factory :dataset, class: "Datasets::Dataset" do
    transient do
      organization { create(:organization) }
    end

    project { create(:project, organization: organization) }
    created_by { create(:account) }
    sequence(:name) { |n| "Dataset #{n}" }
    status { :draft }
  end

  factory :dataset_column, class: "Datasets::Column" do
    dataset
    sequence(:code) { |n| "col_#{n}" }
    sequence(:label) { |n| "Colonna #{n}" }
    sequence(:position) { |n| n }
    kind { :text }
    role { :input }
    required { false }
    options { [] }

    trait :target do
      role { :target }
    end

    trait :photo do
      kind { :photo }
      role { :input }
    end

    trait :category do
      kind { :category }
      options { %w[positivo negativo] }
    end
  end

  factory :dataset_row, class: "Datasets::Row" do
    dataset
    cell_values { {} }
    sequence(:position) { |n| n }
    purpose { :sample }

    trait :prediction do
      purpose { :prediction }
    end
  end

  factory :dataset_cell, class: "Datasets::Cell" do
    transient do
      dataset { create(:dataset) }
    end

    row { create(:dataset_row, dataset: dataset) }
    column { create(:dataset_column, :photo, dataset: dataset) }

    after(:build) do |cell|
      next if cell.image.attached?

      cell.image.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
        filename: "cell.png",
        content_type: "image/png"
      )
    end
  end

  factory :dataset_training, class: "Datasets::Training" do
    dataset
    created_by { create(:account) }
    status { :pending }
    config { {} }
    metrics { {} }

    trait :done do
      status { :done }
      system_prompt { "Sei un classificatore. Rispondi solo con la funzione." }
      metrics { { "overall_accuracy" => 0.9, "per_target" => { "esito" => 0.9 }, "evaluated" => 10 } }
    end

    trait :failed do
      status { :failed }
      error_code { "R502-DATASET-001" }
      error_message { "Gateway non disponibile" }
    end
  end

  factory :dataset_prediction, class: "Datasets::Prediction" do
    transient do
      dataset_record { create(:dataset) }
    end

    dataset { dataset_record }
    training { create(:dataset_training, dataset: dataset_record) }
    input_row { create(:dataset_row, :prediction, dataset: dataset_record) }
    created_by { create(:account) }
    status { :pending }

    trait :done do
      status { :done }
      predicted_values { { "esito" => "positivo" } }
    end
  end
end
