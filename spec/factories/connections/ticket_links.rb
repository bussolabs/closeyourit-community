# frozen_string_literal: true

FactoryBot.define do
  factory :ticket_link, class: "Connections::TicketLink" do
    transient do
      organization { FactoryReuse.organization }
    end

    ticket { create(:ticket, organization: organization) }
    related { create(:ticket, organization: organization) }
    created_by { ticket.reporter }
    kind { :duplicate }
  end
end
