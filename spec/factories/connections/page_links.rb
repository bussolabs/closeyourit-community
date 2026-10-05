# frozen_string_literal: true

FactoryBot.define do
  factory :page_link, class: "Connections::PageLink" do
    transient do
      organization { create(:organization) }
    end

    # Progetti diversi nella STESSA org: il collegamento è cross-progetto per default, come la
    # risoluzione org-wide dei wikilink (Knowledge::Links::Sync).
    page { create(:knowledge_page, organization: organization) }
    related { create(:knowledge_page, organization: organization) }
    target_title { related.title }
  end
end
