# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Tools::Registry do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:write_tool) do
    Class.new(Assistant::Tools::ProposalTool) do
      def self.declaration = { name: "propose_test", description: "x", parameters: { type: "OBJECT", properties: {} } }
      def call(_args) = { ok: true }
    end
  end

  before { stub_const("#{described_class}::WRITE_TOOLS", [ write_tool ]) }

  def context(reply_message_id: nil)
    Assistant::Tools::Context.new(account: account, organization: organization, project_ids: [],
                                  group_ids: [], full_access: false, reply_message_id: reply_message_id)
  end

  def names(declarations) = declarations.first[:functionDeclarations].map { |d| d[:name] }

  it "declares only read tools without a reply" do
    expect(names(described_class.declarations(context))).not_to include("propose_test")
  end

  it "declares write tools when the context carries the reply" do
    expect(names(described_class.declarations(context(reply_message_id: SecureRandom.uuid)))).to include("propose_test")
  end

  it "refuses a write tool without a reply even if the model asks for it" do
    expect(described_class.run(name: "propose_test", args: {}, context: context)[:error]).to be_present
  end

  it "runs a write tool when the context carries the reply" do
    result = described_class.run(name: "propose_test", args: {}, context: context(reply_message_id: SecureRandom.uuid))

    expect(result).to eq(ok: true)
  end
end
