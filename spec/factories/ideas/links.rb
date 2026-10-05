FactoryBot.define do
  factory :idea_link, class: "Ideas::Link" do
    transient do
      organization { create(:organization) }
      project { create(:project, organization: organization) }
    end

    # Stesso progetto di default: è la condizione di validità.
    target { create(:idea, organization: organization, project: project) }
    source { create(:idea, organization: organization, project: target.project) }
    kind { :related }

    trait :evolution do
      kind { :evolution }
    end
  end
end
