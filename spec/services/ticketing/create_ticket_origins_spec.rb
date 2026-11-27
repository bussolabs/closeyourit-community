# frozen_string_literal: true

require "rails_helper"

# CYRA-1219 — every way a ticket is born names its channel, and only the three a person types into count
# as the team. A new caller without an origin, or with a team origin it does not deserve, fails here.
RSpec.describe "Origins declared by the ticket creation paths" do
  EXPECTED = {
    "app/controllers/member/tickets_controller.rb" => %w[form],
    "app/services/ticketing/resolve_duplicate.rb" => %w[form form],
    "app/controllers/cli/v1/tickets_controller.rb" => %w[cli],
    "app/services/telegram/create_ticket_from_message.rb" => %w[telegram],
    "app/services/helpdesk/promote_to_ticket.rb" => %w[helpdesk],
    "app/services/agents/council/settle.rb" => %w[council],
    "app/services/projects/releases/report_deploy_failure.rb" => %w[deploy_failure],
    "app/services/agents/workflows/split_epic.rb" => %w[epic_split],
    "app/services/logs/promote_to_ticket.rb" => %w[logs],
    "app/services/ideas/promote_to_ticket.rb" => %w[ideas],
    "app/services/observability/promote_to_ticket.rb" => %w[observability],
    "app/services/workload/actions/promote_to_ticket.rb" => %w[workload],
    "app/services/assistant/proposals/confirm.rb" => %w[assistant],
    "app/services/github/issues/import.rb" => %w[github_import]
  }.freeze

  # The argument list of each `CreateTicket.call(`, read up to its closing parenthesis.
  def calls_in(source)
    source.to_enum(:scan, /CreateTicket\.call\(/).map do
      start = Regexp.last_match.end(0)
      depth = 1
      index = start
      while depth.positive?
        depth += 1 if source[index] == "("
        depth -= 1 if source[index] == ")"
        index += 1
      end
      source[start...index]
    end
  end

  def origins_in(path)
    calls_in(Rails.root.join(path).read).map { |arguments| arguments[/origin: :(\w+)/, 1] }
  end

  it "lists every file that creates a ticket" do
    callers = Dir[Rails.root.join("app/**/*.rb")].select { |file| File.read(file).include?("CreateTicket.call(") }
                                                .map { |file| Pathname(file).relative_path_from(Rails.root).to_s }

    expect(callers - [ "app/services/ticketing/create_ticket.rb" ]).to match_array(EXPECTED.keys)
  end

  EXPECTED.each do |path, origins|
    it "#{path} declares #{origins.uniq.join(", ")}" do
      expect(origins_in(path)).to eq(origins)
    end
  end

  it "declares only known channels" do
    expect(EXPECTED.values.flatten.uniq - Ticketing::Ticket::ORIGINS).to be_empty
  end

  it "counts as the team only the form, the command line and Telegram" do
    expect(Ticketing::Ticket::TEAM_ORIGINS).to match_array(%w[form cli telegram])
  end
end
