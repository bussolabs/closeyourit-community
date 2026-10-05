# frozen_string_literal: true

FactoryBot.define do
  factory :ticket_dependency, class: "Connections::TicketDependency" do
    transient do
      organization { FactoryReuse.organization }
    end

    # `ticket` dipende da `blocker` (blocker = prerequisito). Stessa org di default; cross-project
    # intra-org è comunque ammesso, i test lo esercitano passando progetti diversi della stessa org.
    ticket { create(:ticket, organization: organization) }
    blocker { create(:ticket, organization: organization) }
    created_by { ticket.reporter }
  end
end
