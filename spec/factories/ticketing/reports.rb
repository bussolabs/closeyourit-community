FactoryBot.define do
  factory :ticket_report, class: "Ticketing::Report" do
    transient { organization { FactoryReuse.organization } }

    ticket { create(:ticket, organization: organization) }
    author do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    body { "Resoconto di lavorazione." }
  end
end
