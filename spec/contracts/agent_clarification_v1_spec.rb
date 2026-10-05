# frozen_string_literal: true

require "rails_helper"
require "digest"
require "json_schemer"

# Contract dello stato dei chiarimenti (CYRA-221). Verifica lo snapshot vendorizzato (checksum-pin,
# gemello di agent_result_v1_spec), che lo schema accetti e rifiuti le golden fixtures, e che il
# payload REALE dell'endpoint sia conforme — così la forma che due repository esterni si aspettano
# resta legata al contratto invece di dipendere da come il serializer viene ritoccato.
RSpec.describe "Agent clarification contract v1", type: :request do
  # let (non costanti top-level): evita la collisione globale con CONTRACT_ROOT/CONTRACT degli altri
  # contract spec.
  let(:contract_root) { Rails.root.join("contracts/agent-clarification") }
  let(:contract) { contract_root.join("v1") }

  def contract_schema
    @contract_schema ||= JSON.parse(contract.join("schema.json").read)
  end

  def schema_errors(definition, document)
    contract_errors(contract_schema, definition, document)
  end

  it "corrisponde allo snapshot canonico bloccato e a tutti i checksum" do
    lock = JSON.parse(contract_root.join("LOCK.json").read)
    sums = contract.join("SHA256SUMS").read
    expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

    sums.each_line do |line|
      expected, relative = line.strip.split("  ./", 2)
      expect(Digest::SHA256.file(contract.join(relative)).hexdigest).to eq(expected), relative
    end
  end

  it "accetta e rifiuta ogni golden fixture contro il suo $def" do
    manifest = JSON.parse(contract.join("manifest.json").read)
    manifest.fetch("fixtures").each do |fixture|
      document = JSON.parse(contract.join(fixture.fetch("path")).read)
      errors = schema_errors(fixture.fetch("definition"), document)
      if fixture.fetch("valid")
        expect(errors).to be_empty, "#{fixture['path']}: #{errors.map { |item| item['error'] }.join(', ')}"
      else
        expect(errors).not_to be_empty, fixture["path"]
      end
    end
  end

  # Il payload vero, non una fixture: è ciò che impedisce al serializer di allontanarsi dal contratto
  # senza che nessuno se ne accorga finché un lettore esterno non si rompe.
  it "il payload dell'endpoint è conforme al contratto" do
    account = create(:account)
    organization = create(:organization)
    project = create(:project, organization:)
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    create(:membership, account:, organization:, role: :member)
    create(:project_membership, account:, project:)
    create(:agent_clarification, workflow: ticket.agent_workflow, questions: [ "Quale delle due strade?" ])
    token = Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret]

    get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/clarifications",
        headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    errors = schema_errors("clarification_state", response.parsed_body["data"])
    expect(errors).to be_empty, errors.map { |item| item["error"] }.join(", ")
  end
end
