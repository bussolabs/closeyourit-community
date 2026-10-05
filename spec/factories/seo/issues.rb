# frozen_string_literal: true

FactoryBot.define do
  factory :seo_issue, class: "Seo::Issue" do
    site { create(:seo_site) }
    page { create(:seo_page, site:) }
    check_key { "missing_h1" }
    severity { :high }
    status { :open }
    evidence { { "url" => page&.url, "found" => 0, "expected" => 1 } }
    first_seen_at { 2.days.ago }
    last_seen_at { Time.current }

    trait :resolved do
      status { :resolved }
      resolved_at { Time.current }
    end

    trait :ignored do
      status { :ignored }
      triage_note { "Pagina di servizio, ci conviviamo" }
    end

    trait :critical do
      check_key { "noindex" }
      severity { :critical }
    end

    # Rilievo d'insieme: nasce dal confronto fra pagine, quindi non ne ha una sola.
    trait :site_scoped do
      page { nil }
      check_key { "duplicate_title" }
      severity { :medium }
      evidence { { "title" => "Home", "urls" => %w[https://example.com/ https://example.com/it] } }
    end

    trait :promoted do
      ticket do
        project = site.project
        create(:ticket, organization: project.organization, project: project)
      end
    end
  end
end
